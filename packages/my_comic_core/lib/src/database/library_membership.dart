import 'database.dart' show EpubBookRow;
import 'epub_book_meta.dart';

/// Library membership（`epub_books.in_library`）的**唯一判据**。
///
/// 一部 Manga 行存在，不等于它在书架：打开在线源作品、移出书架后，行仍然
/// 持久化，以便 Reading progress、Chapter 已读、History、下载与 Download
/// index 继续归属到同一身份。所有「书架专属」读取点（书架页、Home 继续阅读、
/// Tag 页签与计数、订阅 / 自动追更、更新探测、备份「书架中的作品」、书架批量
/// 动作）都必须经过这里判断，不要再用「行是否存在」或 `format='manga'` 代替。
///
/// 反过来说，阅读器、章节状态、History、下载、下载索引与重建索引**不是**
/// 书架专属：它们继续用 `getAllEpubBooks()` / 按 bookKey 直查，读取全部行。
///
/// 数据层查询口径见 `MyComicDatabase.getLibraryEpubBooks` /
/// `MyComicDatabase.watchLibraryEpubBookKeys`。
extension EpubBookRowLibraryMembership on EpubBookRow {
  /// 这一行是否属于 Library（书架）。
  bool get isInLibrary => inLibrary;
}

extension EpubBookMetaLibraryMembership on EpubBookMeta {
  /// 这一行是否属于 Library（书架），见 [EpubBookRowLibraryMembership]。
  bool get isInLibrary => inLibrary;
}
