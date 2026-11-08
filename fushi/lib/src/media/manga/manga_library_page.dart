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
      // 只剩书架一个视图，但「漫画」标题和右上角动作仍由壳画。页签位不画只有
      // 「书架」一项的视图页签；标签页签胶囊由书架页登记到标题 / 动作行下方的
      // 二级浮动行（布局跟进 ticket 01）。主 chrome 行的页签位留空，按布局方案
      // 让给顶部行的继续阅读胶囊（ticket 03）。
      alwaysShowChrome: true,
      chromeTabsFromView: true,
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
