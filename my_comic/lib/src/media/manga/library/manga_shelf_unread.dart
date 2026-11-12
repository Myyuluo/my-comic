import 'package:my_comic/src/media/manga/library/manga_shelf_chapter_source.dart';
import 'package:my_comic_core/my_comic_core.dart';

/// 漫画书架未读角标的批量计算：输入
/// [`MyComicDatabase.getMangaShelfReadSnapshot`] 的一次性快照，输出
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
/// 章节列表的解析与「已下载」筛选共用 [MangaShelfChapterSourceKeys.chapterKeys]。
Map<String, int> computeMangaShelfUnreadCounts(
  MangaShelfReadSnapshot snapshot,
) {
  final Map<String, int> unreadByBookKey = <String, int>{};
  for (final MangaShelfChapterSource book in snapshot.books) {
    final List<String> chapterKeys = book.chapterKeys;
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
