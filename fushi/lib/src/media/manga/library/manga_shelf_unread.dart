import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

/// 漫画书架未读角标的批量计算：输入
/// [`FushiDatabase.getMangaShelfReadSnapshot`] 的一次性快照，输出
/// `bookKey → 未读章节数`（0 未读的书不出现在结果里）。
///
/// 口径（ticket 03 / spec「封面角标」）：
/// - 范围 = **当前章节列表**（在线描述符里的 `chapters`；本地图源
///   `chaptersJson`），列表外的历史章状态不计；
/// - 未读 = 该章没有已读标记（`readAt == null`）。读到一半（有页码但没读完整章）
///   同样算未读；锁定章、未下载章也照常计入——它们只是还没读，不是已读；
/// - 章节身份以 `key` 对齐 `manga_chapter_states.chapter_key`。
///
/// 全程只在内存里比对两个集合，不查库、不碰文件系统，供书架滚动路径直接使用。
Map<String, int> computeMangaShelfUnreadCounts(
  MangaShelfReadSnapshot snapshot,
) {
  final Map<String, int> unreadByBookKey = <String, int>{};
  for (final MangaShelfChapterSource book in snapshot.books) {
    final List<String> chapterKeys = _chapterKeysOf(book);
    if (chapterKeys.isEmpty) continue;
    final Set<String> readKeys =
        snapshot.readChapterKeysByBookUid[book.bookUid] ?? const <String>{};
    int unread = 0;
    for (final String chapterKey in chapterKeys) {
      if (!readKeys.contains(chapterKey)) unread++;
    }
    if (unread > 0) unreadByBookKey[book.bookKey] = unread;
  }
  return unreadByBookKey;
}

/// 一部漫画当前的章节身份列表。
///
/// 在线条目的权威来源是 `sourceMetadata` 描述符；其余（本地图源、或描述符损坏
/// 但 `chaptersJson` 还在的在线条目）回退到 `chaptersJson`。两种落库形状都以
/// `key` 为章节身份，`decodeLocalSourceChapters` 恰好只依赖这个字段；普通 EPUB
/// 章节 JSON 没有 `key`，解出空表 → 未读数 0（角标隐藏）。
List<String> _chapterKeysOf(MangaShelfChapterSource book) {
  final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
    book.sourceMetadata,
  );
  if (entry != null) {
    return <String>[
      for (final OnlineMangaChapter chapter in entry.chapters) chapter.key,
    ];
  }
  return <String>[
    for (final LocalSourceChapterRecord chapter in decodeLocalSourceChapters(
      book.chaptersJson,
    ))
      chapter.key,
  ];
}
