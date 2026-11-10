/// Download library 的读取/删除索引（storage-layout 票 04；CBZ 票 06）。
///
/// 磁盘布局是 `downloads/{source}/{manga}/{chapter}/`（页图平铺 + `pages.json`）
/// 或 `downloads/{source}/{manga}/{chapter}.cbz`（包根页图 + `pages.json`）。
/// 容器名不是身份：数据库的 `manga_chapter_dirs` 保存
/// `bookKey + chapterKey → 容器名 + 容器类型`，阅读器、作品页、完整性检查与删除
/// 都问这个索引，不再用章 key / 标题自行拼路径。
///
/// Ticket 12 删除了票 01 的旧哈希布局只读回退：fresh-start 语义下旧
/// `<content>/fushi_books/<bookKey>/chapters/<digest>/` 不再读取。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:fushi/src/media/manga/download/download_identity.dart';
import 'package:fushi/src/media/manga/download/download_library_scanner.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 一个已定位的章节载体：文件夹章节或 CBZ 压缩包章节。
///
/// 两种形态互斥：folder 容器有 [directory] / [manifestFile] /
/// [imagesDirectory]；archive 容器只有 [archiveFile]。
class MangaChapterContainer {
  const MangaChapterContainer.folder({
    required this.directory,
    required this.manifestFile,
    required this.imagesDirectory,
  }) : kind = MangaChapterContainerKind.folder,
       archiveFile = null;

  const MangaChapterContainer.archive({required this.archiveFile})
    : kind = MangaChapterContainerKind.archive,
      directory = null,
      manifestFile = null,
      imagesDirectory = null;

  /// 取 [MangaChapterContainerKind]。
  final MangaChapterContainerKind kind;

  /// 章节目录（`downloads/{source}/{manga}/{chapter}`）；archive 为 null。
  final Directory? directory;

  /// CBZ 压缩包（`downloads/{source}/{manga}/{chapter}.cbz`）；folder 为 null。
  final File? archiveFile;

  /// 章元数据文件（`pages.json`）；archive 为 null（页表在包根）。
  final File? manifestFile;

  /// 页图根：folder 容器就是章目录本身（页图平铺）；archive 为 null。
  final Directory? imagesDirectory;

  bool get isArchive => kind == MangaChapterContainerKind.archive;
}

/// [DownloadLibraryIndex.booksWithAnyCompleteChapter] 的输入项：一本书在
/// Download library 里的漫画目录与**当前**章节 key 列表。
///
/// 章节 key 来自书架快照（在线描述符 / `chaptersJson`），不是数据库映射表的
/// 全部行——映射表里可能残留描述符已经不再列出的历史章，那些不该让整本算已下载。
class MangaDownloadLibraryBook {
  const MangaDownloadLibraryBook({
    required this.extractDir,
    required this.chapterKeys,
  });

  /// Download library 里的漫画目录。
  final String extractDir;

  /// 当前章节身份列表。
  final Iterable<String> chapterKeys;
}

/// 按数据库映射解析章节载体与「已下载」判据。
class DownloadLibraryIndex {
  const DownloadLibraryIndex(
    this.database, {
    this.downloadsRoot,
    this.localComicRoot,
  });

  final FushiDatabase database;

  /// 当前 Content root 的 Download library 根；null = 生产解析 / 测试注入的
  /// EpubStorage 根派生。
  final Directory? downloadsRoot;

  /// 当前 Content root 的 Local source 根；null = 不扫描 `local`。
  final Directory? localComicRoot;

  /// 定位 [chapterKey] 的章目录。
  ///
  /// 只认数据库映射指向的新布局；返回 null = 磁盘上没有这章的容器
  /// （未下载或已被删）。
  Future<MangaChapterContainer?> resolveChapter({
    required String bookKey,
    required String chapterKey,
  }) async {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) return null;
    // Ticket 08：库里的章节路径记录切换 Content root 时**不重基**。解析时必须
    // 确认记录的漫画目录仍在**当前** Content root 的 Download library 下；指向
    // 旧根的记录一律视为找不到文件（Missing），绝不回头读旧路径。
    final Directory currentDownloadsRoot = await _downloadsRoot();
    final bool withinCurrentRoot = isLocalSourcePathWithinRoot(
      row.extractDir,
      currentDownloadsRoot,
    );
    final MangaChapterDirRow? mapping = await database.getMangaChapterDir(
      bookKey,
      chapterKey,
    );
    if (mapping != null && withinCurrentRoot) {
      final Directory mangaDir = Directory(row.extractDir);
      final String containerPath = p.join(row.extractDir, mapping.folderName);
      final bool withinMangaDir = isLocalSourcePathWithinRoot(
        containerPath,
        mangaDir,
      );
      if (!withinMangaDir) return null;
      if (mapping.containerKindEnum == MangaChapterContainerKind.archive) {
        final File file = downloadChapterArchiveFile(
          row.extractDir,
          mapping.folderName,
        );
        if (await file.exists()) {
          return MangaChapterContainer.archive(archiveFile: file);
        }
      } else {
        final Directory directory = downloadChapterDirectory(
          row.extractDir,
          mapping.folderName,
        );
        if (await directory.exists()) {
          return MangaChapterContainer.folder(
            directory: directory,
            manifestFile: downloadPagesManifestFile(directory),
            imagesDirectory: directory,
          );
        }
      }
    }
    return null;
  }

  /// 当前 Content root 下的 Download library 根。
  ///
  /// 与 `OnlineMangaLibraryService._downloadsRoot` 同一条测试缝：`EpubStorage` 测试根是
  /// `<tmp>/fushi_books`，Download library 派生到同级 `<tmp>/downloads`。
  Future<Directory> _downloadsRoot() async =>
      downloadsRoot ??
      _debugDownloadsRoot() ??
      AppPaths.downloadsRootDirectory();

  /// 测试注入的 EpubStorage 根派生出的 Download library 根；生产 / 未注入为 null。
  Directory? _debugDownloadsRoot() {
    final String? legacyBase = EpubStorage.debugBaseDirectoryOverridePath;
    if (legacyBase == null) return null;
    return Directory(p.join(p.dirname(legacyBase), 'downloads'));
  }

  /// 这一章是否**完整**下载（容器存在且 manifest + 全部页齐）。
  ///
  /// 文件夹章节检查章目录里的页文件；CBZ 章节检查包内条目。
  Future<bool> isChapterDownloaded({
    required String bookKey,
    required String chapterKey,
  }) async {
    final MangaChapterContainer? container = await resolveChapter(
      bookKey: bookKey,
      chapterKey: chapterKey,
    );
    if (container == null) return false;
    if (container.isArchive) {
      return await isDownloadLibraryArchiveComplete(container.archiveFile!);
    }
    return await readDownloadLibraryChapterPayload(container.directory!) !=
        null;
  }

  /// 一批章里哪些已完整下载（作品页 / 章节选择器一次算全量）。
  Future<Set<String>> downloadedChapterKeys(
    String bookKey,
    Iterable<String> chapterKeys,
  ) async {
    final Set<String> downloaded = <String>{};
    for (final String key in chapterKeys) {
      if (await isChapterDownloaded(bookKey: bookKey, chapterKey: key)) {
        downloaded.add(key);
      }
    }
    return downloaded;
  }

  /// 任意在线条目的已下载章（ticket 07）：不要求 Library 行。
  ///
  /// 有行时先走记录的映射（`extractDir` + `manga_chapter_dirs`，最精确）；
  /// 映射没覆盖到的章再按 entry 身份扫描 `downloads` 与 `local` 的
  /// `pages.json`。没有 manifest 的目录不按标题/文件夹名猜测；多个目录都能
  /// 证明同一身份时同样不猜（[MangaDownloadDiskIndex.downloadedChapterKeys]）。
  Future<Set<String>> downloadedChapterKeysForEntry(
    OnlineMangaLibraryEntry entry, {
    EpubBookRow? row,
    Iterable<String>? chapterKeys,
  }) async {
    final Set<String> wanted = <String>{
      ...(chapterKeys ??
          entry.chapters.map((OnlineMangaChapter chapter) => chapter.key)),
    };
    if (wanted.isEmpty) return <String>{};
    final Set<String> downloaded = row == null
        ? <String>{}
        : await downloadedChapterKeys(row.bookKey, wanted);
    if (downloaded.length == wanted.length) return downloaded;
    final MangaDownloadIdentity identity = MangaDownloadIdentity.ofEntry(entry);
    final MangaDownloadDiskIndex disk = await scanDisks(
      queries: <MangaDownloadDiskQuery>[
        MangaDownloadDiskQuery.ofEntry(entry),
      ],
    );
    downloaded.addAll(disk.downloadedChapterKeys(identity, wanted));
    return downloaded;
  }

  /// 扫描当前 Content root 的 `downloads` 与 `local`（只读 manifest 身份）。
  ///
  /// [queries] 带标题：同 Source 同标题的作品共享目录时，扫描会继续读同一
  /// 文件夹里的其余 manifest，确保每部作品都能按自己的 `pages.json` 命中。
  Future<MangaDownloadDiskIndex> scanDisks({
    required Iterable<MangaDownloadDiskQuery> queries,
  }) async => MangaDownloadDiskIndex.scan(
    downloadsRoot: await _downloadsRoot(),
    localComicRoot: localComicRoot,
    queries: queries,
  );

  /// 这批书里哪些**至少有一章完整落盘**（书架「已下载」筛选 / 页签数量的
  /// 批量口径，ticket 06）。
  ///
  /// 一次读全量 `manga_chapter_dirs` 映射，只为有映射的候选章探磁盘，不按书 /
  /// 按章反复查库；完整性判据与 [isChapterDownloaded] 相同（容器存在且
  /// manifest + 全部页齐）。书目录不在**当前** Download library 根下（切换
  /// Content root 后的旧路径 = Missing）整本不算已下载。
  Future<Set<String>> booksWithAnyCompleteChapter(
    Map<String, MangaDownloadLibraryBook> books, {
    Directory? currentDownloadsRoot,
  }) async {
    if (books.isEmpty) return <String>{};
    // 调用方（页面）传当前 Content root 的 Download library；测试壳没有
    // AppPaths 时回落到 [EpubStorage] 测试根的同级 `downloads`。两者都未知则
    // 跳过「旧根 = Missing」检查，只按容器完整性判定。
    final Directory? currentRoot =
        currentDownloadsRoot ?? _debugDownloadsRoot();
    final Map<String, Map<String, MangaChapterDirRow>> mappingsByBook =
        <String, Map<String, MangaChapterDirRow>>{};
    for (final MangaChapterDirRow row
        in await database.getAllMangaChapterDirRows()) {
      if (!books.containsKey(row.bookKey)) continue;
      (mappingsByBook[row.bookKey] ??=
              <String, MangaChapterDirRow>{})[row.chapterKey] =
          row;
    }
    final Set<String> downloaded = <String>{};
    for (final MapEntry<String, MangaDownloadLibraryBook> entry
        in books.entries) {
      final Map<String, MangaChapterDirRow>? mappings =
          mappingsByBook[entry.key];
      if (mappings == null || mappings.isEmpty) continue;
      final String extractDir = entry.value.extractDir;
      if (currentRoot != null &&
          !isLocalSourcePathWithinRoot(extractDir, currentRoot)) {
        continue;
      }
      final Directory mangaDir = Directory(extractDir);
      for (final String chapterKey in entry.value.chapterKeys) {
        final MangaChapterDirRow? mapping = mappings[chapterKey];
        if (mapping == null) continue;
        final String containerPath = p.join(extractDir, mapping.folderName);
        if (!isLocalSourcePathWithinRoot(containerPath, mangaDir)) continue;
        final bool complete;
        if (mapping.containerKindEnum == MangaChapterContainerKind.archive) {
          final File file = downloadChapterArchiveFile(
            extractDir,
            mapping.folderName,
          );
          complete =
              await file.exists() &&
              await isDownloadLibraryArchiveComplete(file);
        } else {
          final Directory directory = downloadChapterDirectory(
            extractDir,
            mapping.folderName,
          );
          complete =
              await directory.exists() &&
              await readDownloadLibraryChapterPayload(directory) != null;
        }
        if (complete) {
          downloaded.add(entry.key);
          break;
        }
      }
    }
    return downloaded;
  }

  /// 删除一章的磁盘内容，并清掉它的映射。
  ///
  /// 文件夹章节删章节目录；CBZ 章节删压缩包文件。容器不存在时静默
  /// （任务取消 / 重复删除）。旧哈希布局已不再解析，映射行仍清掉，避免留下
  /// 指向不存在容器的记录。
  Future<void> deleteChapter({
    required String bookKey,
    required String chapterKey,
  }) async {
    final MangaChapterContainer? container = await resolveChapter(
      bookKey: bookKey,
      chapterKey: chapterKey,
    );
    Directory? mangaDir;
    if (container != null) {
      if (container.isArchive) {
        final File file = container.archiveFile!;
        mangaDir = file.parent;
        if (await file.exists()) await file.delete();
      } else {
        final Directory directory = container.directory!;
        mangaDir = directory.parent;
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
    await database.deleteMangaChapterDir(bookKey, chapterKey);
    if (mangaDir != null) {
      await _cleanupEmptyDirectories(mangaDir, deletedBookKey: bookKey);
    }
  }

  /// 删除容器后清理空目录：空的 manga 目录与整个空 source 目录。
  ///
  /// 只清理当前 Download library 根下、刚被删空的目录；非空目录、Download
  /// library 根本身与 `local` 下的任何内容都不动。删除使用非递归模式：检查后
  /// 又被写入（并发下载 / 用户）时删除失败即放弃，绝不误删内容。
  ///
  /// 清理前检查目录是否仍被**其他作品**引用（同名共享目录里的另一部作品即使
  /// 此刻没有容器，也会在下次开始下载时复用这个目录）。共享目录里还有别的
  /// 作品容器时目录非空，天然不会被删。
  Future<void> _cleanupEmptyDirectories(
    Directory mangaDir, {
    String? deletedBookKey,
  }) async {
    final Directory root = await _downloadsRoot();
    if (!_isStrictlyWithin(mangaDir, root)) return;
    if (!await _isEmptyDirectory(mangaDir)) return;
    if (await _hasOtherWorkReference(mangaDir, deletedBookKey)) return;
    if (!await _deleteEmptyDirectory(mangaDir)) return;
    final Directory sourceDir = mangaDir.parent;
    if (!_isStrictlyWithin(sourceDir, root)) return;
    if (!await _isEmptyDirectory(sourceDir)) return;
    if (await _hasOtherWorkReference(sourceDir, deletedBookKey)) return;
    await _deleteEmptyDirectory(sourceDir);
  }

  /// [directory] 是否仍被 [exceptBookKey] 之外的作品行引用（目录本身或子目录）。
  Future<bool> _hasOtherWorkReference(
    Directory directory,
    String? exceptBookKey,
  ) async {
    for (final EpubBookMeta book in await database.getEpubBookMetas()) {
      if (book.bookKey == exceptBookKey) continue;
      if (isLocalSourcePathWithinRoot(book.extractDir, directory)) return true;
    }
    return false;
  }

  /// 目录存在且为空。
  static Future<bool> _isEmptyDirectory(Directory directory) async {
    try {
      return await directory.exists() &&
          await directory.list(followLinks: false).isEmpty;
    } on FileSystemException {
      return false;
    }
  }

  /// 非递归删除空目录；删除失败（被占用 / 竞态写入）静默放弃。
  static Future<bool> _deleteEmptyDirectory(Directory directory) async {
    try {
      await directory.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static bool _isStrictlyWithin(Directory directory, Directory root) =>
      p.isWithin(p.canonicalize(root.path), p.canonicalize(directory.path));

  /// 删除一章的下载：有行 / 映射时按记录删；没有行或映射没覆盖时按 [entry]
  /// 的下载身份在 `downloads` 里找唯一能证明身份的漫画文件夹，再删其中
  /// `chapterKey` 的容器。
  ///
  /// 票 08：非书架作品（含源页暂时没有 Manga 行的场景）不需要 Library 行也能
  /// 删除已显示为「已下载」的章节。身份判据与 [downloadedChapterKeysForEntry]
  /// 相同；同一根下多个文件夹都能证明同一身份时仍不猜（不删），避免误删。
  /// `local` 根不参与删除：本地原作文件不归「删除下载」管理。
  Future<void> deleteChapterForEntry({
    required OnlineMangaLibraryEntry entry,
    required String chapterKey,
    EpubBookRow? row,
  }) async {
    if (row != null) {
      final MangaChapterContainer? mapped = await resolveChapter(
        bookKey: row.bookKey,
        chapterKey: chapterKey,
      );
      if (mapped != null) {
        await deleteChapter(bookKey: row.bookKey, chapterKey: chapterKey);
        return;
      }
      // 映射已失效 / 从未写过：清掉残留行，再按身份找磁盘容器。
      await database.deleteMangaChapterDir(row.bookKey, chapterKey);
    }
    await _deleteChapterByIdentity(
      entry,
      chapterKey,
      deletedBookKey: row?.bookKey,
    );
  }

  Future<void> _deleteChapterByIdentity(
    OnlineMangaLibraryEntry entry,
    String chapterKey, {
    String? deletedBookKey,
  }) async {
    final MangaDownloadIdentity identity = MangaDownloadIdentity.ofEntry(entry);
    final List<DownloadMangaFolderOnDisk> folders = <DownloadMangaFolderOnDisk>[
      for (final DownloadMangaFolderProbe probe
          in await probeDownloadLibraryFolders(
            await _downloadsRoot(),
            queries: <MangaDownloadDiskQuery>[
              MangaDownloadDiskQuery.ofEntry(entry),
            ],
          ))
        probe.toFolder(),
    ];
    // 共享匹配器负责「恰好一个匹配 / 扩展包 tie-breaker / 多个不猜」；
    // 删除路径不再自己抄一遍，避免与已下载状态使用不同的判据。
    final DownloadMangaFolderOnDisk? folder =
        matchDownloadMangaFolderByIdentity(folders, identity).folder;
    if (folder == null) return;
    bool deleted = false;
    for (final ChapterContainerOnDisk container
        in await scanDownloadChapterContainers(folder.directory)) {
      final MangaPagesManifest? manifest = container.manifest;
      if (manifest == null ||
          manifest.chapterKey != chapterKey ||
          !identity.matchesManifest(manifest)) {
        continue;
      }
      final Directory? directory = container.directory;
      if (directory != null) {
        if (await directory.exists()) {
          await directory.delete(recursive: true);
          deleted = true;
        }
        continue;
      }
      final File? archive = container.archiveFile;
      if (archive != null && await archive.exists()) {
        await archive.delete();
        deleted = true;
      }
    }
    if (deleted) {
      await _cleanupEmptyDirectories(
        folder.directory,
        deletedBookKey: deletedBookKey,
      );
    }
  }
}

/// 当前 Content root 下 `downloads` 与 `local` 的 manifest 身份索引。
///
/// 只认 `pages.json` 证明的身份，目录名（标题）不参与匹配。扫描分两段：
/// 1. 每个 Manga 文件夹只读第一份 manifest 做身份探针；
/// 2. 只有被某个查询身份匹配到的文件夹才读完整章表并检查完整性。
/// 这样查一部作品的已下载状态不会把全库每一章都验证一遍。
class MangaDownloadDiskIndex {
  const MangaDownloadDiskIndex._(this._entries);

  static Future<MangaDownloadDiskIndex> scan({
    required Directory? downloadsRoot,
    required Directory? localComicRoot,
    required Iterable<MangaDownloadDiskQuery> queries,
  }) async {
    final List<MangaDownloadDiskQuery> wanted = queries.toList(growable: false);
    final List<({MangaDownloadIdentity identity, Set<String> chapterKeys})>
    entries = <({MangaDownloadIdentity identity, Set<String> chapterKeys})>[];
    if (wanted.isEmpty) return MangaDownloadDiskIndex._(entries);

    // (探针, 是否是 local 根)。downloads 的 manifest 只在章节容器里；
    // local 还要接受单章作品把 pages.json 放在 Manga 目录根。
    final List<({List<DownloadMangaFolderProbe> probes, bool local})> roots =
        <({List<DownloadMangaFolderProbe> probes, bool local})>[
          if (downloadsRoot != null)
            (
              probes: await probeDownloadLibraryFolders(
                downloadsRoot,
                // 共享目录：第一份 manifest 可能属于另一部同名作品。
                queries: wanted,
              ),
              local: false,
            ),
          if (localComicRoot != null)
            (probes: await probeLocalMangaFolders(localComicRoot), local: true),
        ];
    for (final ({List<DownloadMangaFolderProbe> probes, bool local}) root
        in roots) {
      // 探针只包含有 manifest 的目录：无 manifest 的目录不参与匹配。
      final List<DownloadMangaFolderOnDisk> probeFolders =
          <DownloadMangaFolderOnDisk>[
            for (final DownloadMangaFolderProbe probe in root.probes)
              if (probe.manifest != null) probe.toFolder(),
          ];
      if (probeFolders.isEmpty) continue;
      for (final MangaDownloadDiskQuery query in wanted) {
        final DownloadMangaFolderOnDisk? folder =
            matchDownloadMangaFolderByIdentity(
              probeFolders,
              query.identity,
            ).folder;
        if (folder == null) continue;
        entries.add((
          identity: query.identity,
          chapterKeys: await _completeChapterKeys(
            folder.directory,
            query.identity,
            includeMangaRootManifest: root.local,
          ),
        ));
      }
    }
    return MangaDownloadDiskIndex._(entries);
  }

  final List<({MangaDownloadIdentity identity, Set<String> chapterKeys})>
  _entries;

  /// 由 manifest 证明属于 [identity]、且容器完整落盘的章。
  ///
  /// 没有 manifest / `pages.json` 不完整的章不算已下载；调用方再按当前章表
  /// 取交集。
  Set<String> downloadedChapterKeys(
    MangaDownloadIdentity identity,
    Iterable<String> chapterKeys,
  ) {
    final Set<String> wanted = chapterKeys.toSet();
    if (wanted.isEmpty) return <String>{};
    final Set<String> downloaded = <String>{};
    for (final ({MangaDownloadIdentity identity, Set<String> chapterKeys}) entry
        in _entries) {
      if (!entry.identity.matches(identity)) continue;
      for (final String chapterKey in entry.chapterKeys) {
        if (wanted.contains(chapterKey)) downloaded.add(chapterKey);
      }
    }
    return downloaded;
  }

  static Future<Set<String>> _completeChapterKeys(
    Directory mangaFolder,
    MangaDownloadIdentity identity, {
    required bool includeMangaRootManifest,
  }) async {
    final Set<String> keys = <String>{};
    for (final ChapterContainerOnDisk chapter
        in await scanDownloadChapterContainers(
          mangaFolder,
          readComplete: true,
        )) {
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest == null ||
          !chapter.complete ||
          !identity.matchesManifest(manifest)) {
        continue;
      }
      keys.add(manifest.chapterKey);
    }
    if (includeMangaRootManifest) {
      final MangaPagesManifest? rootManifest = await readPagesManifest(
        mangaFolder,
      );
      if (rootManifest != null &&
          identity.matchesManifest(rootManifest) &&
          await readDownloadLibraryChapterPayload(mangaFolder) != null) {
        keys.add(rootManifest.chapterKey);
      }
    }
    return keys;
  }
}
