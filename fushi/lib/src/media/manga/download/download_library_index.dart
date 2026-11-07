/// Download library 的读取/删除索引（storage-layout 票 04）。
///
/// 磁盘布局是 `downloads/{source}/{manga}/{chapter}/`（页图平铺 + `pages.json`）。
/// 目录名不是身份：数据库的 `manga_chapter_dirs` 保存
/// `bookKey + chapterKey → folderName`，阅读器、作品页与删除都问这个索引，
/// 不再用章 key / 标题自行拼路径。
///
/// 旧版哈希布局（`<content>/fushi_books/<bookKey>/chapters/<digest>/`）只作为
/// **只读回退**保留：票 01 保留旧布局直到后续票清理，fresh-start 不迁移旧数据。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/manga_chapter_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// 一个已定位的章节载体。
class MangaChapterContainer {
  const MangaChapterContainer({
    required this.directory,
    required this.manifestFile,
    required this.imagesDirectory,
    required this.legacyLayout,
  });

  /// 章节目录（新布局：`downloads/{source}/{manga}/{chapter}`；
  /// 旧布局：`chapters/<digest>`）。
  final Directory directory;

  /// 章元数据文件（新布局 `pages.json`；旧布局 `manga.json`）。
  final File manifestFile;

  /// 页图根：新布局就是章目录本身（页图平铺），旧布局是 `images/`。
  final Directory imagesDirectory;

  /// 是否旧哈希布局（`chapterDir/manga.json + images/`）。
  final bool legacyLayout;
}

/// 按数据库映射解析章节载体与「已下载」判据。
class DownloadLibraryIndex {
  const DownloadLibraryIndex(this.database);

  final FushiDatabase database;

  /// 定位 [chapterKey] 的章目录。
  ///
  /// 优先映射指向的新布局；映射缺失/目录不在时回退旧哈希布局（只读兼容）。
  /// 返回 null = 磁盘上没有这章的容器（未下载或已被删）。
  Future<MangaChapterContainer?> resolveChapter({
    required String bookKey,
    required String chapterKey,
  }) async {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) return null;
    // Ticket 08：库里的章节路径记录切换 Content root 时**不重基**。解析时必须
    // 确认记录的漫画目录仍在**当前** Content root 的 Download library 下；指向
    // 旧根的记录一律视为找不到文件（Missing），绝不回头读旧路径。
    final String downloadsRoot = p.canonicalize((await _downloadsRoot()).path);
    final String recordedMangaDir = p.canonicalize(row.extractDir);
    final bool withinCurrentRoot =
        p.equals(downloadsRoot, recordedMangaDir) ||
        p.isWithin(downloadsRoot, recordedMangaDir);
    final MangaChapterDirRow? mapping = await database.getMangaChapterDir(
      bookKey,
      chapterKey,
    );
    if (mapping != null && withinCurrentRoot) {
      final Directory directory = downloadChapterDirectory(
        row.extractDir,
        mapping.folderName,
      );
      final String canonicalDirectory = p.canonicalize(directory.path);
      final bool withinMangaDir =
          p.equals(p.canonicalize(row.extractDir), canonicalDirectory) ||
          p.isWithin(p.canonicalize(row.extractDir), canonicalDirectory);
      if (withinMangaDir && await directory.exists()) {
        return MangaChapterContainer(
          directory: directory,
          manifestFile: downloadPagesManifestFile(directory),
          imagesDirectory: directory,
          legacyLayout: false,
        );
      }
    }
    // 票 01 的旧哈希布局：`<content>/fushi_books/<bookKey>/chapters/<digest>`。
    // 路径由 EpubStorage 解析，天然只指向**当前** Content root。
    final Directory legacyDirectory = mangaChapterDirectory(
      await MangaStorage.bookPath(bookKey),
      chapterKey,
    );
    if (await legacyDirectory.exists()) {
      return MangaChapterContainer(
        directory: legacyDirectory,
        manifestFile: mangaChapterJsonFile(legacyDirectory),
        imagesDirectory: mangaChapterImagesDirectory(legacyDirectory),
        legacyLayout: true,
      );
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

  /// 这一章是否**完整**下载（容器存在且 manifest + 全部页文件齐）。
  Future<bool> isChapterDownloaded({
    required String bookKey,
    required String chapterKey,
  }) async {
    final MangaChapterContainer? container = await resolveChapter(
      bookKey: bookKey,
      chapterKey: chapterKey,
    );
    if (container == null) return false;
    if (container.legacyLayout) {
      return await readDownloadedChapterPayload(container.directory) != null;
    }
    return await readDownloadLibraryChapterPayload(container.directory) != null;
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
  /// 目录不存在时静默（任务取消 / 重复删除）；旧布局也按旧判据删。
  Future<void> deleteChapter({
    required String bookKey,
    required String chapterKey,
  }) async {
    final MangaChapterContainer? container = await resolveChapter(
      bookKey: bookKey,
      chapterKey: chapterKey,
    );
    if (container != null && await container.directory.exists()) {
      await container.directory.delete(recursive: true);
    }
    await database.deleteMangaChapterDir(bookKey, chapterKey);
  }
}
