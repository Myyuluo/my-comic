/// Download library 的读取/删除索引（storage-layout 票 04；CBZ 票 06）。
///
/// 磁盘布局是 `downloads/{source}/{manga}/{chapter}/`（页图平铺 + `pages.json`）
/// 或 `downloads/{source}/{manga}/{chapter}.cbz`（包根页图 + `pages.json`）。
/// 容器名不是身份：数据库的 `manga_chapter_dirs` 保存
/// `bookKey + chapterKey → 容器名 + 容器类型`，阅读器、作品页、完整性检查与删除
/// 都问这个索引，不再用章 key / 标题自行拼路径。
///
/// Ticket 12 删除了票 01 的旧哈希布局只读回退：fresh-start 语义下旧
/// `<content>/my_comic_books/<bookKey>/chapters/<digest>/` 不再读取。
library;

import 'dart:io';

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/book_storage.dart';
import 'package:my_comic_engine/media/manga/download_library_storage.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:my_comic/src/media/manga/download/download_identity.dart';
import 'package:my_comic/src/media/manga/download/download_library_scanner.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/storage/app_paths.dart';

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
       archiveFile = null,
       isMangaRoot = false;

  /// 单章作品的根容器：`pages.json` 直接住在漫画目录根。
  ///
  /// 它不是一个章子目录（不能写 `<manga>/<manga>` 映射），但渲染与阅读都按
  /// 「目录根 + 根 manifest」处理。
  const MangaChapterContainer.mangaRoot({
    required Directory this.directory,
    required File this.manifestFile,
  }) : kind = MangaChapterContainerKind.folder,
       archiveFile = null,
       imagesDirectory = directory,
       isMangaRoot = true;

  const MangaChapterContainer.archive({required this.archiveFile})
    : kind = MangaChapterContainerKind.archive,
      directory = null,
      manifestFile = null,
      imagesDirectory = null,
      isMangaRoot = false;

  /// 取 [MangaChapterContainerKind]。
  final MangaChapterContainerKind kind;

  /// 章节目录（`downloads/{source}/{manga}/{chapter}`）；archive 为 null。
  ///
  /// 根 manifest 单章作品返回漫画目录本身。
  final Directory? directory;

  /// CBZ 压缩包（`downloads/{source}/{manga}/{chapter}.cbz`）；folder 为 null。
  final File? archiveFile;

  /// 章元数据文件（`pages.json`）；archive 为 null（页表在包根）。
  final File? manifestFile;

  /// 页图根：folder 容器就是章目录本身（页图平铺）；archive 为 null。
  final Directory? imagesDirectory;

  /// 是否是单章作品根 manifest 的容器（不是章子目录）。
  final bool isMangaRoot;

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

  final MyComicDatabase database;

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
    // 单章作品把 pages.json 直接放在漫画目录根：没有章子目录映射，但这一章
    // 确实可读（ticket 06）。只对当前行自己的漫画目录生效，且必须由 manifest
    // 证明属于同一部作品。
    return _resolveMangaRootManifest(
      row,
      chapterKey,
      downloadsRoot: currentDownloadsRoot,
    );
  }

  /// 根 manifest 单章作品的容器；不是 / 读不了返回 null。
  Future<MangaChapterContainer?> _resolveMangaRootManifest(
    EpubBookRow row,
    String chapterKey, {
    required Directory downloadsRoot,
  }) async {
    final Directory mangaDir = Directory(row.extractDir);
    if (!await mangaDir.exists()) return null;
    final bool withinDownloads = isLocalSourcePathWithinRoot(
      row.extractDir,
      downloadsRoot,
    );
    bool withinLocal = false;
    if (!withinDownloads) {
      final Directory? localRoot = await _resolvedLocalComicRoot();
      withinLocal =
          localRoot != null &&
          isLocalSourcePathWithinRoot(row.extractDir, localRoot);
    }
    if (!withinDownloads && !withinLocal) return null;
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) return null;
    final MangaPagesManifest? manifest = await readPagesManifest(mangaDir);
    if (manifest == null || manifest.chapterKey != chapterKey) return null;
    if (!MangaDownloadIdentity.ofEntry(entry).matchesManifest(manifest)) {
      return null;
    }
    if (await readDownloadLibraryChapterPayload(mangaDir) == null) return null;
    return MangaChapterContainer.mangaRoot(
      directory: mangaDir,
      manifestFile: downloadPagesManifestFile(mangaDir),
    );
  }

  /// 当前 Content root 下的 Download library 根。
  ///
  /// 与 `OnlineMangaLibraryService._downloadsRoot` 同一条测试缝：`EpubStorage` 测试根是
  /// `<tmp>/my_comic_books`，Download library 派生到同级 `<tmp>/downloads`。
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

  /// 当前 Content root 下的 Local source 根；解析不了返回 null。
  Future<Directory?> _resolvedLocalComicRoot() async {
    final Directory? injected = localComicRoot;
    if (injected != null) return injected;
    final String? legacyBase = EpubStorage.debugBaseDirectoryOverridePath;
    if (legacyBase != null) {
      return Directory(p.join(p.dirname(legacyBase), 'local'));
    }
    try {
      return await AppPaths.localComicRootDirectory();
    } on Object {
      return null;
    }
  }

  /// 这一章是否已下载（容器存在且可读）。
  ///
  /// 有 `pages.json` 的容器按完整性判（manifest + 全部页齐）；没有可用
  /// `pages.json` 的用户容器（ticket 06）只要可读即算已下载——它可能正是
  /// 按容器名关联上的普通文件夹或 CBZ。容器存在但读不出任何页仍不算。
  Future<bool> isChapterDownloaded({
    required String bookKey,
    required String chapterKey,
  }) async {
    final MangaChapterContainer? container = await resolveChapter(
      bookKey: bookKey,
      chapterKey: chapterKey,
    );
    if (container == null) return false;
    return _isContainerDownloaded(container);
  }

  /// [container] 是否可读（有 manifest 时仍要求完整）。
  Future<bool> _isContainerDownloaded(MangaChapterContainer container) async {
    // 根 manifest 容器由 [_resolveMangaRootManifest] 验证过身份与页负载。
    if (container.isMangaRoot) return true;
    if (container.isArchive) {
      final File file = container.archiveFile!;
      final MangaPagesManifest? manifest =
          await readDownloadLibraryArchiveManifest(file);
      if (manifest != null) return await isDownloadLibraryArchiveComplete(file);
      return await isDownloadLibraryArchiveReadable(file);
    }
    final Directory directory = container.directory!;
    final MangaPagesManifest? manifest = await readPagesManifest(directory);
    if (manifest != null) {
      return await readDownloadLibraryChapterPayload(directory) != null;
    }
    return await isDownloadLibraryFolderReadable(directory);
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
      queries: <MangaDownloadDiskQuery>[MangaDownloadDiskQuery.ofEntry(entry)],
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
        // 与单章判据共用同一份「已下载」口径（ticket 06）：有 manifest 的
        // 要求完整；用户提供的无 manifest 容器只要可读即算。
        final MangaChapterContainer container =
            mapping.containerKindEnum == MangaChapterContainerKind.archive
            ? MangaChapterContainer.archive(
                archiveFile: downloadChapterArchiveFile(
                  extractDir,
                  mapping.folderName,
                ),
              )
            : MangaChapterContainer.folder(
                directory: downloadChapterDirectory(
                  extractDir,
                  mapping.folderName,
                ),
                manifestFile: downloadPagesManifestFile(
                  downloadChapterDirectory(extractDir, mapping.folderName),
                ),
                imagesDirectory: downloadChapterDirectory(
                  extractDir,
                  mapping.folderName,
                ),
              );
        final bool complete = await _isContainerDownloaded(container);
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
  ///
  /// 删除只作用于**当前 Download library 根**内、且能证明属于目标作品的容器：
  /// Local source 根下的用户原件一律拒绝（不删文件、保留映射）；共享目录里
  /// 只由另一部作品映射的无 manifest 容器同样拒绝，不猜归属。
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
      final Directory downloadsRoot = await _downloadsRoot();
      if (!_isContainerWithinDownloads(container, downloadsRoot)) {
        // local 根下的用户原件（含单章根 manifest）不属于「删除下载」。
        return;
      }
      final EpubBookRow? row = await database.getEpubBook(bookKey);
      if (!await _isContainerOwnedBy(row, container)) return;
      if (container.isMangaRoot) {
        // 单章作品的负载直接住在漫画目录根：只删根 manifest 与它声明的页，
        // 绝不递归删除目录（共享目录里可能还有别的作品 / 用户文件）。
        mangaDir = container.directory!;
        await _deleteMangaRootPayload(mangaDir);
      } else if (container.isArchive) {
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

  /// [container] 是否位于当前 Download library 根内（可被「删除下载」管理）。
  bool _isContainerWithinDownloads(
    MangaChapterContainer container,
    Directory downloadsRoot,
  ) {
    final String? path =
        container.archiveFile?.path ?? container.directory?.path;
    if (path == null) return false;
    return _isStrictlyWithinPath(path, downloadsRoot);
  }

  /// [container] 是否能证明属于 [row] 对应的作品（删除前的安全闸）。
  ///
  /// - 根 manifest 容器已由 [resolveChapter] 校验身份；
  /// - 有身份的章节容器：`pages.json` 必须匹配目标作品；
  /// - 无 manifest / 行没有描述符的历史数据：只能由**唯一**映射证明归属——
  ///   同一物理容器被另一部作品也映射时视为归属不明，拒绝删除。
  Future<bool> _isContainerOwnedBy(
    EpubBookRow? row,
    MangaChapterContainer container,
  ) async {
    if (container.isMangaRoot) return true;
    final MangaPagesManifest? manifest = container.isArchive
        ? await readDownloadLibraryArchiveManifest(container.archiveFile!)
        : await readPagesManifest(container.directory!);
    if (manifest != null) {
      final OnlineMangaLibraryEntry? entry = row == null
          ? null
          : OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
      if (entry != null) {
        return MangaDownloadIdentity.ofEntry(entry).matchesManifest(manifest);
      }
      // 行没有在线描述符（历史数据）：继续用唯一映射证明。
    }
    if (row == null) return false;
    return _isContainerMappedOnlyBy(row.bookKey, container);
  }

  /// 除 [bookKey] 外是否还有作品映射到同一物理容器。
  Future<bool> _isContainerMappedOnlyBy(
    String bookKey,
    MangaChapterContainer container,
  ) async {
    final String? path =
        container.archiveFile?.path ?? container.directory?.path;
    if (path == null) return false;
    final String target = p.canonicalize(path);
    final Map<String, String> extractDirs = <String, String>{
      for (final EpubBookRow row in await database.getAllEpubBooks())
        row.bookKey: row.extractDir,
    };
    for (final MangaChapterDirRow mapping
        in await database.getAllMangaChapterDirRows()) {
      if (mapping.bookKey == bookKey) continue;
      final String? extractDir = extractDirs[mapping.bookKey];
      if (extractDir == null) continue;
      final String mapped = p.canonicalize(
        p.join(extractDir, mapping.folderName),
      );
      if (mapped == target) return false;
    }
    return true;
  }

  /// 这批**已下载**章里哪些可以由「删除下载」删除。
  ///
  /// 与 [deleteChapterForEntry] 同一判据：映射解析到当前 `downloads` 根内的
  /// 容器才算可删；解析不到映射的章再按身份扫描 `downloads`（不含 `local`）。
  /// Local source 根下的用户原件、旧 Content root 的路径一律不算；UI 据此不
  /// 提供会静默删除用户文件的操作。
  Future<Set<String>> deletableChapterKeysForEntry(
    OnlineMangaLibraryEntry entry, {
    EpubBookRow? row,
    required Iterable<String> downloadedChapterKeys,
  }) async {
    final Set<String> wanted = downloadedChapterKeys.toSet();
    if (wanted.isEmpty) return <String>{};
    final Directory downloadsRoot = await _downloadsRoot();
    final Set<String> deletable = <String>{};
    final Set<String> mapped = <String>{};
    if (row != null) {
      for (final String chapterKey in wanted) {
        final MangaChapterContainer? container = await resolveChapter(
          bookKey: row.bookKey,
          chapterKey: chapterKey,
        );
        if (container == null) continue;
        mapped.add(chapterKey);
        if (_isContainerWithinDownloads(container, downloadsRoot) &&
            await _isContainerOwnedBy(row, container)) {
          deletable.add(chapterKey);
        }
      }
    }
    // 没有映射的章走删除路径的同一份身份扫描（只扫 downloads）：有身份证明
    // 的容器即使没有数据库映射也能安全删除。
    final Set<String> unmapped = wanted.difference(mapped);
    if (unmapped.isNotEmpty) {
      final MangaDownloadDiskIndex disk = await MangaDownloadDiskIndex.scan(
        downloadsRoot: downloadsRoot,
        localComicRoot: null,
        queries: <MangaDownloadDiskQuery>[
          MangaDownloadDiskQuery.ofEntry(entry),
        ],
      );
      deletable.addAll(
        disk.downloadedChapterKeys(
          MangaDownloadIdentity.ofEntry(entry),
          unmapped,
        ),
      );
    }
    return deletable;
  }

  /// 删除单章作品根 manifest 的下载负载：声明页 + `pages.json`。
  ///
  /// 只删根目录内由 manifest 声明的文件；`cover.jpg` 等既有文件、子目录里的
  /// 其他作品容器都原样保留。返回是否真的删了东西。
  Future<bool> _deleteMangaRootPayload(
    Directory mangaDir, {
    MangaPagesManifest? manifest,
  }) async {
    final MangaPagesManifest? pages =
        manifest ?? await readPagesManifest(mangaDir);
    if (pages == null) return false;
    final String root = p.canonicalize(mangaDir.path);
    bool deleted = false;
    for (final MokuroImage image in pages.payload.images) {
      final String relative = normalizeMangaUrl(image.url);
      if (relative.isEmpty) continue;
      final String candidate = p.canonicalize(p.join(root, relative));
      if (!p.isWithin(root, candidate)) continue;
      final File file = File(candidate);
      if (await file.exists()) {
        await file.delete();
        deleted = true;
      }
    }
    final File manifestFile = downloadPagesManifestFile(mangaDir);
    if (await manifestFile.exists()) {
      await manifestFile.delete();
      deleted = true;
    }
    return deleted;
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

  static bool _isStrictlyWithinPath(String path, Directory root) =>
      p.isWithin(p.canonicalize(root.path), p.canonicalize(path));

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
    // 单章作品根 manifest：没有章容器可删，清空根负载（页 + pages.json），
    // 但保留目录里的其他文件与其他作品容器。
    final MangaPagesManifest? rootManifest = await readPagesManifest(
      folder.directory,
    );
    if (rootManifest != null &&
        rootManifest.chapterKey == chapterKey &&
        identity.matchesManifest(rootManifest)) {
      final bool rootDeleted = await _deleteMangaRootPayload(
        folder.directory,
        manifest: rootManifest,
      );
      deleted = deleted || rootDeleted;
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
            // 单章作品的根 pages.json 在两个根下都能证明这一章可读。
            includeMangaRootManifest: true,
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
