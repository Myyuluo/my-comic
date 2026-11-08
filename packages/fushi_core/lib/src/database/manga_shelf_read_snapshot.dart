/// 书架漫画未读角标的批量数据快照。
///
/// 未读角标需要「每本漫画当前的章节列表」+「每章是否已读」两路数据。章节身份
/// 住在 `epub_books` 的两个大 TEXT 列里（在线 = `sourceMetadata` 描述符，本地
/// 图源 = `chaptersJson`），已读状态住在 `manga_chapter_states.readAt`。逐卡查库
/// 在几百本漫画的滚动路径上不可接受，故经一次批量查询取回原始数据，由展示层
/// 按书计算未读数（解码章节列表的职责不在数据库层，它不认识运行时描述符形状）。
library;

/// 一本漫画的章节身份来源行。
class MangaShelfChapterSource {
  const MangaShelfChapterSource({
    required this.bookKey,
    required this.bookUid,
    required this.sourceMetadata,
    required this.chaptersJson,
    required this.author,
    required this.extractDir,
  });

  /// 书架身份（`EpubBooks.bookKey`），角标按它归到卡片。
  final String bookKey;

  /// 章状态表的书键（`EpubBooks.uid`，可能为空 = 异常旧行）。
  final String bookUid;

  /// 在线漫画重启描述符（`OnlineMangaLibraryEntry` 编码）；本地图源为
  /// `LocalSourceMetadata`；两者都不是时为 null。
  final String? sourceMetadata;

  /// 章节列表 JSON。本地图源与在线条目都会写；单卷 / PDF 类漫画为 `'[]'`。
  final String chaptersJson;

  /// 作者（在线条目 = 源作者行，作者优先、画师兜底；本地图源可被用户编辑）。
  /// 书架搜索的作者行与「是否已下载」的本地图源判定都读它。
  final String? author;

  /// 作品目录（在线 = Download library 里的漫画目录；本地图源 = 原地目录）。
  final String extractDir;
}

/// [FushiDatabase.getMangaShelfReadSnapshot] 的返回值。
class MangaShelfReadSnapshot {
  const MangaShelfReadSnapshot({
    required this.books,
    required this.readChapterKeysByBookUid,
  });

  /// 全部 `format='manga'` 书行的章节身份来源。
  final List<MangaShelfChapterSource> books;

  /// `bookUid → 已读（readAt 非空）的章节键集合`。未出现在表里的书 = 一章未读。
  final Map<String, Set<String>> readChapterKeysByBookUid;
}
