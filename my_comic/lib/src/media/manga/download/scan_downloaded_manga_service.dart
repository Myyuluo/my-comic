/// 检索已下载（Scan downloaded）：只扫描**当前** Content root 的 `downloads`，
/// 把已下载但尚未加入书架的漫画加入书架。
///
/// 与「重建下载索引」的职责边界（spec「检索已下载」）：
///  - 本服务只发现并加入**未在书架**的作品；已在书架但未关联的下载仍由
///    `RebuildDownloadIndexService` 重链。
///  - 只接收 `downloads` 根，结构上不读取 `local`、`autobackup` 或旧 Content root。
///  - 候选目录必须至少有一个**完整**章节容器；半成品、空目录或不可读目录跳过
///    并计入报告。
///  - 归属顺序：已在书架 → 跳过；已有非书架行 → 原地提升；tombstone → 显式
///    复活并清除墓碑；`pages.json` 身份 + 源已安装 → 在线条目；源未安装 /
///    无 manifest → 指向该 `downloads` 目录的本地条目。
///  - 多个目录证明同一身份且无法安全决定归属时跳过并报告歧义，绝不猜测。
///  - 全程只增改数据库行，不移动、复制、删除、重命名任何用户文件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/download_library_storage.dart'
    show MangaPagesManifest, readDownloadLibraryChapterPayload;
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart'
    show LocalSourceManga, scanLocalSourceMangaDirectory;
import 'package:my_comic_engine/media/manga/local_source/local_source_library.dart'
    show localSourceBookKeyFor;

import 'package:my_comic/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:my_comic/src/media/manga/download/download_library_changes.dart';
import 'package:my_comic/src/media/manga/download/download_library_scanner.dart';
import 'package:my_comic/src/media/manga/download/download_manga_discovery.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';

/// 一次检索的进度快照。
class ScanDownloadedMangaProgress {
  const ScanDownloadedMangaProgress({
    required this.completed,
    required this.total,
    this.currentTitle,
  });

  /// 已处理的漫画目录数。
  final int completed;

  /// 本次要处理的漫画目录总数。
  final int total;

  /// 正在处理的作品标题（给进度框用）。
  final String? currentTitle;

  /// 0..1；[total] 为 0 时为 null（不确定态）。
  double? get fraction => total <= 0 ? null : completed / total;
}

/// 取消令牌。服务在每个漫画目录之间检查；取消后返回 `cancelled: true` 的
/// 部分报告，已完成的更新保留（检索是幂等的）。
class ScanDownloadedMangaCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 一次检索的结果摘要。
class ScanDownloadedMangaReport {
  const ScanDownloadedMangaReport({
    required this.foldersScanned,
    this.addedOnline = 0,
    this.addedLocal = 0,
    this.addedLocalSourceMissing = 0,
    this.promoted = 0,
    this.revivedTombstones = 0,
    this.skippedIncomplete = 0,
    this.skippedAmbiguous = 0,
    this.failed = 0,
    this.cancelled = false,
  });

  const ScanDownloadedMangaReport.empty()
    : foldersScanned = 0,
      addedOnline = 0,
      addedLocal = 0,
      addedLocalSourceMissing = 0,
      promoted = 0,
      revivedTombstones = 0,
      skippedIncomplete = 0,
      skippedAmbiguous = 0,
      failed = 0,
      cancelled = false;

  /// 扫描到的 `downloads/<source>/<manga>` 目录数。
  final int foldersScanned;

  /// 新建立的在线条目数（源已安装且 `pages.json` 身份可证明）。
  final int addedOnline;

  /// 新建立的本地条目数（源未安装 / 没有 `pages.json`）。
  final int addedLocal;

  /// [addedLocal] 中因来源未安装而降级的数量。
  final int addedLocalSourceMissing;

  /// 已有非书架行被原地提升为书架成员的数量。
  final int promoted;

  /// tombstone 作品被显式复活并清除墓碑的数量。
  final int revivedTombstones;

  /// 没有完整章节容器、被跳过的目录数。
  final int skippedIncomplete;

  /// 同身份多副本无法安全决定归属、被跳过的作品数。
  final int skippedAmbiguous;

  /// 单个目录处理失败数；失败不中断其余目录。
  final int failed;

  /// 用户中途取消。
  final bool cancelled;
}

/// 一次「检索已下载」服务。显式注入当前 Content root 的 `downloads` 根，
/// 测试与生产走同一条路径。
class ScanDownloadedMangaService {
  const ScanDownloadedMangaService({
    required this.database,
    required this.downloadsRoot,
  });

  final MyComicDatabase database;

  /// 当前 Content root 的 Download library 根。只扫描这里。
  final Directory downloadsRoot;

  Future<ScanDownloadedMangaReport> run({
    ScanDownloadedMangaCancelToken? cancelToken,
    void Function(ScanDownloadedMangaProgress progress)? onProgress,
  }) async {
    try {
      return await _run(cancelToken: cancelToken, onProgress: onProgress);
    } finally {
      // 与重建一致：完成后让已打开的作品页重算已下载状态；异常 / 取消时也发，
      // 已经写下的部分更新同样可能改变页面显示。
      DownloadLibraryChanges.instance.notifyChanged();
    }
  }

  Future<ScanDownloadedMangaReport> _run({
    ScanDownloadedMangaCancelToken? cancelToken,
    void Function(ScanDownloadedMangaProgress progress)? onProgress,
  }) async {
    final List<DownloadMangaFolderOnDisk> folders =
        await scanDownloadLibraryFolders(downloadsRoot, readComplete: true);
    final DownloadMangaInstalledSources installedSources =
        await DownloadMangaInstalledSources.load(database);
    final List<EpubBookRow> rows = await database.getAllEpubBooks();
    final Set<String> libraryBookKeys = <String>{
      for (final EpubBookRow row in rows)
        if (row.isInLibrary) row.bookKey,
    };
    final Set<String> nonLibraryBookKeys = <String>{
      for (final EpubBookRow row in rows)
        if (!row.isInLibrary) row.bookKey,
    };
    final Set<String> existingBookKeys = <String>{
      for (final EpubBookRow row in rows) row.bookKey,
    };
    final Set<String> tombstones = await database.getBookTombstoneKeys();
    final Set<String> ambiguousOnlineBookKeys = await _ambiguousOnlineBookKeys(
      folders,
      existingBookKeys,
    );

    // 逐个目录的发现结果统一 merge：字段一多，手工逐项累加极易漏掉新增字段。
    DownloadMangaDiscoveryOutcome discovery =
        const DownloadMangaDiscoveryOutcome();
    int skippedIncomplete = 0;
    int failed = 0;
    bool cancelled = false;

    for (int index = 0; index < folders.length; index++) {
      if (cancelToken?.isCancelled ?? false) {
        cancelled = true;
        break;
      }
      final DownloadMangaFolderOnDisk folder = folders[index];
      onProgress?.call(
        ScanDownloadedMangaProgress(
          completed: index,
          total: folders.length,
          currentTitle: folder.mangaFolderName,
        ),
      );
      try {
        if (!await _hasCompleteChapter(folder)) {
          skippedIncomplete += 1;
        } else if (_isAmbiguousRootManifest(folder, ambiguousOnlineBookKeys)) {
          // 单章根 manifest 没有章节容器可交给发现模块逐身份过滤；整个目录
          // 属于同一个歧义身份，直接跳过（歧义数已按身份计入报告）。
        } else {
          final DownloadMangaDiscoveryOutcome outcome =
              await DownloadMangaDiscovery(
                database: database,
                downloadsRoot: downloadsRoot,
              ).discover(
                folder,
                installedSources: installedSources,
                bookKeys: DownloadMangaBookKeys(
                  tombstonedBookKeys: tombstones,
                  existingBookKeys: libraryBookKeys,
                  existingNonLibraryBookKeys: nonLibraryBookKeys,
                  skippedOnlineBookKeys: ambiguousOnlineBookKeys,
                ),
                reviveTombstoned: true,
              );
          discovery = discovery.merge(outcome);
          await _refreshBookKeySets(
            folder,
            libraryBookKeys,
            nonLibraryBookKeys,
          );
        }
      } on Object {
        failed += 1;
      }
      onProgress?.call(
        ScanDownloadedMangaProgress(
          completed: index + 1,
          total: folders.length,
          currentTitle: folder.mangaFolderName,
        ),
      );
    }
    if (cancelled) {
      onProgress?.call(
        ScanDownloadedMangaProgress(
          completed: folders.length,
          total: folders.length,
          currentTitle: null,
        ),
      );
    }

    return ScanDownloadedMangaReport(
      foldersScanned: folders.length,
      addedOnline: discovery.addedOnline,
      addedLocal: discovery.addedLocal,
      addedLocalSourceMissing: discovery.addedLocalSourceMissing,
      promoted: discovery.promoted,
      revivedTombstones: discovery.revivedTombstones,
      skippedIncomplete: skippedIncomplete,
      skippedAmbiguous: ambiguousOnlineBookKeys.length,
      failed: failed,
      cancelled: cancelled,
    );
  }

  /// 一个漫画目录是否至少有一个完整章节容器。
  ///
  /// `pages.json` 下载：章节容器必须页齐（或单章作品的根 manifest + 页齐）。
  /// 没有 manifest 的手工目录：按本地图源规则扫描，能读出至少一章才算完整——
  /// 半成品 manifest 目录即使还残留部分页图也不能降级成本地条目。
  Future<bool> _hasCompleteChapter(DownloadMangaFolderOnDisk folder) async {
    for (final ChapterContainerOnDisk chapter in folder.chapters) {
      if (chapter.complete) return true;
    }
    final bool hasManifestedChapter = folder.chapters.any(
      (ChapterContainerOnDisk chapter) => chapter.manifest != null,
    );
    if (hasManifestedChapter) return false;
    if (folder.rootManifest != null) {
      return await readDownloadLibraryChapterPayload(folder.directory) != null;
    }
    final LocalSourceManga? scanned = await scanLocalSourceMangaDirectory(
      folder.directory,
      relativePath: _relativeToDownloads(folder.directory),
    );
    return scanned != null;
  }

  /// 多个目录证明同一在线身份、且没有现成记录可复用时，返回需要跳过的身份。
  ///
  /// 已有 Manga 行（书架或非书架）不需要在副本之间做选择，因此不算歧义；
  /// 只有「必须新建条目 / 从墓碑复活」时存在安全归属问题。
  Future<Set<String>> _ambiguousOnlineBookKeys(
    List<DownloadMangaFolderOnDisk> folders,
    Set<String> existingBookKeys,
  ) async {
    final Map<String, Set<String>> foldersByBookKey = <String, Set<String>>{};
    for (final DownloadMangaFolderOnDisk folder in folders) {
      for (final String bookKey in await _onlineBookKeys(folder)) {
        foldersByBookKey
            .putIfAbsent(bookKey, () => <String>{})
            .add(p.canonicalize(folder.directory.path));
      }
    }
    return <String>{
      for (final MapEntry<String, Set<String>> entry
          in foldersByBookKey.entries)
        if (entry.value.length > 1 && !existingBookKeys.contains(entry.key))
          entry.key,
    };
  }

  /// 目录里能证明**可加入书架**的在线身份（只算完整章节 / 完整的根 manifest）。
  Future<Set<String>> _onlineBookKeys(DownloadMangaFolderOnDisk folder) async {
    final Set<String> keys = <String>{};
    for (final ChapterContainerOnDisk chapter in folder.chapters) {
      if (!chapter.complete) continue;
      final MangaPagesManifest? manifest = chapter.manifest;
      final String? key = manifest == null ? null : _onlineBookKeyOf(manifest);
      if (key != null) keys.add(key);
    }
    final MangaPagesManifest? rootManifest = folder.rootManifest;
    if (rootManifest != null) {
      final String? key = _onlineBookKeyOf(rootManifest);
      if (key != null &&
          await readDownloadLibraryChapterPayload(folder.directory) != null) {
        keys.add(key);
      }
    }
    return keys;
  }

  /// 单章根 manifest 目录的唯一身份是否歧义。
  bool _isAmbiguousRootManifest(
    DownloadMangaFolderOnDisk folder,
    Set<String> ambiguousOnlineBookKeys,
  ) {
    if (folder.chapters.any(
      (ChapterContainerOnDisk chapter) => chapter.manifest != null,
    )) {
      return false;
    }
    final MangaPagesManifest? rootManifest = folder.rootManifest;
    if (rootManifest == null) return false;
    final String? key = _onlineBookKeyOf(rootManifest);
    return key != null && ambiguousOnlineBookKeys.contains(key);
  }

  /// 处理完一个目录后刷新内存里的 membership 视图：同一身份若在本次运行中刚
  /// 被提升 / 新建，后续目录不应重复计数。
  Future<void> _refreshBookKeySets(
    DownloadMangaFolderOnDisk folder,
    Set<String> libraryBookKeys,
    Set<String> nonLibraryBookKeys,
  ) async {
    final Set<String> keys = <String>{
      localSourceBookKeyFor(folder.directory.path),
    };
    for (final MangaPagesManifest manifest in folder.manifests) {
      final String? key = _onlineBookKeyOf(manifest);
      if (key != null) keys.add(key);
    }
    for (final String key in keys) {
      final EpubBookRow? row = await database.getEpubBook(key);
      if (row == null || !row.isInLibrary) continue;
      libraryBookKeys.add(key);
      nonLibraryBookKeys.remove(key);
    }
  }

  String _relativeToDownloads(Directory directory) => p
      .relative(directory.path, from: downloadsRoot.path)
      .replaceAll('\\', '/');

  static String? _onlineBookKeyOf(MangaPagesManifest manifest) {
    final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
      manifest.sourceRuntime,
    );
    if (runtime == null) return null;
    return onlineMangaBookKeyFor(
      runtime: runtime,
      extensionPackage: manifest.extensionPackage,
      sourceId: manifest.sourceId,
      seriesKey: manifest.mangaKey,
    );
  }
}
