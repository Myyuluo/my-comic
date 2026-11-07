import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';

import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 假运行时：页表固定三页，取图返回真实 PNG 字节（尺寸随页序变，好核 manga.json）。
///
/// [OnlineMangaPageRef] 是密封类，假适配器借用数据形状最简单的
/// [InterconnectMangaPageRef] 当页引用——下载服务只看 `index`，不看里面是谁的。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  static const int pageCount = 3;

  /// 每页被取了几次（续跑 / 幂等断言用）。
  final Map<int, int> fetchCounts = <int, int>{};

  /// 某页要失败几次（按调用顺序递减）。
  final Map<int, int> failuresLeft = <int, int>{};

  /// 非空时取页先卡在这里（取消用）。
  Completer<void>? gate;

  static Uint8List pngOf(int index) => Uint8List.fromList(
        img.encodePng(img.Image(width: 100 + index, height: 150 + index)),
      );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// Source 显示名（路径净化测试会改它）。
  String sourceLabelText = 'Fake';

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      sourceLabelText;

  @override
  Future<OnlineMangaRefreshResult> refresh(
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async =>
      <OnlineMangaPageRef>[
        for (int i = 0; i < pageCount; i++)
          InterconnectMangaPageRef(index: i, bookKey: 'fake', remoteIndex: i),
      ];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    fetchCounts[page.index] = (fetchCounts[page.index] ?? 0) + 1;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    final int left = failuresLeft[page.index] ?? 0;
    if (left > 0) {
      failuresLeft[page.index] = left - 1;
      throw StateError('boom page ${page.index}');
    }
    return pngOf(page.index);
  }

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

/// 记录 update / stop 顺序的假保活（BUG-2714）。
class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<String> events = <String>[];
  final List<int?> percents = <int?>[];

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    events.add('update:$title');
    percents.add(percent);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }
}

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
    );

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late List<Duration> waits;
  late String bookKey;
  late String bookDir;

  MangaDownloadService build({DownloadKeepAlive? keepAlive}) =>
      MangaDownloadService(
        database: db,
        serviceFor: (OnlineMangaRuntimeKind runtime) => library,
        keepAlive: keepAlive,
        wait: (Duration duration) async {
          waits.add(duration);
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-manga-download-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
    waits = <Duration>[];
    final EpubBookRow row = await library.add(_entry());
    bookKey = row.bookKey;
    bookDir = row.extractDir;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MangaDownloadJobRow> jobOf(String chapterKey) async =>
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: chapterKey,
      ))!;

  test('start 清理旧的 mokuro 卷任务行，章节任务保留', () async {
    final MangaDownloadService downloads = build();
    addTearDown(downloads.dispose);
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'legacy-mokuro-01',
        kind: MangaDownloadJobKind.mokuroVolume,
        bookKey: 'mokuro:Series',
        chapterKey: 'Series 01',
        runtime: 'mokuro_moe',
        title: 'Series · Series 01',
        chapterTitle: 'Series 01',
        status: const Value<String>(MangaDownloadJobStatus.done),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'chapter-01',
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: 'ch-1',
        runtime: 'mihon',
        title: 'Fixture',
        chapterTitle: 'ch-1',
        status: const Value<String>(MangaDownloadJobStatus.done),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 2,
        updatedAt: 2,
      ),
    );

    await downloads.start();

    expect(await db.listMangaDownloadJobs(), hasLength(1));
    expect((await db.listMangaDownloadJobs()).single.jobId, 'chapter-01');
  });

  test('入队 → worker 跑完：页图平铺 + pages.json、映射落库、行 done', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow queued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(queued.status, MangaDownloadJobStatus.queued);
    expect(queued.runtime, 'mihon');
    expect(queued.chapterTitle, 'Chapter 1');

    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.pagesDone, 3);
    expect(done.pagesTotal, 3);
    expect(done.completedAt, isNotNull);
    expect(done.lastError, isNull);

    // Download library：downloads/{source}/{manga}/{chapter}/001.png…
    expect(bookDir, p.join(root.path, 'downloads', 'Fake', 'Fixture series'));
    final Directory chapterDir = downloadChapterDirectory(bookDir, 'Chapter 1');
    for (int i = 1; i <= 3; i++) {
      final File page = File(
        p.join(chapterDir.path, downloadPageFileName(i - 1, '.png')),
      );
      expect(page.existsSync(), isTrue, reason: 'page $i 必须平铺落盘');
      expect(File('${page.path}.tmp').existsSync(), isFalse);
    }
    expect(
      Directory(p.join(chapterDir.path, 'images')).existsSync(),
      isFalse,
      reason: '新布局页图平铺，不再有 images/ 前缀',
    );
    expect(
      Directory(p.join(bookDir, '.staging')).existsSync(),
      isFalse,
      reason: '完成后 staging 应已 rename 走',
    );

    final MangaPagesManifest? manifest = await readPagesManifest(chapterDir);
    expect(manifest, isNotNull);
    expect(manifest!.sourceRuntime, 'mihon');
    expect(manifest.sourceId, '1');
    expect(manifest.sourceName, 'Fake');
    expect(manifest.extensionPackage, 'org.example.fixture');
    expect(manifest.mangaKey, '/series/fixture');
    expect(manifest.mangaTitle, 'Fixture series');
    expect(manifest.chapterKey, '/chapter/1');
    expect(manifest.chapterName, 'Chapter 1');
    expect(manifest.chapterNumber, 1);
    expect(manifest.chapterUrl, '/chapter/1');
    expect(
      manifest.payload.images.map((MokuroImage image) => image.url).toList(),
      <String>['001.png', '002.png', '003.png'],
    );
    expect(manifest.payload.images[0].size.width, 100);
    expect(manifest.payload.images[0].size.height, 150);
    expect(manifest.payload.images[2].size.width, 102);
    expect(manifest.payload.images[2].size.height, 152);

    // 数据库映射：bookKey + chapterKey → 实际目录名。
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isTrue,
    );
    expect(waits, isEmpty);
    downloads.dispose();
  });

  test('下载中只有 .staging 有内容：正式章目录与索引要等整章 rename 后才出现', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
    expect(staging.existsSync(), isTrue, reason: '下载中的页只在 staging 里');
    final Directory chapterDir = downloadChapterDirectory(bookDir, 'Chapter 1');
    expect(chapterDir.existsSync(), isFalse, reason: '半成品不得出现在正式位置');
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isFalse,
      reason: '半成品不进已下载索引',
    );

    adapter.gate!.complete();
    await downloads.whenIdle;
    expect(staging.existsSync(), isFalse);
    expect(chapterDir.existsSync(), isTrue);
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
    downloads.dispose();
  });

  test('目标章目录已存在时不覆盖：内容进确定后缀，映射指向实际目录', () async {
    final Directory existing = downloadChapterDirectory(bookDir, 'Chapter 1');
    await existing.create(recursive: true);
    final File sentinel = File(p.join(existing.path, 'keep.txt'));
    await sentinel.writeAsString('do not touch');

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(await sentinel.readAsString(), 'do not touch');
    expect(existing.listSync(), hasLength(1), reason: '已有目录内容不得被覆盖');
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1 (2)');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1 (2)').existsSync(),
      isTrue,
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
    downloads.dispose();
  });

  test('source / manga / chapter 目录段经过基础净化', () async {
    adapter.sourceLabelText = 'Bad:Source';
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter: 1?',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    );
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: _entry().runtime,
      extensionPackage: _entry().extensionPackage,
      sourceId: _entry().sourceId,
      series: const OnlineMangaSeries(
        key: '/series/bad-names',
        title: 'Fixture: Series?',
        raw: <String, Object?>{'url': '/series/bad-names'},
      ),
      chapters: const <OnlineMangaChapter>[chapter],
    );
    // 入库就会按净化后的 source / manga 建目录；下载章节名同样要净化。
    final EpubBookRow badRow = await library.add(entry);
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: entry,
      chapter: chapter,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(
      badRow.extractDir,
      p.join(root.path, 'downloads', 'Bad_Source', 'Fixture_ Series_'),
    );
    expect(
      downloadChapterDirectory(badRow.extractDir, 'Chapter_ 1_').existsSync(),
      isTrue,
      reason: '目录名按 Windows 非法字符净化',
    );
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      badRow.bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter_ 1_');
    downloads.dispose();
  });

  test('单页连续失败 3 次 → failed + last_error，退避表被按序调用', () async {
    adapter.failuresLeft[1] = 99;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow failed = await jobOf('/chapter/1');
    expect(failed.status, MangaDownloadJobStatus.failed);
    expect(failed.attemptCount, kMangaDownloadMaxAttempts);
    expect(failed.lastError, contains('boom page 1'));
    expect(waits, <Duration>[
      kMangaDownloadRetryBackoff[0],
      kMangaDownloadRetryBackoff[1],
    ]);
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isFalse,
      reason: '失败的半成品不得被当成已下载',
    );
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '正式章目录只在整章完成后才出现',
    );
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    // 半成品留在 .staging，供重试续跑。
    final Directory staging = downloadStagingDirectory(bookDir, failed.jobId);
    expect(staging.existsSync(), isTrue);
    expect(
      File(p.join(staging.path, downloadPageFileName(0, '.png'))).existsSync(),
      isTrue,
    );
    // 其余页只取一次：续跑认磁盘上已落地的页，不重下。
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[2], 1);
    expect(adapter.fetchCounts[1], kMangaDownloadMaxAttempts);
    downloads.dispose();
  });

  test('第 2 次成功 → done，退避只等了一次，已落地的页不重取', () async {
    adapter.failuresLeft[1] = 1;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.attemptCount, 1);
    expect(done.lastError, isNull, reason: '成功后清掉上一次的错误');
    expect(waits, <Duration>[kMangaDownloadRetryBackoff[0]]);
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[1], 2);
    expect(adapter.fetchCounts[2], 1);
    downloads.dispose();
  });

  test('failed 后 retry → 重置 queued 并跑成 done', () async {
    adapter.failuresLeft[0] = 99;
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.failed);

    adapter.failuresLeft.clear();
    await downloads.retry(job.jobId);
    await downloads.whenIdle;
    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.lastError, isNull);
    downloads.dispose();
  });

  test('取消 running 的任务 → cancelled，半成品目录被删', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    // 等 worker 真的进到取页（第一页已被请求）。
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.running);
    final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
    expect(staging.existsSync(), isTrue, reason: '页图先写 staging');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '完成前正式章目录不存在',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isFalse,
    );

    await downloads.cancel(job.jobId);
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(
      (await jobOf('/chapter/1')).status,
      MangaDownloadJobStatus.cancelled,
    );
    expect(staging.existsSync(), isFalse, reason: '取消要删半成品 staging');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
    );
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    downloads.dispose();
  });

  test('queued 的任务取消 → 直接 cancelled；再 enqueue 同章 → 重置成 queued', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: false,
    );
    await downloads.cancel(job.jobId);
    expect(
      (await jobOf('/chapter/2')).status,
      MangaDownloadJobStatus.cancelled,
    );
    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: true,
    );
    expect(again.jobId, job.jobId, reason: 'job_id 由身份三元组派生，稳定');
    expect(again.status, MangaDownloadJobStatus.queued);
    downloads.dispose();
  });

  test('重启：running 行复位成 queued 续跑', () async {
    final MangaDownloadService first = build();
    final MangaDownloadJobRow job = await first.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    // 模拟上一个进程死在 running：直接改状态，不起 worker。
    await db.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.running,
      updatedAt: 1,
    );
    first.dispose();

    final MangaDownloadService second = build();
    await second.start();
    await second.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    second.dispose();
  });

  test('同章重复入队幂等：done 且目录在 → 不重下、不重取', () async {
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(await db.listMangaDownloadJobs(), hasLength(1));
    await downloads.start();
    await downloads.whenIdle;
    expect(adapter.fetchCounts, <int, int>{0: 1, 1: 1, 2: 1});

    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(again.status, MangaDownloadJobStatus.done);
    await downloads.whenIdle;
    expect(
        adapter.fetchCounts,
        <int, int>{
          0: 1,
          1: 1,
          2: 1,
        },
        reason: '已下载的章不该再打源');

    // 目录被删 → 判据失效 → 重新排队（worker 在跑，行可能已被立刻领走）。
    await DownloadLibraryIndex(
      db,
    ).deleteChapter(bookKey: bookKey, chapterKey: '/chapter/1');
    final MangaDownloadJobRow requeued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(
      requeued.status,
      anyOf(MangaDownloadJobStatus.queued, MangaDownloadJobStatus.running),
    );
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    expect(
        adapter.fetchCounts,
        <int, int>{
          0: 2,
          1: 2,
          2: 2,
        },
        reason: '目录没了就得真的重下');
    downloads.dispose();
  });

  group('下载保活（BUG-2714）', () {
    test('worker 开跑即保活、报页进度；两章连跑中间不撤，排空后撤一次', () async {
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapters(
        entry: _entry(),
        chapters: _chapters,
        autoOcr: false,
      );
      expect(keepAlive.events, isEmpty, reason: '未 start 不该挂保活');

      await downloads.start();
      await downloads.whenIdle;

      expect(keepAlive.events.first, 'update:Fixture series');
      expect(keepAlive.events.last, 'stop');
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '队列没排空之前不能撤（后台里撤了就再也拉不起前台服务）',
      );
      expect(keepAlive.percents, contains(100));
      downloads.dispose();
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '已撤过，dispose 不重复 stop',
      );
    });

    test('跑到一半 dispose → 撤保活', () async {
      adapter.gate = Completer<void>();
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(keepAlive.events, isNot(contains('stop')));

      downloads.dispose();
      expect(keepAlive.events.last, 'stop');
      adapter.gate!.complete();
      await downloads.whenIdle;
      expect(keepAlive.events.where((String e) => e == 'stop'), hasLength(1));
    });
  });
}
