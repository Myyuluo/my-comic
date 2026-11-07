/// 在线漫画章节下载服务（设计稿 2026-09-12 §4，app 级、挂 `AppModel`）。
///
/// 下载是在线直读之外的离线入口（2026-09-26 起点章即在线直读，设计稿 §1 补记）：
/// 单 worker 串行取 `manga_download_jobs`
/// 里最早的 `queued` 任务，任务内 4 并发取页落到 `<manga>/.staging/<jobId>/`，
/// 全部齐后写 `pages.json`（最后写），再把整个 staging 目录 rename 成
/// `downloads/{source}/{manga}/{chapter}/` → `done`。失败按 2s / 8s / 20s 退避
/// 重试三次，再失败留 `failed` + `last_error`；取消真中止并删半成品 staging。
/// 进程重启后 `running` 行复位为 `queued` 续跑，staging 里已落地的页按磁盘现状跳过。
///
/// **合规**：本服务**不**挂 `StoreRestrictedCapability.downloads`——互联对端漫画
/// 在 iOS 是保留的在线源，改成必须下载后读，若下载被门挡住就是死路。Mihon
/// 入口继续受 `onlineMangaSource` 门控（iOS 无入口）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/online_manga_chapter_updates.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/download/manga_download_sidecar.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi/src/platform/mobile/download_keep_alive_hub.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/media/manga/mokuro_sidecar.dart';

/// 三次自动重试之间的退避。
const List<Duration> kMangaDownloadRetryBackoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 8),
  Duration(seconds: 20),
];

/// 一个任务最多尝试的次数：失败后 `attempt_count < 3` 才退避重跑，否则 `failed`。
const int kMangaDownloadMaxAttempts = 3;

/// 分隔身份串的 NUL（写成转义而不是裸字节：裸 NUL 会让 git 把源码判成 binary）。
final String _identitySeparator = String.fromCharCode(0);

/// 任务 id：`sha256(kind NUL bookKey NUL chapterKey)[:32]`。
String mangaDownloadJobId({
  required String kind,
  required String bookKey,
  required String chapterKey,
}) {
  final String identity = <String>[
    kind,
    bookKey,
    chapterKey,
  ].join(_identitySeparator);
  return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
}

/// 中止信号。用户取消（[cancelled]）与服务停止（[stopped]）必须分开：前者把行改成
/// `cancelled` 并删半成品，后者只是进程要退出，行保持 `running` 留给下次启动续跑。
class _CancelToken {
  bool cancelled = false;
  bool stopped = false;
}

class _ActiveJob {
  _ActiveJob(this.jobId);

  final String jobId;
  final _CancelToken token = _CancelToken();
  final Completer<void> done = Completer<void>();
}

class _PageFile {
  const _PageFile({required this.relativeUrl, required this.file});

  final String relativeUrl;
  final File file;
}

/// 本章目录的落点。`adoptedComplete` = 正式目录已存在且完整（上次崩溃在
/// rename 与映射落库之间），直接认领，不重下。
class _ChapterTarget {
  const _ChapterTarget({
    required this.folderName,
    required this.adoptedComplete,
  });

  final String folderName;
  final bool adoptedComplete;
}

class MangaDownloadService {
  MangaDownloadService({
    required FushiDatabase database,
    required OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
    serviceFor,
    MangaDownloadSidecarFetcher? sidecarFetcher,
    DateTime Function()? clock,
    Future<void> Function(Duration duration)? wait,
    DownloadKeepAlive? keepAlive,
    this.pageConcurrency = 4,
  }) : _database = database,
       _serviceFor = serviceFor,
       _sidecarFetcher = sidecarFetcher,
       _clock = clock ?? DateTime.now,
       _wait = wait ?? ((Duration duration) => Future<void>.delayed(duration)),
       _keepAlive = keepAlive ?? downloadKeepAliveHub.lease('manga');

  final FushiDatabase _database;
  final OnlineMangaLibraryService Function(OnlineMangaRuntimeKind runtime)
  _serviceFor;
  final MangaDownloadSidecarFetcher? _sidecarFetcher;
  final DateTime Function() _clock;
  final Future<void> Function(Duration duration) _wait;

  /// BUG-2714：worker 有任务在跑就挂下载保活（Android 前台服务），队列排空 /
  /// 服务停止时撤。与其它下载来源经 [downloadKeepAliveHub] 汇总，互不撤对方。
  final DownloadKeepAlive _keepAlive;
  bool _keepAliveActive = false;

  /// 任务内同时在飞的取页数。
  final int pageConcurrency;

  bool _started = false;
  bool _disposed = false;
  bool _draining = false;
  bool _wakeRequested = false;
  _ActiveJob? _active;
  Completer<void>? _idle;

  int get _now => _clock().millisecondsSinceEpoch;

  /// 上一条新排任务的 `created_at`。worker 按 `(created_at, job_id)` 领取，同一
  /// 毫秒内批量入队（「下载全部」几十章）若共用同一时刻，领取序会退化成哈希序、
  /// 章序丢失；这里保证每条新任务的 `created_at` 严格递增。
  int _lastCreatedAt = 0;

  int _nextCreatedAt() {
    final int now = _now;
    _lastCreatedAt = now > _lastCreatedAt ? now : _lastCreatedAt + 1;
    return _lastCreatedAt;
  }

  /// worker 是否空闲（测试用；生产不需要等它）。
  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();

  /// 启动：把上次进程死亡留下的 `running` 复位并开始消费队列。幂等。
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    // 2026-11-05：Mokuro.moe 内置源已移除。清掉旧任务行，避免它们被当成
    // 普通章节任务重试失败；已下载的书是普通漫画行，不受影响。
    await _database.deleteMangaDownloadJobsOfKind(
      MangaDownloadJobKind.mokuroVolume,
    );
    await _database.resetRunningMangaDownloadJobs(updatedAt: _now);
    _kick();
  }

  /// 停止消费（正在飞的任务中止；行保持 `running`，下次 [start] 复位续跑）。
  void dispose() {
    _disposed = true;
    final _ActiveJob? active = _active;
    if (active != null) {
      active.token.stopped = true;
    }
    _stopKeepAlive();
  }

  /// 任务表变了的信号流（不带行，消费方自己 [listJobs]）。
  Stream<void> watchJobs() => _database.watchMangaDownloadJobs();

  Future<List<MangaDownloadJobRow>> listJobs({
    Set<String> statuses = const <String>{},
  }) =>
      _database.listMangaDownloadJobs(statuses: statuses);

  /// 一本书的任务，按 chapterKey 索引（作品页 / 章节选择器一次取全量）。
  Future<Map<String, MangaDownloadJobRow>> jobsForBook(String bookKey) async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs();
    return <String, MangaDownloadJobRow>{
      for (final MangaDownloadJobRow row in rows)
        if (row.bookKey == bookKey && row.kind == MangaDownloadJobKind.chapter)
          row.chapterKey: row,
    };
  }

  /// 入队一章。
  ///
  /// 幂等：已 `done` 且目录判据为真 → 原样返回不重下；`queued` / `running` →
  /// 原样返回；`failed` / `cancelled` / 已 done 但目录被删 → 重置成 `queued`。
  /// 条目必须已在书架（`bookKey` 由条目身份推导，与作品页入库用的同一条）。
  Future<MangaDownloadJobRow> enqueueChapter({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    required bool autoOcr,
  }) async {
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(entry);
    final String jobId = mangaDownloadJobId(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: chapter.key,
    );
    final MangaDownloadJobRow? existing = await _database.getMangaDownloadJob(
      jobId,
    );
    if (existing != null) {
      switch (existing.status) {
        case MangaDownloadJobStatus.queued:
        case MangaDownloadJobStatus.running:
          return existing;
        case MangaDownloadJobStatus.done:
          if (await DownloadLibraryIndex(_database).isChapterDownloaded(
            bookKey: bookKey,
            chapterKey: chapter.key,
          )) {
            return existing;
          }
      }
    }
    final int now = _now;
    await _database.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion(
        jobId: Value<String>(jobId),
        kind: const Value<String>(MangaDownloadJobKind.chapter),
        bookKey: Value<String>(bookKey),
        chapterKey: Value<String>(chapter.key),
        runtime: Value<String>(entry.runtime.wireValue),
        title: Value<String>(entry.series.title),
        chapterTitle: Value<String>(mangaChapterDisplayName(chapter)),
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        lastError: const Value<String?>(null),
        createdAt: Value<int>(existing?.createdAt ?? _nextCreatedAt()),
        updatedAt: Value<int>(now),
        completedAt: const Value<int?>(null),
      ),
    );
    _kick();
    return (await _database.getMangaDownloadJob(jobId))!;
  }

  /// 批量入队（按给定顺序）。
  Future<void> enqueueChapters({
    required OnlineMangaLibraryEntry entry,
    required Iterable<OnlineMangaChapter> chapters,
    required bool autoOcr,
  }) async {
    for (final OnlineMangaChapter chapter in chapters) {
      await enqueueChapter(entry: entry, chapter: chapter, autoOcr: autoOcr);
    }
  }

  /// 取消：`queued` 直接改状态；正在飞的任务中止并删半成品目录。
  Future<void> cancel(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    final _ActiveJob? active = _active;
    if (active != null && active.jobId == jobId) {
      active.token.cancelled = true;
      return;
    }
    if (row.status == MangaDownloadJobStatus.queued ||
        row.status == MangaDownloadJobStatus.running) {
      await _database.updateMangaDownloadJobStatus(
        jobId,
        status: MangaDownloadJobStatus.cancelled,
        updatedAt: _now,
      );
      await _deleteChapterDirectory(row);
    }
  }

  /// 重试 `failed` / `cancelled` 的任务。
  Future<void> retry(String jobId) async {
    final MangaDownloadJobRow? row = await _database.getMangaDownloadJob(jobId);
    if (row == null) return;
    if (row.status != MangaDownloadJobStatus.failed &&
        row.status != MangaDownloadJobStatus.cancelled) {
      return;
    }
    await _database.updateMangaDownloadJobStatus(
      jobId,
      status: MangaDownloadJobStatus.queued,
      updatedAt: _now,
      clearLastError: true,
      attemptCount: 0,
    );
    _kick();
  }

  /// 删任务行（正在飞的先取消）。不删已下载的章目录——那是内容，走
  /// [deleteChapterDownload]。
  Future<void> remove(String jobId) async {
    final _ActiveJob? active = _active;
    if (active != null && active.jobId == jobId) {
      active.token.cancelled = true;
      await active.done.future;
    }
    await _database.deleteMangaDownloadJob(jobId);
  }

  /// 删所有已结束（done / failed / cancelled）的任务行（下载中心「清除已完成」）。
  Future<void> clearFinished() async {
    final List<MangaDownloadJobRow> rows = await _database
        .listMangaDownloadJobs(
          statuses: const <String>{
            MangaDownloadJobStatus.done,
            MangaDownloadJobStatus.failed,
            MangaDownloadJobStatus.cancelled,
          },
        );
    for (final MangaDownloadJobRow row in rows) {
      await _database.deleteMangaDownloadJob(row.jobId);
    }
  }

  // ── worker ─────────────────────────────────────────────────────────

  void _kick() {
    if (!_started || _disposed) return;
    if (_draining) {
      _wakeRequested = true;
      return;
    }
    _draining = true;
    _idle = Completer<void>();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (!_disposed) {
        final MangaDownloadJobRow? next = await _database
            .claimNextQueuedMangaDownloadJob(updatedAt: _now);
        if (next == null) break;
        final _ActiveJob active = _ActiveJob(next.jobId);
        _active = active;
        _reportKeepAlive(next);
        try {
          await _run(next, active);
        } on Object catch (error, stack) {
          // _run 自己把失败落库；能到这里的是落库本身失败（库已关等）。
          ErrorLogService.instance.log(
            'MangaDownloadService.run ${next.jobId}',
            error,
            stack,
          );
        } finally {
          _active = null;
          active.done.complete();
        }
      }
    } finally {
      _draining = false;
      final Completer<void>? idle = _idle;
      _idle = null;
      idle?.complete();
      if (_wakeRequested && !_disposed) {
        // 马上还有下一轮：不撤保活——撤了之后 app 若已在后台，Android 不允许
        // 再拉起前台服务，后续任务就失去保护。
        _wakeRequested = false;
        _kick();
      } else {
        _stopKeepAlive();
      }
    }
  }

  /// 当前任务的保活通知：标题是作品名，正文是章 / 卷名（有页数时带百分比）。
  /// 节流 / 去重在 [DownloadKeepAlive] 实现里做，这里每次进度变化都如实报。
  void _reportKeepAlive(
    MangaDownloadJobRow job, {
    int done = 0,
    int total = 0,
  }) {
    if (_disposed) return;
    final int? percent = total > 0
        ? (done.clamp(0, total) * 100 ~/ total)
        : null;
    _keepAliveActive = true;
    unawaited(
      _keepAlive.update(
        title: job.title,
        text: percent == null
            ? job.chapterTitle
            : '${job.chapterTitle} · $percent%',
        percent: percent,
      ),
    );
  }

  void _stopKeepAlive() {
    if (!_keepAliveActive) return;
    _keepAliveActive = false;
    unawaited(_keepAlive.stop());
  }

  Future<void> _run(MangaDownloadJobRow job, _ActiveJob active) async {
    final _CancelToken token = active.token;
    int attempt = job.attemptCount;
    while (true) {
      try {
        await _download(job, token);
        return;
      } on _Stopped {
        // 服务停止：行保持 running，下次 start() 复位成 queued 续跑。
        return;
      } on _Cancelled {
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.cancelled,
          updatedAt: _now,
        );
        await _deleteChapterDirectory(job);
        return;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaDownloadService.download ${job.jobId}',
          error,
          stack,
        );
        attempt += 1;
        if (attempt >= kMangaDownloadMaxAttempts || _disposed) {
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.failed,
            updatedAt: _now,
            lastError: '$error',
            attemptCount: attempt,
          );
          return;
        }
        await _database.updateMangaDownloadJobStatus(
          job.jobId,
          status: MangaDownloadJobStatus.running,
          updatedAt: _now,
          lastError: '$error',
          attemptCount: attempt,
        );
        await _wait(
          kMangaDownloadRetryBackoff[(attempt - 1).clamp(
            0,
            kMangaDownloadRetryBackoff.length - 1,
          )],
        );
        if (token.stopped) return;
        if (token.cancelled) {
          await _database.updateMangaDownloadJobStatus(
            job.jobId,
            status: MangaDownloadJobStatus.cancelled,
            updatedAt: _now,
          );
          await _deleteChapterDirectory(job);
          return;
        }
      }
    }
  }

  Future<void> _download(MangaDownloadJobRow job, _CancelToken token) async {
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      job.runtime,
    );
    if (runtime == null) {
      throw StateError('Unknown manga runtime: ${job.runtime}');
    }
    final OnlineMangaLibraryService service = _serviceFor(runtime);
    EpubBookRow? row = await _database.getEpubBook(job.bookKey);
    if (row == null) {
      throw StateError('The manga is no longer in the library: ${job.bookKey}');
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) {
      throw StateError('The library row has no online descriptor');
    }
    final int chapterIndex = entry.indexOfChapterKey(job.chapterKey);
    if (chapterIndex < 0) {
      throw StateError('The chapter is no longer listed: ${job.chapterKey}');
    }
    final OnlineMangaChapter chapter = entry.chapters[chapterIndex];
    // 新布局的漫画根：`downloads/{source}/{manga}`。旧行在这里被重指向新根
    // （不搬文件）；旧布局的已下载章仍由 DownloadLibraryIndex 只读回退打开。
    row = await service.ensureBookDirectory(row);
    final String mangaDir = row.extractDir;
    final DownloadLibraryIndex index = DownloadLibraryIndex(_database);
    if (await index.isChapterDownloaded(
      bookKey: job.bookKey,
      chapterKey: chapter.key,
    )) {
      await _markDone(job);
      return;
    }
    _throwIfCancelled(token);
    final List<OnlineMangaPageRef> pages = await service.adapter
        .resolveChapterPages(entry: entry, chapter: chapter);
    if (pages.isEmpty) {
      throw StateError('The chapter has no pages');
    }
    _throwIfCancelled(token);

    final _ChapterTarget target = await _prepareChapterTarget(
      job: job,
      chapter: chapter,
      mangaDir: mangaDir,
    );
    if (target.adoptedComplete) {
      // 上次崩溃在 rename 与映射落库之间：目录已经完整，认领它而不是重下。
      await _persistMapping(
        bookKey: job.bookKey,
        chapterKey: chapter.key,
        folderName: target.folderName,
      );
      await _markDone(job);
      return;
    }

    // 整章先写 `<manga>/.staging/<jobId>/`，pages.json 最后写，完成后整目录
    // rename 到正式位置。半成品永远不在正式章目录里，也不进映射/索引。
    final Directory staging = downloadStagingDirectory(mangaDir, job.jobId);
    await staging.create(recursive: true);
    final List<_PageFile?> files = List<_PageFile?>.filled(pages.length, null);
    int done = 0;
    // 续跑：staging 里已完整落地的页直接认（`.tmp` 不算）。
    for (int index = 0; index < pages.length; index++) {
      final _PageFile? existing = await _existingPageFile(staging, index);
      if (existing != null) {
        files[index] = existing;
        done += 1;
      }
    }
    await _database.updateMangaDownloadJobProgress(
      job.jobId,
      pagesDone: done,
      pagesTotal: pages.length,
      updatedAt: _now,
    );
    _reportKeepAlive(job, done: done, total: pages.length);
    final List<int> pending = <int>[
      for (int index = 0; index < pages.length; index++)
        if (files[index] == null) index,
    ];
    Object? firstError;
    StackTrace? firstStack;
    Future<void> worker() async {
      while (pending.isNotEmpty && firstError == null) {
        if (token.cancelled || token.stopped) return;
        final int index = pending.removeAt(0);
        try {
          files[index] = await _fetchPage(
            service.adapter,
            pages[index],
            staging,
            index,
          );
          done += 1;
          await _database.updateMangaDownloadJobProgress(
            job.jobId,
            pagesDone: done,
            pagesTotal: pages.length,
            updatedAt: _now,
          );
          _reportKeepAlive(job, done: done, total: pages.length);
        } on Object catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
    }

    final int concurrency = pageConcurrency < 1 ? 1 : pageConcurrency;
    await Future.wait<void>(<Future<void>>[
      for (int i = 0; i < concurrency; i++) worker(),
    ]);
    _throwIfCancelled(token);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    // 全部页齐 → 用真实字节尺寸写 pages.json（含稳定身份）。
    final List<MokuroImage> payloadImages = <MokuroImage>[];
    for (final _PageFile? file in files) {
      if (file == null) throw StateError('A page is missing after download');
      final Uint8List bytes = await file.file.readAsBytes();
      final ({int width, int height})? size = await mangaImageDimensions(bytes);
      if (size == null) {
        throw StateError('Undecodable page image: ${file.relativeUrl}');
      }
      payloadImages.add(
        MokuroImage(
          url: file.relativeUrl,
          size: MokuroSize(size.width.toDouble(), size.height.toDouble()),
          blocks: const <MokuroBlock>[],
        ),
      );
    }
    _throwIfCancelled(token);
    MokuroPayload payload = MokuroPayload(images: payloadImages);
    final List<String> sourceUrls = <String>[
      for (final OnlineMangaPageRef page in pages) page.sourceUrl ?? '',
    ];
    final MangaDownloadSidecarFetcher? sidecarFetcher =
        _sidecarFetcher ??
        (service.adapter is MangaOcrSidecarProvider
            ? (OnlineMangaLibraryEntry e, OnlineMangaChapter c) =>
                  (service.adapter as MangaOcrSidecarProvider)
                      .fetchChapterOcrSidecar(entry: e, chapter: c)
            : null);
    if (sidecarFetcher != null) {
      try {
        final String? sidecar = await sidecarFetcher(entry, chapter);
        if (sidecar != null && looksLikeMokuroSidecar(sidecar)) {
          final MokuroSidecarMergeResult merged = mergeMokuroSidecar(
            downloaded: payload,
            sidecarJson: sidecar,
            sourceUrls: sourceUrls,
          );
          if (merged.accepted) payload = merged.payload;
        }
      } on Object catch (error, stack) {
        // sidecar 是增强能力，网络或格式问题不得让图片下载失败。
        ErrorLogService.instance.log(
          'MangaDownloadService.sidecar ${job.jobId}',
          error,
          stack,
        );
      }
    }
    _throwIfCancelled(token);
    final MangaPagesManifest manifest = MangaPagesManifest(
      sourceRuntime: entry.runtime.wireValue,
      sourceId: entry.sourceId,
      sourceName: await service.downloadSourceName(entry),
      extensionPackage: entry.extensionPackage,
      mangaKey: entry.series.key,
      mangaTitle: entry.series.title,
      chapterKey: chapter.key,
      chapterName: chapter.name,
      chapterNumber: chapter.number,
      scanlator: chapter.scanlator,
      chapterUrl: chapter.raw['url']?.toString() ?? chapter.key,
      payload: payload,
      downloadedAt: _clock().toUtc(),
    );
    // pages.json 最后写：它存在即代表整章页图已经齐了。
    await writePagesManifestAtomically(staging, manifest);
    _throwIfCancelled(token);
    final String folderName = await _renameStagingIntoPlace(
      staging: staging,
      mangaDir: mangaDir,
      desiredFolderName: target.folderName,
    );
    // rename 成功后立刻落映射（中间没有取消检查：取消路径按映射删目录）。
    await _persistMapping(
      bookKey: job.bookKey,
      chapterKey: chapter.key,
      folderName: folderName,
    );
    await _markDone(job);
  }

  Future<_ChapterTarget> _prepareChapterTarget({
    required MangaDownloadJobRow job,
    required OnlineMangaChapter chapter,
    required String mangaDir,
  }) async {
    final MangaChapterDirRow? mapping = await _database.getMangaChapterDir(
      job.bookKey,
      job.chapterKey,
    );
    final String base = _chapterFolderName(chapter);
    final Set<String> tried = <String>{};
    String desired = mapping?.folderName ?? base;
    int suffix = 2;
    while (true) {
      if (!tried.add(desired)) {
        desired = '$base ($suffix)';
        suffix += 1;
        continue;
      }
      final Directory directory = downloadChapterDirectory(mangaDir, desired);
      if (!await directory.exists()) {
        return _ChapterTarget(folderName: desired, adoptedComplete: false);
      }
      if (await isDownloadLibraryChapterComplete(directory)) {
        return _ChapterTarget(folderName: desired, adoptedComplete: true);
      }
      desired = '$base ($suffix)';
      suffix += 1;
    }
  }

  /// 章目录名：章展示名；空名退回章 key。票 05 再补扫译组/序号后缀。
  static String _chapterFolderName(OnlineMangaChapter chapter) {
    final String name = chapter.name.trim();
    return sanitizeDownloadLibrarySegment(name.isEmpty ? chapter.key : name);
  }

  /// 把 staging 目录整章 rename 到正式章目录；目标被占时用确定后缀，绝不覆盖。
  Future<String> _renameStagingIntoPlace({
    required Directory staging,
    required String mangaDir,
    required String desiredFolderName,
  }) async {
    String candidate = desiredFolderName;
    int suffix = 2;
    while (true) {
      final Directory target = downloadChapterDirectory(mangaDir, candidate);
      if (!await target.exists()) {
        try {
          await staging.rename(target.path);
          await _cleanupStagingParent(staging);
          return candidate;
        } on FileSystemException {
          if (!await target.exists()) rethrow;
        }
      }
      candidate = '$desiredFolderName ($suffix)';
      suffix += 1;
    }
  }

  Future<void> _persistMapping({
    required String bookKey,
    required String chapterKey,
    required String folderName,
  }) =>
      _database.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: chapterKey,
        folderName: folderName,
        updatedAt: _now,
      );

  /// staging 的父目录（`<manga>/.staging`）空了就删掉；非致命。
  static Future<void> _cleanupStagingParent(Directory staging) async {
    try {
      final Directory parent = staging.parent;
      if (await parent.exists() && await parent.list().isEmpty) {
        await parent.delete();
      }
    } on FileSystemException {
      // 目录被占用等：留着空 `.staging` 无害，扫描本来就会忽略点号目录。
    }
  }

  Future<void> _markDone(MangaDownloadJobRow job) async {
    final int now = _now;
    await _database.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.done,
      updatedAt: now,
      clearLastError: true,
      completedAt: now,
    );
    // OCR 自动钩子已随 OCR 域移除；下载完成只标记任务状态。
  }

  Future<_PageFile> _fetchPage(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaPageRef page,
    Directory staging,
    int index,
  ) async {
    final Uint8List bytes = await adapter.fetchChapterPage(page);
    if (bytes.isEmpty) {
      throw StateError('Empty page image at index $index');
    }
    final String name = downloadPageFileName(
      index,
      downloadPageExtensionFor(bytes),
    );
    final File target = File(p.join(staging.path, name));
    // 先写 .tmp 再 rename：半截文件被续跑当成有效页就是一页永久坏图。
    final File staged = File('${target.path}.tmp');
    await staged.writeAsBytes(bytes, flush: true);
    await staged.rename(target.path);
    return _PageFile(relativeUrl: name, file: target);
  }

  /// 续跑时找 staging 里已落地的第 [index] 页（任意扩展名，`.tmp` 除外，空文件不算）。
  Future<_PageFile?> _existingPageFile(Directory staging, int index) async {
    for (final String ext in kDownloadPageExtensions) {
      final String name = downloadPageFileName(index, ext);
      final File file = File(p.join(staging.path, name));
      if (await file.exists() && await file.length() > 0) {
        return _PageFile(relativeUrl: name, file: file);
      }
    }
    return null;
  }

  Future<void> _deleteChapterDirectory(MangaDownloadJobRow job) async {
    try {
      final EpubBookRow? row = await _database.getEpubBook(job.bookKey);
      if (row == null) return;
      await DownloadLibraryIndex(
        _database,
      ).deleteChapter(bookKey: job.bookKey, chapterKey: job.chapterKey);
      final Directory staging = downloadStagingDirectory(
        row.extractDir,
        job.jobId,
      );
      if (await staging.exists()) {
        await staging.delete(recursive: true);
        await _cleanupStagingParent(staging);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaDownloadService.deleteChapter ${job.jobId}',
        error,
        stack,
      );
    }
  }

  static void _throwIfCancelled(_CancelToken token) {
    if (token.stopped) throw const _Stopped();
    if (token.cancelled) throw const _Cancelled();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Stopped implements Exception {
  const _Stopped();
}
