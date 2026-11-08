/// 书架「漫画下载」筛选的批量判定（ticket 06）：哪些漫画**至少有一章在本地
/// 可读**。
///
/// 口径（spec「排序与筛选与搜索」）：
/// - 在线漫画：Download library 里至少一章**完整**落盘（判据委托
///   [DownloadLibraryIndex.booksWithAnyCompleteChapter]）；
/// - 本地图源：作品目录在磁盘上实际存在（原地读取，目录存在 = 可读）；
/// - 文件缺失（Missing，含切换 Content root 后指向旧根的记录）不计为已下载。
///
/// 输入是 [`FushiDatabase.getMangaShelfReadSnapshot`] 的一次性快照——书架加载时
/// 批量算一次、缓存进页面 State，滚动与每帧重建都不再查库 / 探盘。
library;

import 'dart:io';

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

/// 批量计算「哪些漫画至少有一章本地可读」，返回已下载的 `bookKey` 集合。
///
/// [localSourceRoot] / [downloadsRoot] 是**当前** Content root 下的本地图源根与
/// Download library 根；任一为 null（测试壳 / 早期启动）时只按目录存在性判定，
/// 不做「旧根 = Missing」检查。两者都非空时，本地图源目录必须落在其中任一之下。
Future<Set<String>> computeMangaShelfDownloadedBookKeys(
  Iterable<MangaShelfChapterSource> books, {
  required FushiDatabase database,
  Directory? localSourceRoot,
  Directory? downloadsRoot,
}) async {
  final Map<String, ({String extractDir, Iterable<String> chapterKeys})>
  online = <String, ({String extractDir, Iterable<String> chapterKeys})>{};
  final List<MangaShelfChapterSource> localBooks = <MangaShelfChapterSource>[];
  for (final MangaShelfChapterSource book in books) {
    if (LocalSourceMetadata.tryParse(book.sourceMetadata) != null) {
      localBooks.add(book);
      continue;
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      book.sourceMetadata,
    );
    if (entry == null || entry.chapters.isEmpty) continue;
    online[book.bookKey] = (
      extractDir: book.extractDir,
      chapterKeys: <String>[
        for (final OnlineMangaChapter chapter in entry.chapters) chapter.key,
      ],
    );
  }
  final Set<String> downloaded = online.isEmpty
      ? <String>{}
      : await DownloadLibraryIndex(database).booksWithAnyCompleteChapter(
          online,
          currentDownloadsRoot: downloadsRoot,
        );
  for (final MangaShelfChapterSource book in localBooks) {
    if (!await Directory(book.extractDir).exists()) continue;
    if (!_withinCurrentRoots(book.extractDir, <Directory?>[
      localSourceRoot,
      downloadsRoot,
    ])) {
      continue;
    }
    downloaded.add(book.bookKey);
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
