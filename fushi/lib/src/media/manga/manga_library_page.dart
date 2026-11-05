import 'package:flutter/widgets.dart';

import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/utils.dart';

/// 顶层漫画页：只保留书架。
///
/// 2026-11-05 用户口径：发现 / 在线源 / Local import 全部搬到「浏览」，
/// 漫画页不再有子页签；单视图壳不会画分段条。
class MangaLibraryPage extends StatelessWidget {
  const MangaLibraryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return MediaLibraryShell(
      focusIdPrefix: 'manga-library-view',
      views: <MediaLibraryViewSpec>[
        MediaLibraryViewSpec(
          kind: MediaLibraryViewKind.library,
          label: t.library_view_shelf,
          // 书架主滚动视图自己让出浮动工具栏的高度（内容滚到工具栏底下）。
          handlesChromeInset: true,
          builder: (BuildContext context, Widget navigation) =>
              ReaderFushiHistoryPage(mangaOnly: true, navigation: navigation),
        ),
      ],
    );
  }
}
