/// Rebuild download index：只重链书架成员。
///
/// 对每个 Library Manga（在线条目 / Local source 条目），在**当前** Content root
/// 的 `downloads/{source}/{manga}` 或 `local/{manga}` 里重新定位章节，更新
/// `epub_books.extractDir` 与 `manga_chapter_dirs` 映射。
///
/// 匹配顺序（spec「Rebuild download index」）：
///  1. `pages.json` 的稳定 ID（Source runtime / extension / source id / manga key /
///     chapter key）；
///  2. 已记录且仍在 `downloads` 内的目录；
///  3. `downloads` 无 manifest 目录的文件夹名回退。`local` 无 manifest 的目录
///     不按标题匹配。
///
/// 只查询 `membership=true` 的 Manga：非书架行不被读取、改写、重链或删除。
/// 不新增 Manga、不改 Library membership、不分配 Tag；发现新作品的职责属于
/// 「检索已下载」（见 `download_manga_discovery.dart` 的发现模块）。
/// 本服务不引入「本机章节」概念：源章节列表为空时不会把磁盘容器合成为章节。
///
/// 找不到文件的章节**不删除记录**：书目行与任务行原样保留，磁盘判据返回
/// 「找不到」，任务行的 `done` 状态使它显示为 Missing。整个流程只增改数据库
/// 行，不移动、复制、删除或重命名任何用户文件；唯一会写的用户文件是按本地
/// 图源扫描规则补写缺失的可见 `cover.jpg`（已有封面绝不覆盖，见
/// [LocalSourceCoverService]）。
///
/// 只接收当前 Content root 的 `downloads` 与 `local` 两个根，因此结构上
/// 不可能读取旧 Content root，也不会扫描 `autobackup`。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:fushi/src/media/manga/download/download_identity.dart';
import 'package:fushi/src/media/manga/download/download_library_changes.dart';
import 'package:fushi/src/media/manga/download/download_library_scanner.dart';
import 'package:fushi/src/media/manga/download/download_manga_relinker.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 一次重建的进度快照。
class RebuildDownloadIndexProgress {
  const RebuildDownloadIndexProgress({
    required this.completed,
    required this.total,
    this.currentTitle,
  });

  /// 已处理的书目数。
  final int completed;

  /// 本次要处理的书目总数。
  final int total;

  /// 正在处理的作品标题（给进度框用）。
  final String? currentTitle;

  /// 0..1；[total] 为 0 时为 null（不确定态）。
  double? get fraction => total <= 0 ? null : completed / total;
}

/// 取消令牌。服务在每本书 / 每一章之间检查；取消后返回 `cancelled: true` 的
/// 部分报告，已完成的更新保留（重建是幂等的）。
class RebuildDownloadIndexCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 一次重建的结果摘要。
class RebuildDownloadIndexReport {
  const RebuildDownloadIndexReport({
    required this.booksScanned,
    this.booksMatched = 0,
    required this.booksRelinked,
    required this.booksMissing,
    required this.booksSkipped,
    this.booksAmbiguous = 0,
    required this.chaptersRelinked,
    required this.chaptersMissing,
    required this.chaptersSkipped,
    required this.failed,
    required this.cancelled,
  });

  const RebuildDownloadIndexReport.empty()
    : booksScanned = 0,
      booksMatched = 0,
      booksRelinked = 0,
      booksMissing = 0,
      booksSkipped = 0,
      booksAmbiguous = 0,
      chaptersRelinked = 0,
      chaptersMissing = 0,
      chaptersSkipped = 0,
      failed = 0,
      cancelled = false;

  /// 书架里参与重建的书目数（在线 + Local source）。
  final int booksScanned;

  /// 在磁盘上找到对应文件夹（`pages.json` 身份或文件名回退）的书目数。
  ///
  /// 与 [booksRelinked] 不同：已经指向正确目录、没有需要改写记录的第二次重建
  /// 也计为 matched。
  final int booksMatched;

  /// `extractDir` 或章映射实际被更新的书目数。
  final int booksRelinked;

  /// 当前 Content root 下找不到漫画目录的书目数（记录保留）。
  final int booksMissing;

  /// 匹配有歧义而整本跳过的书目数（不猜）。
  final int booksSkipped;

  /// [booksSkipped] 中因为多个重复副本无法安全决定而跳过的数量。
  final int booksAmbiguous;

  /// 章路径/映射被新增或更新的章节数。
  final int chaptersRelinked;

  /// 下载索引曾认为已下载、但当前 Content root 下找不到文件的章节数
  /// （记录保留，显示 Missing）。从未下载的章节不计入。
  final int chaptersMissing;

  /// 因歧义跳过的章节数。
  final int chaptersSkipped;

  /// 单本处理失败数；失败不中断其余书目。
  final int failed;

  /// 用户中途取消。
  final bool cancelled;
}

/// 一次重建服务。显式注入当前 Content root 下的两个根，测试与生产走同一条路径。
class RebuildDownloadIndexService {
  const RebuildDownloadIndexService({
    required this.database,
    required this.downloadsRoot,
    required this.localComicRoot,
  });

  final FushiDatabase database;

  /// 当前 Content root 的 Download library 根。
  final Directory downloadsRoot;

  /// 当前 Content root 的 Local source root。
  final Directory localComicRoot;

  Future<RebuildDownloadIndexReport> run({
    RebuildDownloadIndexCancelToken? cancelToken,
    void Function(RebuildDownloadIndexProgress progress)? onProgress,
  }) async {
    try {
      return await _run(cancelToken: cancelToken, onProgress: onProgress);
    } finally {
      // 票 12：完成后通知已打开的作品详情页重算已下载状态。异常 / 取消时也发：
      // 已经写下的部分关联同样可能改变页面显示。
      DownloadLibraryChanges.instance.notifyChanged();
    }
  }

  /// 实际重建流程；[run] 负责在结束时广播「下载索引可能变了」。
  Future<RebuildDownloadIndexReport> _run({
    RebuildDownloadIndexCancelToken? cancelToken,
    void Function(RebuildDownloadIndexProgress progress)? onProgress,
  }) async {
    // 只重链书架成员：非书架 Manga 不读取、不改写、不重链、不删除。
    final List<EpubBookRow> rows = await database.getLibraryEpubBooks();
    final List<_BookCandidate> books = <_BookCandidate>[];
    for (final EpubBookRow row in rows) {
      final OnlineMangaLibraryEntry? online = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
      if (online != null) {
        books.add(_BookCandidate.online(row, online));
        continue;
      }
      final LocalSourceMetadata? local = LocalSourceMetadata.tryParse(
        row.sourceMetadata,
      );
      if (local != null) books.add(_BookCandidate.local(row, local));
    }

    final _DownloadScan downloadScan = await _scanDownloadLibrary();
    // 书架里的本地作品重链时补齐缺失封面：与进入本地图源页同一条补齐路径
    // （幂等、绝不覆盖已有封面、坏页跳过）。
    final LocalSourceCoverService coverService = LocalSourceCoverService(
      db: database,
    );
    final List<LocalSourceManga> localMangas = await scanLocalSourceRoot(
      localComicRoot,
    );
    // Missing 只适用于「下载索引曾认为已下载」的章（含 done 任务或已有映射）；
    // 从未下载的章不算缺失，否则一个 500 话的作品会报 498 章 missing。
    final Map<String, Set<String>> doneJobChapterKeys =
        await _doneChapterKeysByBook();

    int booksMatched = 0;
    int booksRelinked = 0;
    int booksMissing = 0;
    int booksSkipped = 0;
    int booksAmbiguous = 0;
    int chaptersRelinked = 0;
    int chaptersMissing = 0;
    int chaptersSkipped = 0;
    int failed = 0;
    bool cancelled = false;

    for (int index = 0; index < books.length; index++) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final _BookCandidate book = books[index];
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: index,
          total: books.length,
          currentTitle: book.row.title,
        ),
      );
      try {
        final _BookOutcome outcome = book.online != null
            ? await _relinkOnlineBook(
                book.row,
                book.online!,
                downloadScan,
                doneJobChapterKeys[book.row.bookKey] ?? const <String>{},
                cancelToken,
              )
            : await _relinkLocalBook(
                book.row,
                book.local!,
                localMangas,
                coverService,
              );
        if (outcome.cancelled) {
          cancelled = true;
          // 取消发生在书内：保留这本书已经写下的部分更新，报告截止到这里。
          if (outcome.matched) booksMatched++;
          booksRelinked += outcome.relinked ? 1 : 0;
          chaptersRelinked += outcome.chaptersRelinked;
          chaptersMissing += outcome.chaptersMissing;
          chaptersSkipped += outcome.chaptersSkipped;
          if (outcome.missing) booksMissing++;
          if (outcome.skipped) booksSkipped++;
          if (outcome.ambiguous) booksAmbiguous++;
          break;
        }
        if (outcome.matched) booksMatched++;
        if (outcome.relinked) booksRelinked++;
        if (outcome.missing) booksMissing++;
        if (outcome.skipped) booksSkipped++;
        if (outcome.ambiguous) booksAmbiguous++;
        chaptersRelinked += outcome.chaptersRelinked;
        chaptersMissing += outcome.chaptersMissing;
        chaptersSkipped += outcome.chaptersSkipped;
      } on Object {
        failed++;
      }
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: index + 1,
          total: books.length,
          currentTitle: book.row.title,
        ),
      );
    }
    // 取消时也补一次最终进度，UI 不会停在旧值上。
    if (cancelled) {
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: books.length,
          total: books.length,
          currentTitle: null,
        ),
      );
    }

    return RebuildDownloadIndexReport(
      booksScanned: books.length,
      booksMatched: booksMatched,
      booksRelinked: booksRelinked,
      booksMissing: booksMissing,
      booksSkipped: booksSkipped,
      booksAmbiguous: booksAmbiguous,
      chaptersRelinked: chaptersRelinked,
      chaptersMissing: chaptersMissing,
      chaptersSkipped: chaptersSkipped,
      failed: failed,
      cancelled: cancelled,
    );
  }

  // ── 在线条目 ────────────────────────────────────────────────────────

  Future<_BookOutcome> _relinkOnlineBook(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
    _DownloadScan scan,
    Set<String> doneJobChapterKeys,
    RebuildDownloadIndexCancelToken? cancelToken,
  ) async {
    final Map<String, MangaChapterDirRow> existingMappings = await database
        .getMangaChapterDirRowsForBook(row.bookKey);
    // 下载索引认为已下载的章：有章容器映射，或有 done 任务行。
    final Set<String> indexedChapterKeys = <String>{
      ...existingMappings.keys,
      ...doneJobChapterKeys,
    };
    final int indexedChapterCount = entry.chapters
        .where(
          (OnlineMangaChapter chapter) =>
              indexedChapterKeys.contains(chapter.key),
        )
        .length;

    final _MangaFolderMatch match = _matchOnlineMangaFolder(row, entry, scan);
    if (match.folder == null) {
      return _BookOutcome(
        relinked: false,
        missing: !match.ambiguous && indexedChapterCount > 0,
        skipped: match.ambiguous,
        ambiguous: match.ambiguous,
        chaptersMissing: match.ambiguous ? 0 : indexedChapterCount,
        chaptersSkipped: match.ambiguous ? indexedChapterCount : 0,
        ambiguousPaths: match.ambiguous
            ? <String>{
                for (final DownloadMangaFolderOnDisk candidate
                    in match.candidates)
                  _canonicalPath(candidate.directory.path),
              }
            : const <String>{},
      );
    }
    final DownloadMangaFolderOnDisk folder = match.folder!;
    // 单章 Local source 作品的根 pages.json 不是章容器：不写映射，但章确实
    // 已下载（manifest + 页齐）。把它从「曾认为已下载」集合里排除，避免报告
    // 成 Missing；已下载状态仍由 manifest 扫描提供。
    final Set<String> rootManifestPresentKeys =
        await _rootManifestPresentChapterKeys(folder, entry);
    // 文件夹定位之后的重链逻辑与「复用现有下载文件夹」共用一份实现：
    // pages.json 稳定 ID 优先，已有映射 / 容器名回退兜底，只增改不删除。
    final DownloadMangaRelinkResult result = await relinkDownloadMangaFolder(
      database: database,
      row: row,
      entry: entry,
      mangaFolder: folder.directory,
      chapters: folder.chapters,
      indexedChapterKeys: indexedChapterKeys.difference(
        rootManifestPresentKeys,
      ),
      isCancelled: () => cancelToken?.isCancelled ?? false,
    );
    return _BookOutcome(
      matched: true,
      relinked: result.relinked,
      missing: !result.cancelled && result.chaptersMissing > 0,
      chaptersRelinked: result.chaptersRelinked,
      chaptersMissing: result.chaptersMissing,
      chaptersSkipped: result.chaptersSkipped,
      cancelled: result.cancelled,
      ambiguousPaths: <String>{
        for (final DownloadMangaFolderOnDisk duplicate in match.duplicates)
          _canonicalPath(duplicate.directory.path),
      },
    );
  }

  /// 根 manifest 已完整落盘的章 key（不写映射，但也不该报 Missing）。
  Future<Set<String>> _rootManifestPresentChapterKeys(
    DownloadMangaFolderOnDisk folder,
    OnlineMangaLibraryEntry entry,
  ) async {
    final MangaPagesManifest? rootManifest = folder.rootManifest;
    if (rootManifest == null) return const <String>{};
    if (!MangaDownloadIdentity.ofEntry(entry).matchesManifest(rootManifest)) {
      return const <String>{};
    }
    if (await readDownloadLibraryChapterPayload(folder.directory) == null) {
      return const <String>{};
    }
    return <String>{rootManifest.chapterKey};
  }

  // ── Local source 条目 ───────────────────────────────────────────────

  Future<_BookOutcome> _relinkLocalBook(
    EpubBookRow row,
    LocalSourceMetadata metadata,
    List<LocalSourceManga> mangas,
    LocalSourceCoverService coverService,
  ) async {
    // Ticket 10：源未安装的下载内容被降级成指向 `downloads/{source}/{manga}`
    // 的本地条目。它不在 local 扫描结果里，按记录路径原地刷新即可。
    if (_isWithinDownloadsRoot(row.extractDir)) {
      final Directory directory = Directory(row.extractDir);
      if (await directory.exists()) {
        final String relative = p
            .relative(directory.path, from: downloadsRoot.path)
            .replaceAll('\\', '/');
        try {
          final LocalSourceManga? scanned = await scanLocalSourceMangaDirectory(
            directory,
            relativePath: relative,
          );
          if (scanned != null) {
            return await _refreshLocalMangaRow(row, scanned);
          }
        } on Object {
          // 读盘失败按「找不到」处理，继续走 local 名称回退。
        }
      }
    }

    final _LocalMangaMatch match = _matchLocalManga(row, metadata, mangas);
    if (match.manga == null) {
      final List<LocalSourceChapterRecord> existing = decodeLocalSourceChapters(
        row.chaptersJson,
      );
      return _BookOutcome(
        missing: !match.ambiguous,
        skipped: match.ambiguous,
        ambiguous: match.ambiguous,
        chaptersMissing: match.ambiguous ? 0 : existing.length,
        chaptersSkipped: match.ambiguous ? existing.length : 0,
        ambiguousPaths: match.ambiguous
            ? <String>{
                for (final LocalSourceManga candidate in match.candidates)
                  _canonicalPath(candidate.directoryPath),
              }
            : const <String>{},
      );
    }
    // Rebuild 是本地作品补封面的一条独立入口：用户不进入本地图源页也应看到
    // 封面。只对 Local source root 里的作品做（downloads 降级条目不在本 spec
    // 的封面范围内）。
    final LocalSourceManga found = await _withGeneratedCover(
      match.manga!,
      coverService,
    );
    return _refreshLocalMangaRow(row, found);
  }

  /// 补齐缺失封面后返回带真实封面相对路径的扫描条目；生成失败时原样返回
  /// （重建索引不因封面失败而失败）。
  Future<LocalSourceManga> _withGeneratedCover(
    LocalSourceManga manga,
    LocalSourceCoverService coverService,
  ) async {
    try {
      final LocalSourceCoverResult result = await coverService
          .generateMissingCover(manga);
      final String? cover = result.coverRelativePath;
      if (cover == null) return manga;
      return withLocalSourceCoverRelativePath(manga, cover);
    } on Object {
      return manga;
    }
  }

  /// 用一次扫描结果刷新 Local source 条目（local 或 downloads 降级条目）。
  Future<_BookOutcome> _refreshLocalMangaRow(
    EpubBookRow row,
    LocalSourceManga found,
  ) async {
    final List<LocalSourceChapterRecord> scanned = <LocalSourceChapterRecord>[
      for (final LocalSourceChapter chapter in found.chapters)
        LocalSourceChapterRecord(
          key: chapter.key,
          name: chapter.name,
          relativePath: chapter.relativePath,
        ),
    ];
    final String chaptersJson = encodeLocalSourceChapters(scanned);
    // 重建索引只刷新磁盘描述；当前章是阅读状态，原样保留。
    final LocalSourceMetadata updatedMetadata = LocalSourceMetadata(
      relativePath: found.relativePath,
      currentChapterKey: LocalSourceMetadata.tryParse(
        row.sourceMetadata,
      )?.currentChapterKey,
    );
    final String? coverPath = localSourceCoverRelativePath(found);
    final bool moved = !_samePath(row.extractDir, found.directoryPath);
    final bool changed =
        moved ||
        row.chaptersJson != chaptersJson ||
        row.chapterCount != found.pageCount ||
        row.coverPath != coverPath ||
        row.sourceMetadata != updatedMetadata.encode();

    if (changed) {
      await (database.update(
        database.epubBooks,
      )..where((t) => t.bookKey.equals(row.bookKey))).write(
        EpubBooksCompanion(
          extractDir: Value<String>(found.directoryPath),
          coverPath: Value<String?>(coverPath),
          chapterCount: Value<int>(found.pageCount),
          chaptersJson: Value<String>(chaptersJson),
          sourceMetadata: Value<String?>(updatedMetadata.encode()),
        ),
      );
    }
    return _BookOutcome(
      matched: true,
      relinked: changed,
      chaptersRelinked: moved ? scanned.length : 0,
    );
  }

  // ── 匹配 ────────────────────────────────────────────────────────────

  _MangaFolderMatch _matchOnlineMangaFolder(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
    _DownloadScan scan,
  ) {
    // 1) `pages.json` 稳定 ID：与文件夹复用共用同一份身份判据（含占位包容忍
    //    与扩展包 tie-breaker）。`local` 里带 manifest 的目录与 `downloads`
    //    一起参与匹配，把本地已有文件关联回在线 Manga。多个目录都匹配 =
    //    歧义，不猜。
    final List<DownloadMangaFolderOnDisk> identityMatches =
        matchingDownloadMangaFolders(
          scan.allFolders,
          MangaDownloadIdentity.ofEntry(entry),
        );
    if (identityMatches.length == 1) {
      return _MangaFolderMatch(identityMatches.single);
    }
    if (identityMatches.length > 1) {
      // 重复副本（`(2)` 等）按规范只做两个安全偏好：已记录目录、最新完整
      // 副本；两者都决定不了就跳过并报告，绝不猜。
      final DownloadMangaFolderOnDisk? preferred = _preferDuplicateCopy(
        row,
        identityMatches,
      );
      if (preferred != null) {
        return _MangaFolderMatch(
          preferred,
          duplicates: <DownloadMangaFolderOnDisk>[
            for (final DownloadMangaFolderOnDisk candidate in identityMatches)
              if (!_samePath(
                candidate.directory.path,
                preferred.directory.path,
              ))
                candidate,
          ],
        );
      }
      return _MangaFolderMatch.ambiguous(identityMatches);
    }

    // 2) 库里的 extractDir 仍是**当前**下载根内的有效目录：沿用应用自己写下的
    //    映射。`local` 路径不参与文件名/路径回退（规范：无 manifest 不做匹配）。
    final String recordedPath = p.normalize(row.extractDir);
    if (isLocalSourcePathWithinRoot(recordedPath, downloadsRoot)) {
      for (final DownloadMangaFolderOnDisk folder in scan.allFolders) {
        if (_samePath(folder.directory.path, recordedPath)) {
          return _MangaFolderMatch(folder);
        }
      }
    }

    // 3) 文件夹名回退（标题净化后的大小写不敏感比较）。多候选 = 歧义，不猜。
    //    只回退 `downloads` 里的旧目录；`local` 无 manifest 的目录绝不算。
    final String expected = sanitizeDownloadLibrarySegment(
      entry.series.title,
    ).toLowerCase();
    final List<DownloadMangaFolderOnDisk> nameMatches =
        <DownloadMangaFolderOnDisk>[
          for (final DownloadMangaFolderOnDisk folder in scan.downloadsFolders)
            if (folder.mangaFolderName.toLowerCase() == expected) folder,
        ];
    if (nameMatches.length == 1) return _MangaFolderMatch(nameMatches.single);
    if (nameMatches.length > 1) {
      return _MangaFolderMatch.ambiguous(nameMatches);
    }
    return const _MangaFolderMatch.none();
  }

  /// 多个重复副本之间做安全选择：已记录目录优先，否则最新完整副本。
  ///
  /// 都没有明显胜者（时间并列 / 没有完整副本）时返回 null，由调用方按歧义
  /// 跳过并报告——绝不猜测。
  DownloadMangaFolderOnDisk? _preferDuplicateCopy(
    EpubBookRow row,
    List<DownloadMangaFolderOnDisk> candidates,
  ) {
    final String recorded = _canonicalPath(row.extractDir);
    for (final DownloadMangaFolderOnDisk candidate in candidates) {
      if (_canonicalPath(candidate.directory.path) == recorded) {
        return candidate;
      }
    }
    DateTime? newest;
    DownloadMangaFolderOnDisk? winner;
    bool tied = false;
    for (final DownloadMangaFolderOnDisk candidate in candidates) {
      final DateTime? at = _newestCompleteDownloadedAt(candidate);
      if (at == null) continue;
      if (newest == null || at.isAfter(newest)) {
        newest = at;
        winner = candidate;
        tied = false;
      } else if (at.isAtSameMomentAs(newest)) {
        tied = true;
      }
    }
    if (winner == null || tied) return null;
    return winner;
  }

  /// 目录里最新一个**完整**章节容器的 `downloadedAt`（没有完整章 = null）。
  static DateTime? _newestCompleteDownloadedAt(
    DownloadMangaFolderOnDisk folder,
  ) {
    DateTime? newest;
    for (final ChapterContainerOnDisk container in folder.chapters) {
      final MangaPagesManifest? manifest = container.manifest;
      if (!container.complete || manifest == null) continue;
      if (newest == null || manifest.downloadedAt.isAfter(newest)) {
        newest = manifest.downloadedAt;
      }
    }
    return newest;
  }

  /// 记录路径是否在当前 Download library 根内（源未安装的降级条目）。
  bool _isWithinDownloadsRoot(String path) =>
      isLocalSourcePathWithinRoot(path, downloadsRoot);

  _LocalMangaMatch _matchLocalManga(
    EpubBookRow row,
    LocalSourceMetadata metadata,
    List<LocalSourceManga> mangas,
  ) {
    // 1) 作品身份 = 绝对目录路径（ADR 0013）：未搬动时 bookKey 直接命中。
    for (final LocalSourceManga manga in mangas) {
      if (localSourceBookKeyFor(manga.directoryPath) == row.bookKey) {
        return _LocalMangaMatch(manga);
      }
    }
    // 2) 存下来的相对路径（切换 Content root 后目录结构通常不变）。
    final String expectedRelative = _normalizeRelative(metadata.relativePath);
    for (final LocalSourceManga manga in mangas) {
      if (_normalizeRelative(manga.relativePath) == expectedRelative) {
        return _LocalMangaMatch(manga);
      }
    }
    // 3) 文件夹名回退（用户在同一根内改名）。多候选 = 歧义，不猜。
    final String expectedName = _localFolderName(row.title);
    final List<LocalSourceManga> nameMatches = <LocalSourceManga>[
      for (final LocalSourceManga manga in mangas)
        if (_localFolderName(p.basename(manga.directoryPath)) == expectedName)
          manga,
    ];
    if (nameMatches.length == 1) return _LocalMangaMatch(nameMatches.single);
    if (nameMatches.length > 1) {
      return _LocalMangaMatch.ambiguous(nameMatches);
    }
    return const _LocalMangaMatch.none();
  }

  /// `bookKey → {chapterKey}`：任务表里状态为 `done` 的章节（下载索引的另一份
  /// 证据；映射丢失时仍能把文件缺失报成 Missing）。
  Future<Map<String, Set<String>>> _doneChapterKeysByBook() async {
    final List<MangaDownloadJobRow> rows = await database.listMangaDownloadJobs(
      statuses: const <String>{MangaDownloadJobStatus.done},
    );
    final Map<String, Set<String>> byBook = <String, Set<String>>{};
    for (final MangaDownloadJobRow row in rows) {
      if (row.kind != MangaDownloadJobKind.chapter) continue;
      byBook.putIfAbsent(row.bookKey, () => <String>{}).add(row.chapterKey);
    }
    return byBook;
  }

  // ── 扫描 ────────────────────────────────────────────────────────────

  Future<_DownloadScan> _scanDownloadLibrary() async => _DownloadScan(
    downloadsFolders: await scanDownloadLibraryFolders(
      downloadsRoot,
      readComplete: true,
    ),
    localFolders: await _scanLocalManifestFolders(),
  );

  /// `local` 里带 manifest 的作品目录。
  ///
  /// 只收第一份 `pages.json` 可解析的目录：无 manifest 的本地目录不按标题
  /// 猜测、不参与在线身份匹配。扫描完整的章节容器（含完整性）以便关联后立即
  /// 写映射；单章作品把 `pages.json` 放在作品根，用
  /// [DownloadMangaFolderProbe.toFolder] 把它保留为**目录身份**，不伪造成
  /// 名为漫画目录的章容器（否则会写出不可用的 `<manga>/<manga>` 映射）。
  Future<List<DownloadMangaFolderOnDisk>> _scanLocalManifestFolders() async {
    final List<DownloadMangaFolderOnDisk> folders =
        <DownloadMangaFolderOnDisk>[];
    for (final DownloadMangaFolderProbe probe in await probeLocalMangaFolders(
      localComicRoot,
    )) {
      if (probe.manifest == null) continue;
      final DownloadMangaFolderOnDisk probed = probe.toFolder();
      final List<ChapterContainerOnDisk> chapters =
          await scanDownloadChapterContainers(
            probe.directory,
            readComplete: true,
          );
      folders.add(
        DownloadMangaFolderOnDisk(
          directory: probe.directory,
          chapters: chapters,
          rootManifest: probed.rootManifest,
        ),
      );
    }
    return folders;
  }
}

// ── 内部模型 ──────────────────────────────────────────────────────────

class _BookCandidate {
  const _BookCandidate.online(this.row, OnlineMangaLibraryEntry this.online)
    : local = null;

  const _BookCandidate.local(this.row, LocalSourceMetadata this.local)
    : online = null;

  final EpubBookRow row;
  final OnlineMangaLibraryEntry? online;
  final LocalSourceMetadata? local;
}

class _BookOutcome {
  const _BookOutcome({
    this.matched = false,
    this.relinked = false,
    this.missing = false,
    this.skipped = false,
    this.ambiguous = false,
    this.chaptersRelinked = 0,
    this.chaptersMissing = 0,
    this.chaptersSkipped = 0,
    this.cancelled = false,
    this.ambiguousPaths = const <String>{},
  });

  /// 磁盘上找到了这部作品的文件夹（身份或文件名回退）。
  final bool matched;

  final bool relinked;
  final bool missing;
  final bool skipped;

  /// [skipped] 中因为重复副本无法安全决定而跳过的。
  final bool ambiguous;

  final int chaptersRelinked;
  final int chaptersMissing;
  final int chaptersSkipped;
  final bool cancelled;

  /// 因为歧义没有被认领的磁盘目录（规范：不猜）。
  final Set<String> ambiguousPaths;
}

class _DownloadScan {
  const _DownloadScan({
    required this.downloadsFolders,
    required this.localFolders,
  });

  /// `downloads/<source>/<manga>` 下的全部漫画目录。
  final List<DownloadMangaFolderOnDisk> downloadsFolders;

  /// `local/<manga>` 下带 `pages.json` 的漫画目录（票 12 在线关联用）。
  final List<DownloadMangaFolderOnDisk> localFolders;

  /// 在线 Manga 身份匹配的候选：两个根一起算身份，重复副本一起评估。
  List<DownloadMangaFolderOnDisk> get allFolders => <DownloadMangaFolderOnDisk>[
    ...downloadsFolders,
    ...localFolders,
  ];
}

class _MangaFolderMatch {
  const _MangaFolderMatch(
    this.folder, {
    this.duplicates = const <DownloadMangaFolderOnDisk>[],
  }) : ambiguous = false,
       candidates = const <DownloadMangaFolderOnDisk>[];

  const _MangaFolderMatch.ambiguous(this.candidates)
    : folder = null,
      ambiguous = true,
      duplicates = const <DownloadMangaFolderOnDisk>[];

  const _MangaFolderMatch.none()
    : folder = null,
      ambiguous = false,
      candidates = const <DownloadMangaFolderOnDisk>[],
      duplicates = const <DownloadMangaFolderOnDisk>[];

  final DownloadMangaFolderOnDisk? folder;
  final bool ambiguous;
  final List<DownloadMangaFolderOnDisk> candidates;

  /// 身份相同的未采用副本（报告用；原样保留在磁盘上）。
  final List<DownloadMangaFolderOnDisk> duplicates;
}

class _LocalMangaMatch {
  const _LocalMangaMatch(this.manga)
    : ambiguous = false,
      candidates = const <LocalSourceManga>[];

  const _LocalMangaMatch.ambiguous(this.candidates)
    : manga = null,
      ambiguous = true;

  const _LocalMangaMatch.none()
    : manga = null,
      ambiguous = false,
      candidates = const <LocalSourceManga>[];

  final LocalSourceManga? manga;
  final bool ambiguous;
  final List<LocalSourceManga> candidates;
}

// ── 纯 helper ─────────────────────────────────────────────────────────

bool _samePath(String a, String b) =>
    p.equals(p.canonicalize(a), p.canonicalize(b));

String _canonicalPath(String path) => p.canonicalize(p.normalize(path));

String _normalizeRelative(String value) =>
    value.replaceAll('\\', '/').toLowerCase();

/// Local source 的文件夹名比较：只做大小写折叠（用户目录名按原样保留）。
String _localFolderName(String value) => value.trim().toLowerCase();
