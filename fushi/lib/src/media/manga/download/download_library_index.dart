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
  final String kind;

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

/// 按数据库映射解析章节载体与「已下载」判据。
class DownloadLibraryIndex {
  const DownloadLibraryIndex(this.database);

  final FushiDatabase database;

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
      if (mapping.containerKind == MangaChapterContainerKind.archive) {
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
  Future<Directory> _downloadsRoot() async {
    final String? legacyBase = EpubStorage.debugBaseDirectoryOverridePath;
    if (legacyBase != null) {
      return Directory(p.join(p.dirname(legacyBase), 'downloads'));
    }
    return AppPaths.downloadsRootDirectory();
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
    if (container != null) {
      if (container.isArchive) {
        final File file = container.archiveFile!;
        if (await file.exists()) await file.delete();
      } else {
        final Directory directory = container.directory!;
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
    await database.deleteMangaChapterDir(bookKey, chapterKey);
  }
}
