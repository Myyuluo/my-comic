/// 书架「漫画下载」筛选的批量判定（ticket 06）：哪些漫画**至少有一章在本地
/// 可读**。
///
/// 口径（spec「排序与筛选与搜索」）：
/// - 在线漫画：Download library 里至少一章**完整**落盘（判据委托
///   [DownloadLibraryIndex.booksWithAnyCompleteChapter]）。Ticket 07 起，映射
///   没证明已下载时再按 entry 身份扫 `downloads` / `local` 的 manifest——与
///   作品页共用 [MangaDownloadDiskIndex]，且无 manifest 的目录不按标题匹配；
/// - 本地图源：漫画目录里至少一章**真的读得出来**（文件夹含页图或可解析的
///   `.cbz`；单章作品的章就是漫画目录本身）。只看目录存在会让「章文件全被删、
///   只剩空目录」的作品仍算已下载（复审 finding 11），判据复用 Local source 的
///   扫描器 [scanLocalSourceMangaDirectory]；
/// - 文件缺失（Missing，含切换 Content root 后指向旧根的记录）不计为已下载。
///
/// 输入是 [`FushiDatabase.getMangaShelfReadSnapshot`] 的一次性快照——书架加载时
/// 批量算一次、缓存进页面 State，滚动与每帧重建都不再查库 / 探盘。
library;

import 'dart:io';

import 'package:fushi/src/media/manga/download/download_identity.dart';
import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_chapter_source.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

/// 批量计算「哪些漫画至少有一章本地可读」，返回已下载的 `bookKey` 集合。
///
/// [localSourceRoot] / [downloadsRoot] 是**当前** Content root 下的本地图源根与
/// Download library 根；任一为 null（测试壳 / 早期启动）时跳过「旧根 = Missing」
/// 检查。两者都非空时，本地图源目录必须落在其中任一之下。
Future<Set<String>> computeMangaShelfDownloadedBookKeys(
  Iterable<MangaShelfChapterSource> books, {
  required FushiDatabase database,
  Directory? localSourceRoot,
  Directory? downloadsRoot,
}) async {
  final Map<String, MangaDownloadLibraryBook> online =
      <String, MangaDownloadLibraryBook>{};
  // 映射查不到「已下载」时，用同一份 entry 身份扫描 downloads / local 的
  // manifest（ticket 07）。与作品页共用 [MangaDownloadDiskIndex]。
  final Map<String, ({OnlineMangaLibraryEntry entry, Set<String> chapterKeys})>
  onlineEntries =
      <String, ({OnlineMangaLibraryEntry entry, Set<String> chapterKeys})>{};
  final List<({MangaShelfChapterSource book, LocalSourceMetadata metadata})>
      localBooks =
      <({MangaShelfChapterSource book, LocalSourceMetadata metadata})>[];
  for (final MangaShelfChapterSource book in books) {
    final LocalSourceMetadata? localMetadata = LocalSourceMetadata.tryParse(
      book.sourceMetadata,
    );
    if (localMetadata != null) {
      localBooks.add((book: book, metadata: localMetadata));
      continue;
    }
    final List<String> chapterKeys = book.chapterKeys;
    if (chapterKeys.isEmpty) continue;
    online[book.bookKey] = MangaDownloadLibraryBook(
      extractDir: book.extractDir,
      chapterKeys: chapterKeys,
    );
    final OnlineMangaLibraryEntry? entry = book.onlineEntry;
    if (entry != null) {
      onlineEntries[book.bookKey] = (
        entry: entry,
        chapterKeys: chapterKeys.toSet(),
      );
    }
  }
  final Set<String> downloaded = online.isEmpty
      ? <String>{}
      : await DownloadLibraryIndex(database).booksWithAnyCompleteChapter(
          online,
          currentDownloadsRoot: downloadsRoot,
        );
  final List<String> pendingManifestScan = <String>[
    for (final String bookKey in online.keys)
      if (!downloaded.contains(bookKey) && onlineEntries.containsKey(bookKey))
        bookKey,
  ];
  if (pendingManifestScan.isNotEmpty) {
    final Map<String, MangaDownloadIdentity> identities =
        <String, MangaDownloadIdentity>{
          for (final String bookKey in pendingManifestScan)
            bookKey: MangaDownloadIdentity.ofEntry(
              onlineEntries[bookKey]!.entry,
            ),
        };
    final MangaDownloadDiskIndex disk = await DownloadLibraryIndex(
      database,
      downloadsRoot: downloadsRoot,
      localComicRoot: localSourceRoot,
    ).scanDisks(identities: identities.values);
    for (final String bookKey in pendingManifestScan) {
      final ({OnlineMangaLibraryEntry entry, Set<String> chapterKeys}) info =
          onlineEntries[bookKey]!;
      if (disk
          .downloadedChapterKeys(identities[bookKey]!, info.chapterKeys)
          .isNotEmpty) {
        downloaded.add(bookKey);
      }
    }
  }
  for (final ({MangaShelfChapterSource book, LocalSourceMetadata metadata})
      local
      in localBooks) {
    if (!_withinCurrentRoots(local.book.extractDir, <Directory?>[
      localSourceRoot,
      downloadsRoot,
    ])) {
      continue;
    }
    // 目录存在但一章都读不出来（页图全删 / 只剩封面 / 空目录 / 坏包）不算
    // 已下载。扫描器与「本地图源」网格、重建索引同一套章节识别规则。
    final LocalSourceManga? scanned = await scanLocalSourceMangaDirectory(
      Directory(local.book.extractDir),
      relativePath: local.metadata.relativePath,
    );
    if (scanned != null) downloaded.add(local.book.bookKey);
  }
  return downloaded;
}

/// 路径是否落在任一已解析的当前根下；根全部未知时返回 true（只按存在性判定）。
bool _withinCurrentRoots(String path, Iterable<Directory?> roots) {
  final List<Directory> known = <Directory>[
    for (final Directory? root in roots)
      if (root != null) root,
  ];
  if (known.isEmpty) return true;
  return known.any((Directory root) => isLocalSourcePathWithinRoot(path, root));
}
