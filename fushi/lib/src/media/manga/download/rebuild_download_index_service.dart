/// Rebuild download index：re-link（票 09）+ 全量恢复（票 10）。
///
/// 第一段以书架为**主线**：对每个 Library Manga（在线条目 / Local source 条目），
/// 在**当前** Content root 的 `downloads/{source}/{manga}` 或 `local/{manga}`
/// 里重新定位章节，更新 `epub_books.extractDir` 与 `manga_chapter_dirs` 映射。
///
/// 匹配顺序（spec「Rebuild download index」规则 1）：
///  1. `pages.json` 的稳定 ID（Source runtime / extension / source id / manga key /
///     chapter key）；
///  2. 已有映射 / 文件夹名回退（章节目录无稳定身份时）。
///
/// 第二段扫描磁盘上书架没有的作品并补建 Library 条目（spec 规则 2/3）：
///  - `local` 作品按 Local source 扫描规则登记；
///  - `downloads` 作品在源已安装时按 `pages.json` 稳定身份建在线条目，源未安装
///    或缺少 `pages.json` 时降级为指向该文件夹的本地条目；
///  - 主动移出书架（`book_tombstones`）的作品跳过，绝不复活。
///
/// 找不到文件的章节**不删除记录**：书目行与任务行原样保留，磁盘判据返回
/// 「找不到」，任务行的 `done` 状态使它显示为 Missing。整个流程只增改数据库
/// 行，不移动、不删除任何用户文件；唯一会写的用户文件是按本地图源扫描规则
/// 补写缺失的可见 `cover.jpg`（已有封面绝不覆盖，见 [LocalSourceCoverService]），
/// 让只经 Rebuild 登记 / 重链的作品在书架与作品页也有封面。
///
/// 只接收当前 Content root 的 `downloads` 与 `local` 两个根，因此结构上
/// 不可能读取旧 Content root，也不会扫描 `autobackup`。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
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

/// 一次重建的结果摘要（re-link + 全量恢复）。
class RebuildDownloadIndexReport {
  const RebuildDownloadIndexReport({
    required this.booksScanned,
    this.booksAdded = 0,
    this.booksAddedOnline = 0,
    this.booksAddedLocal = 0,
    this.booksAddedLocalSourceMissing = 0,
    required this.booksRelinked,
    required this.booksMissing,
    required this.booksSkipped,
    this.booksSkippedTombstoned = 0,
    this.chaptersAdded = 0,
    required this.chaptersRelinked,
    required this.chaptersMissing,
    required this.chaptersSkipped,
    required this.failed,
    required this.cancelled,
  });

  const RebuildDownloadIndexReport.empty()
    : booksScanned = 0,
      booksAdded = 0,
      booksAddedOnline = 0,
      booksAddedLocal = 0,
      booksAddedLocalSourceMissing = 0,
      booksRelinked = 0,
      booksMissing = 0,
      booksSkipped = 0,
      booksSkippedTombstoned = 0,
      chaptersAdded = 0,
      chaptersRelinked = 0,
      chaptersMissing = 0,
      chaptersSkipped = 0,
      failed = 0,
      cancelled = false;

  /// 书架里参与重建的书目数（在线 + Local source）。
  final int booksScanned;

  /// 从 `downloads` / `local` 新补建的 Library 条目数。
  final int booksAdded;

  /// [booksAdded] 中建为在线条目的数量（源已安装）。
  final int booksAddedOnline;

  /// [booksAdded] 中建为本地条目的数量（`local` 作品、源未安装或
  /// 缺少 `pages.json` 的下载目录）。
  final int booksAddedLocal;

  /// [booksAddedLocal] 中因为源未安装而降级的数量（指向 `downloads` 里的目录）。
  final int booksAddedLocalSourceMissing;

  /// `extractDir` 或章映射实际被更新的书目数。
  final int booksRelinked;

  /// 当前 Content root 下找不到漫画目录的书目数（记录保留）。
  final int booksMissing;

  /// 匹配有歧义、被墓碑拦截或无法恢复而整本跳过的书目数（不猜）。
  final int booksSkipped;

  /// [booksSkipped] 中因 `book_tombstones`（主动移出书架）而跳过的数量。
  final int booksSkippedTombstoned;

  /// 新恢复条目里被标记/登记的章节数。
  final int chaptersAdded;

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

  /// 找回了任何东西（用于 UI 选择文案与测试断言）。
  bool get hasRelinkedContent =>
      booksAdded > 0 ||
      booksRelinked > 0 ||
      chaptersAdded > 0 ||
      chaptersRelinked > 0;
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
    final List<EpubBookRow> rows = await database.getAllEpubBooks();
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
    // 只经 Rebuild 登记 / 重链的本地作品也要有封面：与进入本地图源页同一条
    // 补齐路径（幂等、绝不覆盖已有封面、坏页跳过）。
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
    final Set<String> tombstones = await database.getBookTombstoneKeys();
    final _InstalledSources installedSources = await _loadInstalledSources();

    // 进度总数在两段之间会从「书架条目数」扩到「书架 + 磁盘恢复候选」；恢复
    // 候选要等 re-link 完成后才知道哪些已经被认回书架。
    int progressTotal = books.length;

    int booksAdded = 0;
    int booksAddedOnline = 0;
    int booksAddedLocal = 0;
    int booksAddedLocalSourceMissing = 0;
    int booksRelinked = 0;
    int booksMissing = 0;
    int booksSkipped = 0;
    int booksSkippedTombstoned = 0;
    int chaptersAdded = 0;
    int chaptersRelinked = 0;
    int chaptersMissing = 0;
    int chaptersSkipped = 0;
    int failed = 0;
    bool cancelled = false;
    // 歧义目录不能被后续恢复扫描当成新作品：那等于猜了其中一个候选。
    final Set<String> ambiguousPaths = <String>{};

    for (int index = 0; index < books.length; index++) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final _BookCandidate book = books[index];
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: index,
          total: progressTotal,
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
        ambiguousPaths.addAll(outcome.ambiguousPaths);
        if (outcome.cancelled) {
          cancelled = true;
          // 取消发生在书内：保留这本书已经写下的部分更新，报告截止到这里。
          booksRelinked += outcome.relinked ? 1 : 0;
          chaptersRelinked += outcome.chaptersRelinked;
          chaptersMissing += outcome.chaptersMissing;
          chaptersSkipped += outcome.chaptersSkipped;
          if (outcome.missing) booksMissing++;
          if (outcome.skipped) booksSkipped++;
          break;
        }
        if (outcome.relinked) booksRelinked++;
        if (outcome.missing) booksMissing++;
        if (outcome.skipped) booksSkipped++;
        chaptersRelinked += outcome.chaptersRelinked;
        chaptersMissing += outcome.chaptersMissing;
        chaptersSkipped += outcome.chaptersSkipped;
      } on Object {
        failed++;
      }
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: index + 1,
          total: progressTotal,
          currentTitle: book.row.title,
        ),
      );
    }

    // ── 全量恢复：downloads / local 里书架没有的作品（票 10） ──────
    if (!cancelled) {
      final List<EpubBookRow> latestRows = await database.getAllEpubBooks();
      final Set<String> latestBookKeys = <String>{
        for (final EpubBookRow row in latestRows) row.bookKey,
      };
      final Set<String> latestExtractDirs = <String>{
        for (final EpubBookRow row in latestRows)
          _canonicalPath(row.extractDir),
      };
      // local 里尚未登记的本地作品。已立墓碑的也留在候选里：处理时计入
      // skipped 并报告用户「主动移出书架」的选择被尊重。
      final List<LocalSourceManga> localRecoveryCandidates = <LocalSourceManga>[
        for (final LocalSourceManga manga in localMangas)
          if (!latestBookKeys.contains(
                localSourceBookKeyFor(manga.directoryPath),
              ) &&
              !latestExtractDirs.contains(
                _canonicalPath(manga.directoryPath),
              ) &&
              !ambiguousPaths.contains(_canonicalPath(manga.directoryPath)))
            manga,
      ];
      final List<_DownloadMangaFolder> downloadRecoveryCandidates =
          <_DownloadMangaFolder>[
            for (final _DownloadMangaFolder folder in downloadScan.folders)
              if (!latestExtractDirs.contains(
                    _canonicalPath(folder.directory.path),
                  ) &&
                  !ambiguousPaths.contains(
                    _canonicalPath(folder.directory.path),
                  ))
                folder,
          ];
      progressTotal =
          books.length +
          localRecoveryCandidates.length +
          downloadRecoveryCandidates.length;

      // local：新增作品（ticket 06 的扫描规则），尊重墓碑。
      for (int index = 0; index < localRecoveryCandidates.length; index++) {
        if (cancelToken?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        final LocalSourceManga manga = localRecoveryCandidates[index];
        onProgress?.call(
          RebuildDownloadIndexProgress(
            completed: books.length + index,
            total: progressTotal,
            currentTitle: manga.title,
          ),
        );
        final String bookKey = localSourceBookKeyFor(manga.directoryPath);
        if (tombstones.contains(bookKey)) {
          booksSkipped++;
          booksSkippedTombstoned++;
          continue;
        }
        try {
          // 先补齐封面再登记：扫描结果里的 `coverRelativePath` 对 CBZ 作品为空，
          // 生成后的 `cover.jpg` 要写进登记行，书架 / 作品页才能直接显示。
          final LocalSourceManga withCover = await _withGeneratedCover(
            manga,
            coverService,
          );
          final bool added = await LocalSourceLibrary(
            db: database,
            root: localComicRoot,
          ).registerScannedManga(withCover);
          if (added) {
            booksAdded++;
            booksAddedLocal++;
            chaptersAdded += manga.chapters.length;
          } else {
            booksRelinked++;
          }
        } on Object {
          failed++;
        }
        onProgress?.call(
          RebuildDownloadIndexProgress(
            completed: books.length + index + 1,
            total: progressTotal,
            currentTitle: manga.title,
          ),
        );
      }

      // downloads：新增作品（源已安装 → 在线条目；否则 → 本地条目）。
      final int downloadOffset = books.length + localRecoveryCandidates.length;
      for (int index = 0; index < downloadRecoveryCandidates.length; index++) {
        if (cancelToken?.isCancelled ?? false) {
          cancelled = true;
          break;
        }
        final _DownloadMangaFolder folder = downloadRecoveryCandidates[index];
        onProgress?.call(
          RebuildDownloadIndexProgress(
            completed: downloadOffset + index,
            total: progressTotal,
            currentTitle: folder.mangaFolderName,
          ),
        );
        try {
          final _RecoveryOutcome outcome = await _recoverDownloadManga(
            folder,
            installedSources,
            tombstones,
            latestBookKeys,
          );
          booksAdded += outcome.added;
          booksAddedOnline += outcome.addedOnline;
          booksAddedLocal += outcome.addedLocal;
          booksAddedLocalSourceMissing += outcome.addedLocalSourceMissing;
          booksSkipped += outcome.skipped;
          booksSkippedTombstoned += outcome.skippedTombstoned;
          chaptersAdded += outcome.chaptersAdded;
          chaptersSkipped += outcome.chaptersSkipped;
        } on Object {
          failed++;
        }
        onProgress?.call(
          RebuildDownloadIndexProgress(
            completed: downloadOffset + index + 1,
            total: progressTotal,
            currentTitle: folder.mangaFolderName,
          ),
        );
      }
    }
    // 取消时也补一次最终进度，UI 不会停在旧值上。
    if (cancelled) {
      onProgress?.call(
        RebuildDownloadIndexProgress(
          completed: progressTotal,
          total: progressTotal,
          currentTitle: null,
        ),
      );
    }

    return RebuildDownloadIndexReport(
      booksScanned: books.length,
      booksAdded: booksAdded,
      booksAddedOnline: booksAddedOnline,
      booksAddedLocal: booksAddedLocal,
      booksAddedLocalSourceMissing: booksAddedLocalSourceMissing,
      booksRelinked: booksRelinked,
      booksMissing: booksMissing,
      booksSkipped: booksSkipped,
      booksSkippedTombstoned: booksSkippedTombstoned,
      chaptersAdded: chaptersAdded,
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
        chaptersMissing: match.ambiguous ? 0 : indexedChapterCount,
        chaptersSkipped: match.ambiguous ? indexedChapterCount : 0,
        ambiguousPaths: match.ambiguous
            ? <String>{
                for (final _DownloadMangaFolder candidate in match.candidates)
                  _canonicalPath(candidate.directory.path),
              }
            : const <String>{},
      );
    }
    final _DownloadMangaFolder folder = match.folder!;
    bool relinked = false;
    final bool moved = !_samePath(row.extractDir, folder.directory.path);
    if (moved) {
      await database.updateEpubBookContentPaths(
        row.bookKey,
        extractDir: folder.directory.path,
      );
      relinked = true;
    }

    // 1) pages.json 稳定 ID 优先。
    final Map<String, List<ChapterContainerOnDisk>> idCandidates =
        <String, List<ChapterContainerOnDisk>>{};
    for (final ChapterContainerOnDisk diskChapter in folder.chapters) {
      final MangaPagesManifest? manifest = diskChapter.manifest;
      if (manifest == null) continue;
      if (!_manifestBelongsTo(manifest, entry)) continue;
      final int chapterIndex = entry.indexOfChapterKey(manifest.chapterKey);
      if (chapterIndex < 0) continue;
      idCandidates
          .putIfAbsent(manifest.chapterKey, () => <ChapterContainerOnDisk>[])
          .add(diskChapter);
    }
    final Map<String, ChapterContainerOnDisk> byId =
        <String, ChapterContainerOnDisk>{};
    final Set<String> ambiguousIds = <String>{};
    for (final MapEntry<String, List<ChapterContainerOnDisk>> item
        in idCandidates.entries) {
      if (item.value.length == 1) {
        byId[item.key] = item.value.single;
      } else {
        ambiguousIds.add(item.key);
      }
    }
    final Set<String> idClaimedContainerNames = <String>{
      for (final ChapterContainerOnDisk container in byId.values)
        container.containerName.toLowerCase(),
    };

    final Map<String, ChapterContainerOnDisk> existingContainers =
        <String, ChapterContainerOnDisk>{
          for (final ChapterContainerOnDisk chapter in folder.chapters)
            chapter.containerName.toLowerCase(): chapter,
        };

    final Map<String, ChapterContainerOnDisk> matches =
        <String, ChapterContainerOnDisk>{...byId};
    final Set<String> usedContainerNames = <String>{...idClaimedContainerNames};
    int chaptersMissing = 0;
    int chaptersSkipped = ambiguousIds.length;
    for (final OnlineMangaChapter chapter in entry.chapters) {
      if (cancelToken?.isCancelled ?? false) {
        // 取消只停在这一章之前；已写下的 extractDir 保留，映射在循环后统一落库，
        // 因此这里不需要回滚任何东西（下一次幂等重建会补齐）。
        return _BookOutcome(
          relinked: relinked,
          chaptersMissing: chaptersMissing,
          chaptersSkipped: chaptersSkipped,
          cancelled: true,
        );
      }
      if (matches.containsKey(chapter.key)) continue;
      if (ambiguousIds.contains(chapter.key)) continue;

      // 2a) 已有映射（应用自己写下的名称映射）仍指向本漫画目录里的容器。
      final String? mappedName = existingMappings[chapter.key]?.folderName;
      ChapterContainerOnDisk? candidate;
      if (mappedName != null) {
        final ChapterContainerOnDisk? mapped =
            existingContainers[mappedName.toLowerCase()];
        if (mapped != null) {
          final bool claimedByOther = idClaimedContainerNames.contains(
            mapped.containerName.toLowerCase(),
          );
          if (!claimedByOther) candidate = mapped;
        }
      }

      // 2b) 没有可用映射时按容器名回退（无稳定身份 / pages.json 丢失）。
      if (candidate == null) {
        final List<ChapterContainerOnDisk> nameCandidates = folder.chapters
            .where(
              (ChapterContainerOnDisk item) =>
                  !usedContainerNames.contains(
                    item.containerName.toLowerCase(),
                  ) &&
                  _chapterContainerNameMatches(item.containerName, chapter),
            )
            .toList();
        if (nameCandidates.length == 1) {
          candidate = nameCandidates.single;
        } else if (nameCandidates.length > 1) {
          final List<ChapterContainerOnDisk> completeCandidates =
              nameCandidates
                  .where((ChapterContainerOnDisk item) => item.complete)
                  .toList();
          if (completeCandidates.length == 1) {
            candidate = completeCandidates.single;
          } else {
            chaptersSkipped++;
            continue;
          }
        }
      }

      if (candidate != null) {
        matches[chapter.key] = candidate;
        usedContainerNames.add(candidate.containerName.toLowerCase());
      } else {
        // 只有「下载索引认为已下载」的章才算 Missing；从未下载的章不是缺失。
        if (indexedChapterKeys.contains(chapter.key)) chaptersMissing++;
        // 映射指向的目录已被 pages.json 证明属于别的章：原样保留这条映射，
        // 不删除。上面的 `claimedByOther` 已保证本轮的匹配不会用它，所以留着
        // 只会让这一章继续显示 Missing；下次重建若目录/ID 变化还可能自愈。
        // Rebuild 的契约是只增改，绝不删记录（spec 规则 4）。
      }
    }

    int chaptersRelinked = 0;
    for (final MapEntry<String, ChapterContainerOnDisk> match
        in matches.entries) {
      final MangaChapterDirRow? previous = existingMappings[match.key];
      if (previous != null &&
          previous.folderName == match.value.containerName &&
          previous.containerKindEnum == match.value.kind) {
        continue;
      }
      await database.upsertMangaChapterDir(
        bookKey: row.bookKey,
        chapterKey: match.key,
        folderName: match.value.containerName,
        containerKind: match.value.kind,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      chaptersRelinked++;
    }
    return _BookOutcome(
      relinked: relinked || chaptersRelinked > 0,
      missing: chaptersMissing > 0,
      chaptersRelinked: chaptersRelinked,
      chaptersMissing: chaptersMissing,
      chaptersSkipped: chaptersSkipped,
    );
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
    // 1) `pages.json` 稳定 ID：任何一章的 manifest 能证明这个目录属于本书。
    final List<_DownloadMangaFolder> idMatches = <_DownloadMangaFolder>[
      for (final _DownloadMangaFolder folder in scan.folders)
        if (folder.chapters.any(
          (ChapterContainerOnDisk chapter) =>
              chapter.manifest != null &&
              _manifestBelongsTo(chapter.manifest!, entry),
        ))
          folder,
    ];
    if (idMatches.length == 1) {
      return _MangaFolderMatch(idMatches.single);
    }
    if (idMatches.length > 1) {
      return _MangaFolderMatch.ambiguous(idMatches);
    }

    // 2) 库里的 extractDir 仍是**当前**根内的有效目录：沿用应用自己写下的映射。
    final String recordedPath = p.normalize(row.extractDir);
    if (isLocalSourcePathWithinRoot(recordedPath, downloadsRoot)) {
      for (final _DownloadMangaFolder folder in scan.folders) {
        if (_samePath(folder.directory.path, recordedPath)) {
          return _MangaFolderMatch(folder);
        }
      }
    }

    // 3) 文件夹名回退（标题净化后的大小写不敏感比较）。多候选 = 歧义，不猜。
    final String expected = sanitizeDownloadLibrarySegment(
      entry.series.title,
    ).toLowerCase();
    final List<_DownloadMangaFolder> nameMatches = <_DownloadMangaFolder>[
      for (final _DownloadMangaFolder folder in scan.folders)
        if (folder.mangaFolderName.toLowerCase() == expected) folder,
    ];
    if (nameMatches.length == 1) return _MangaFolderMatch(nameMatches.single);
    if (nameMatches.length > 1) {
      return _MangaFolderMatch.ambiguous(nameMatches);
    }
    return const _MangaFolderMatch.none();
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

  // ── 全量恢复 ────────────────────────────────────────────────────────

  /// 扩展与在线源都已安装的集合（恢复时决定建在线条目还是降级本地条目）。
  Future<_InstalledSources> _loadInstalledSources() async {
    final List<MangaExtensionRow> extensions = await database
        .getMangaExtensions(mediaKind: 'manga');
    final List<MangaOnlineSourceRow> sources = await database
        .getMangaOnlineSources(mediaKind: 'manga');
    return _InstalledSources(
      extensionPackages: <String>{
        for (final MangaExtensionRow row in extensions) row.packageName,
      },
      sourceIds: <String>{
        for (final MangaOnlineSourceRow row in sources)
          _sourceIdentity(row.extensionPackage, row.sourceId),
      },
    );
  }

  /// 恢复一个 `downloads/{source}/{manga}` 里书架没有的作品。
  Future<_RecoveryOutcome> _recoverDownloadManga(
    _DownloadMangaFolder folder,
    _InstalledSources installedSources,
    Set<String> tombstones,
    Set<String> existingBookKeys,
  ) async {
    // 一部作品下的 `pages.json` 必须只指向同一个 Source/Manga 身份；混合身份
    // 不猜，整本跳过并报告。
    final Map<String, List<ChapterContainerOnDisk>> groups =
        <String, List<ChapterContainerOnDisk>>{};
    for (final ChapterContainerOnDisk chapter in folder.chapters) {
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest == null) continue;
      final String identity = <String>[
        manifest.sourceRuntime,
        manifest.extensionPackage,
        manifest.sourceId,
        manifest.mangaKey,
      ].join('\u0000');
      groups
          .putIfAbsent(identity, () => <ChapterContainerOnDisk>[])
          .add(chapter);
    }
    final String localBookKey = localSourceBookKeyFor(folder.directory.path);
    // 主动移出书架的作品（在线身份或降级后的本地身份）一律不复活；没有
    // pages.json 的目录也一样——它们可能正是上次降级登记后又被移出的作品。
    if (tombstones.contains(localBookKey)) {
      return _RecoveryOutcome(skipped: 1, skippedTombstoned: 1);
    }
    if (existingBookKeys.contains(localBookKey)) {
      return const _RecoveryOutcome();
    }
    if (groups.length > 1) {
      return _RecoveryOutcome(
        skipped: 1,
        chaptersSkipped: folder.chapters.length,
      );
    }
    if (groups.isEmpty) {
      return _recoverDownloadMangaAsLocal(folder);
    }

    final List<ChapterContainerOnDisk> group = groups.values.single;
    final MangaPagesManifest manifest = group.first.manifest!;
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      manifest.sourceRuntime,
    );
    final String? onlineBookKey = runtime == null
        ? null
        : onlineMangaBookKeyFor(
            runtime: runtime,
            extensionPackage: manifest.extensionPackage,
            sourceId: manifest.sourceId,
            seriesKey: manifest.mangaKey,
          );
    if (onlineBookKey != null && tombstones.contains(onlineBookKey)) {
      return _RecoveryOutcome(skipped: 1, skippedTombstoned: 1);
    }
    if (onlineBookKey != null && existingBookKeys.contains(onlineBookKey)) {
      return const _RecoveryOutcome();
    }

    final bool installed =
        runtime == OnlineMangaRuntimeKind.mihon &&
        installedSources.has(manifest.extensionPackage, manifest.sourceId);
    if (!installed) {
      return _recoverDownloadMangaAsLocal(
        folder,
        onlyCompleteManifestChapters: true,
        title: manifest.mangaTitle.trim().isEmpty
            ? folder.mangaFolderName
            : manifest.mangaTitle,
        sourceMissing: true,
      );
    }
    return _createOnlineEntry(folder, group, runtime!);
  }

  /// 源未安装 / 没有 `pages.json` 时，把下载目录降级为指向该文件夹的本地条目。
  Future<_RecoveryOutcome> _recoverDownloadMangaAsLocal(
    _DownloadMangaFolder folder, {
    bool onlyCompleteManifestChapters = false,
    String? title,
    bool sourceMissing = false,
  }) async {
    final LocalSourceManga? scanned = await _scanDownloadMangaAsLocal(
      folder,
      onlyCompleteManifestChapters: onlyCompleteManifestChapters,
      title: title,
    );
    if (scanned == null) return const _RecoveryOutcome();
    final bool added = await LocalSourceLibrary(
      db: database,
      root: downloadsRoot,
    ).registerScannedManga(scanned);
    if (!added) return const _RecoveryOutcome();
    return _RecoveryOutcome(
      added: 1,
      addedLocal: 1,
      addedLocalSourceMissing: sourceMissing ? 1 : 0,
      chaptersAdded: scanned.chapters.length,
    );
  }

  /// 用图片扫描（`pages.json` 缺失/不可用）把下载漫画目录读成一部本地作品。
  Future<LocalSourceManga?> _scanDownloadMangaAsLocal(
    _DownloadMangaFolder folder, {
    required bool onlyCompleteManifestChapters,
    String? title,
  }) async {
    final String relativePath = p
        .relative(folder.directory.path, from: downloadsRoot.path)
        .replaceAll('\\', '/');
    final LocalSourceManga? scanned = await scanLocalSourceMangaDirectory(
      folder.directory,
      relativePath: relativePath,
    );
    if (scanned == null) return null;
    if (!onlyCompleteManifestChapters) return scanned;
    final Set<String> completeContainers = <String>{
      for (final ChapterContainerOnDisk chapter in folder.chapters)
        if (chapter.complete && chapter.manifest != null)
          chapter.containerName.toLowerCase(),
    };
    final List<LocalSourceChapter> complete = <LocalSourceChapter>[
      for (final LocalSourceChapter chapter in scanned.chapters)
        if (completeContainers.contains(chapter.relativePath.toLowerCase()))
          chapter,
    ];
    if (complete.isEmpty) return null;
    return LocalSourceManga(
      title: title ?? scanned.title,
      directoryPath: scanned.directoryPath,
      relativePath: scanned.relativePath,
      chapters: complete,
      coverRelativePath: scanned.coverRelativePath,
    );
  }

  /// 源已安装：按 `pages.json` 的稳定身份创建在线条目，并把完整下载的章写进
  /// `manga_chapter_dirs`（`epub_books.extractDir` 指向漫画目录）。
  Future<_RecoveryOutcome> _createOnlineEntry(
    _DownloadMangaFolder folder,
    List<ChapterContainerOnDisk> group,
    OnlineMangaRuntimeKind runtime,
  ) async {
    final Map<String, ChapterContainerOnDisk> byKey =
        <String, ChapterContainerOnDisk>{};
    int chaptersSkipped = 0;
    for (final ChapterContainerOnDisk chapter in group) {
      final MangaPagesManifest manifest = chapter.manifest!;
      // 半成品下载不进索引：只有 pages.json + 全部页文件齐全的章才算已下载。
      if (!chapter.complete) continue;
      if (byKey.containsKey(manifest.chapterKey)) {
        chaptersSkipped++;
        continue;
      }
      byKey[manifest.chapterKey] = chapter;
    }
    if (byKey.isEmpty) return const _RecoveryOutcome();

    final MangaPagesManifest first = group.first.manifest!;
    final String title = first.mangaTitle.trim().isEmpty
        ? folder.mangaFolderName
        : first.mangaTitle;
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
      for (final MapEntry<String, ChapterContainerOnDisk> entry
          in byKey.entries)
        _onlineChapterFromManifest(entry.value.manifest!),
    ];
    final OnlineMangaLibraryEntry libraryEntry = OnlineMangaLibraryEntry(
      runtime: runtime,
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
      series: OnlineMangaSeries(
        key: first.mangaKey,
        title: title,
        raw: <String, Object?>{'url': first.mangaKey, 'title': title},
      ),
      chapters: chapters,
    );
    final String bookKey = onlineMangaBookKeyFor(
      runtime: runtime,
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
      seriesKey: first.mangaKey,
    );
    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        coverPath: Value<String?>(
          _downloadMangaCoverRelative(folder, byKey.values),
        ),
        epubPath: kDownloadPagesFileName,
        extractDir: folder.directory.path,
        chapterCount: chapters.length,
        chaptersJson: jsonEncode(<Map<String, Object?>>[
          for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
        ]),
        sourceMetadata: Value<String?>(libraryEntry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    for (final MapEntry<String, ChapterContainerOnDisk> entry
        in byKey.entries) {
      await database.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: entry.key,
        folderName: entry.value.containerName,
        containerKind: entry.value.kind,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return _RecoveryOutcome(
      added: 1,
      addedOnline: 1,
      chaptersAdded: byKey.length,
      chaptersSkipped: chaptersSkipped,
    );
  }

  /// `pages.json` → 归一化章节。raw 保留 Mihon 原生章 payload 的最小形状，
  /// 源已安装时仍能按 `url` 拉取未下载的章。
  static OnlineMangaChapter _onlineChapterFromManifest(
    MangaPagesManifest manifest,
  ) {
    final String url = (manifest.chapterUrl ?? '').trim().isEmpty
        ? manifest.chapterKey
        : manifest.chapterUrl!;
    return OnlineMangaChapter(
      key: manifest.chapterKey,
      name: manifest.chapterName,
      scanlator: manifest.scanlator,
      number: manifest.chapterNumber,
      raw: <String, Object?>{
        'url': url,
        'name': manifest.chapterName,
        'date_upload': 0,
        'chapter_number': manifest.chapterNumber ?? 0,
        if (manifest.scanlator != null) 'scanlator': manifest.scanlator,
      },
    );
  }

  /// 在线条目的封面：优先漫画目录里的 `cover.*`，否则取第一张完整下载的页图
  /// （相对漫画目录，与 `ReaderFushiSource.resolveCoverFilePath` 的解析一致）。
  static String? _downloadMangaCoverRelative(
    _DownloadMangaFolder folder,
    Iterable<ChapterContainerOnDisk> chapters,
  ) {
    for (final String name in const <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
    ]) {
      if (File(p.join(folder.directory.path, name)).existsSync()) return name;
    }
    for (final ChapterContainerOnDisk chapter in chapters) {
      // 压缩包内的页不是漫画目录下的独立文件，不能当封面相对路径。
      if (chapter.isArchive) continue;
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest == null || manifest.payload.images.isEmpty) continue;
      return p
          .join(chapter.containerName, manifest.payload.images.first.url)
          .replaceAll('\\', '/');
    }
    return null;
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
      byBook
          .putIfAbsent(row.bookKey, () => <String>{})
          .add(row.chapterKey);
    }
    return byBook;
  }

  // ── 扫描 ────────────────────────────────────────────────────────────

  Future<_DownloadScan> _scanDownloadLibrary() async {
    final List<_DownloadMangaFolder> folders = <_DownloadMangaFolder>[];
    if (!await downloadsRoot.exists()) {
      return _DownloadScan(folders);
    }
    final List<Directory> sourceDirs = await _childDirectories(downloadsRoot);
    for (final Directory sourceDir in sourceDirs) {
      final List<Directory> mangaDirs = await _childDirectories(sourceDir);
      for (final Directory mangaDir in mangaDirs) {
        final List<ChapterContainerOnDisk> chapters =
            <ChapterContainerOnDisk>[];
        for (final FileSystemEntity entity in await _childChapterContainers(
          mangaDir,
        )) {
          final String containerName = p.basename(entity.path);
          if (entity is Directory) {
            final MangaPagesManifest? manifest = await readPagesManifest(
              entity,
            );
            final bool complete =
                manifest != null &&
                await readDownloadLibraryChapterPayload(entity) != null;
            chapters.add(
              ChapterContainerOnDisk.folder(
                containerName: containerName,
                directory: entity,
                manifest: manifest,
                complete: complete,
              ),
            );
          } else if (entity is File) {
            final MangaPagesManifest? manifest =
                await readDownloadLibraryArchiveManifest(entity);
            final bool complete =
                manifest != null &&
                await isDownloadLibraryArchiveComplete(entity);
            chapters.add(
              ChapterContainerOnDisk.archive(
                containerName: containerName,
                archiveFile: entity,
                manifest: manifest,
                complete: complete,
              ),
            );
          }
        }
        folders.add(
          _DownloadMangaFolder(
            directory: mangaDir,
            mangaFolderName: p.basename(mangaDir.path),
            chapters: chapters,
          ),
        );
      }
    }
    return _DownloadScan(folders);
  }

  /// 第一层直接子目录；点号目录（`.staging` 等）忽略。
  static Future<List<Directory>> _childDirectories(Directory parent) async {
    if (!await parent.exists()) return const <Directory>[];
    final List<Directory> dirs = <Directory>[];
    try {
      await for (final FileSystemEntity entity in parent.list(
        followLinks: false,
      )) {
        if (entity is Directory &&
            !p.basename(entity.path).startsWith('.')) {
          dirs.add(entity);
        }
      }
    } on FileSystemException {
      return const <Directory>[];
    }
    dirs.sort(
      (Directory a, Directory b) =>
          p.basename(a.path).toLowerCase().compareTo(
            p.basename(b.path).toLowerCase(),
          ),
    );
    return dirs;
  }

  /// 漫画目录下的章节容器：子目录（文件夹章节）与 `.cbz` 文件（压缩包章节）；
  /// 点号条目（`.staging` 等）忽略。按小写名字排序，保证扫描确定。
  static Future<List<FileSystemEntity>> _childChapterContainers(
    Directory parent,
  ) async {
    if (!await parent.exists()) return const <FileSystemEntity>[];
    final List<FileSystemEntity> entries = <FileSystemEntity>[];
    try {
      await for (final FileSystemEntity entity in parent.list(
        followLinks: false,
      )) {
        final String name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (entity is Directory ||
            (entity is File && isDownloadChapterArchiveName(name))) {
          entries.add(entity);
        }
      }
    } on FileSystemException {
      return const <FileSystemEntity>[];
    }
    entries.sort(
      (FileSystemEntity a, FileSystemEntity b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    return entries;
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
    this.relinked = false,
    this.missing = false,
    this.skipped = false,
    this.chaptersRelinked = 0,
    this.chaptersMissing = 0,
    this.chaptersSkipped = 0,
    this.cancelled = false,
    this.ambiguousPaths = const <String>{},
  });

  final bool relinked;
  final bool missing;
  final bool skipped;
  final int chaptersRelinked;
  final int chaptersMissing;
  final int chaptersSkipped;
  final bool cancelled;

  /// 因为歧义没有被认领的磁盘目录（规范：不猜）。这些目录不能再被恢复扫描
  /// 当成「书架没有的新作品」加进来，否则等于猜了一个匹配。
  final Set<String> ambiguousPaths;
}

/// 一次磁盘作品恢复的结局计数。
class _RecoveryOutcome {
  const _RecoveryOutcome({
    this.added = 0,
    this.addedOnline = 0,
    this.addedLocal = 0,
    this.addedLocalSourceMissing = 0,
    this.skipped = 0,
    this.skippedTombstoned = 0,
    this.chaptersAdded = 0,
    this.chaptersSkipped = 0,
  });

  final int added;
  final int addedOnline;
  final int addedLocal;
  final int addedLocalSourceMissing;
  final int skipped;
  final int skippedTombstoned;
  final int chaptersAdded;
  final int chaptersSkipped;
}

/// 已安装扩展 + 在线源的查询结果。
class _InstalledSources {
  const _InstalledSources({
    required this.extensionPackages,
    required this.sourceIds,
  });

  final Set<String> extensionPackages;
  final Set<String> sourceIds;

  bool has(String extensionPackage, String sourceId) =>
      extensionPackages.contains(extensionPackage) &&
      sourceIds.contains(_sourceIdentity(extensionPackage, sourceId));
}

class _DownloadScan {
  const _DownloadScan(this.folders);

  final List<_DownloadMangaFolder> folders;
}

class _DownloadMangaFolder {
  const _DownloadMangaFolder({
    required this.directory,
    required this.mangaFolderName,
    required this.chapters,
  });

  final Directory directory;
  final String mangaFolderName;
  final List<ChapterContainerOnDisk> chapters;
}

class _MangaFolderMatch {
  const _MangaFolderMatch(this.folder)
    : ambiguous = false,
      candidates = const <_DownloadMangaFolder>[];

  const _MangaFolderMatch.ambiguous(this.candidates)
    : folder = null,
      ambiguous = true;

  const _MangaFolderMatch.none()
    : folder = null,
      ambiguous = false,
      candidates = const <_DownloadMangaFolder>[];

  final _DownloadMangaFolder? folder;
  final bool ambiguous;
  final List<_DownloadMangaFolder> candidates;
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

/// `pages.json` 的身份是否属于这条在线书架条目。
bool _manifestBelongsTo(
  MangaPagesManifest manifest,
  OnlineMangaLibraryEntry entry,
) {
  if (manifest.sourceRuntime != entry.runtime.wireValue) return false;
  if (manifest.sourceId != entry.sourceId) return false;
  if (manifest.mangaKey != entry.series.key) return false;
  // 老描述符可能没有扩展包信息；有就比，没有不比。
  if (entry.extensionPackage.isNotEmpty &&
      manifest.extensionPackage != entry.extensionPackage) {
    return false;
  }
  return true;
}

/// 容器名是否像这一章的展示名。
///
/// 只用于 `pages.json` 缺稳定身份时的兜底：比较净化后的章名；允许下载器在重名 /
/// 同扫译组时追加的 `[扫译组]` 与 ` (2)` 后缀。CBZ 容器名先去掉 `.cbz` 扩展名
/// 再比。大小写不敏感（Windows 语义）。
bool _chapterContainerNameMatches(
  String containerName,
  OnlineMangaChapter chapter,
) {
  final String rawName = chapter.name.trim().isEmpty
      ? chapter.key
      : chapter.name;
  final String base = sanitizeDownloadLibrarySegment(rawName).toLowerCase();
  final String lower =
      (isDownloadChapterArchiveName(containerName)
              ? p.basenameWithoutExtension(containerName)
              : containerName)
          .toLowerCase();
  if (lower == base) return true;
  final String scanlator = chapter.scanlator?.trim() ?? '';
  if (scanlator.isNotEmpty) {
    final String qualifier = sanitizeDownloadLibrarySegment(
      scanlator,
      maxLength: 32,
    ).toLowerCase();
    if (lower == '$base [$qualifier]') return true;
  }
  return RegExp(
    '^${RegExp.escape(base)}(?: \\[.+\\])? \\(\\d+\\)\$',
  ).hasMatch(lower);
}

bool _samePath(String a, String b) => p.equals(p.canonicalize(a), p.canonicalize(b));

String _canonicalPath(String path) => p.canonicalize(p.normalize(path));

String _sourceIdentity(String extensionPackage, String sourceId) =>
    '$extensionPackage\u0000$sourceId';

String _normalizeRelative(String value) =>
    value.replaceAll('\\', '/').toLowerCase();

/// Local source 的文件夹名比较：只做大小写折叠（用户目录名按原样保留）。
String _localFolderName(String value) => value.trim().toLowerCase();
