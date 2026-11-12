/// [MangaShelfChapterSource] 的章节身份解析（书架快照消费方的唯一入口）。
///
/// 快照行来自 `epub_books`：在线条目把章节列表编码在 `sourceMetadata` 描述符
/// 里，本地图源编码在 `chaptersJson` 里。「这本书当前有哪些章」被未读角标和
/// 「已下载」筛选同时需要，两边各自实现已经分叉过一次（复审 finding 5），
/// 统一收在这个扩展里。
library;

import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_metadata.dart';

extension MangaShelfChapterSourceKeys on MangaShelfChapterSource {
  /// 本地图源（`LocalSourceMetadata` 标记）。
  bool get isLocalSource =>
      LocalSourceMetadata.tryParse(sourceMetadata) != null;

  /// 在线条目描述符；本地图源 / 缺失 / 损坏描述符为 null。
  OnlineMangaLibraryEntry? get onlineEntry =>
      OnlineMangaLibraryEntry.tryParse(sourceMetadata);

  /// 一部漫画当前的章节身份列表（按描述符 / `chaptersJson` 的自然顺序）。
  ///
  /// 在线条目的权威来源是 [sourceMetadata] 描述符；其余（本地图源、或描述符
  /// 损坏但 `chaptersJson` 还在的在线条目）回退到 `chaptersJson`。两种落库形状
  /// 都以 `key` 为章节身份，`decodeLocalSourceChapters` 恰好只依赖这个字段；
  /// 普通 EPUB 章节 JSON 没有 `key`，解出空表 → 未读数 0（角标隐藏）。
  List<String> get chapterKeys {
    final OnlineMangaLibraryEntry? entry = onlineEntry;
    if (entry != null) {
      return <String>[
        for (final OnlineMangaChapter chapter in entry.chapters) chapter.key,
      ];
    }
    return <String>[
      for (final LocalSourceChapterRecord chapter in decodeLocalSourceChapters(
        chaptersJson,
      ))
        chapter.key,
    ];
  }
}
