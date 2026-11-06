import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/models/app_model.dart';

import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「浏览 › 导入」视图：漫画 Local import 的管理处。
///
/// 快速导入与单卷 / 单文件漫画导入；来源库扫描根已随非漫画域移除。
///
/// 页签文案本身已是标题，本页不再渲染页内大标题。扩展仓库 / 扩展目录 / 在线源
/// 住在同一「浏览」模块的「在线源」页签（Mihon 的 Browse 形态），本页不挂在线入口。
class MangaSourcesPage extends ConsumerStatefulWidget {
  const MangaSourcesPage({
    super.key,
    this.navigation,
    this.embedded = false,
  });

  /// 页面导航条；嵌在宿主页签里时为 null。
  final Widget? navigation;

  /// 嵌在宿主页签里时隐藏自身页头（浏览 › 导入）：页签文案已经是标题，
  /// 不重复渲染「来源管理」。
  final bool embedded;

  @override
  ConsumerState<MangaSourcesPage> createState() => _MangaSourcesPageState();
}

class _MangaSourcesPageState extends ConsumerState<MangaSourcesPage> {
  /// 单卷 / 单文件漫画导入：与旧漫画库页头按钮同一个对话框（目录 / `.mokuro` /
  /// `.cbz` / 图片包 + OCR 向导）。落库成功后失效书架 provider 刷新漫画库。
  Future<void> _importManga() async {
    final FushiDatabase db = ref.read(appProvider).database;
    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(db: db),
    );
    if (imported == true && mounted) {
      ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
      ref.invalidate(srtBooksProvider);
    }
  }

  /// 页头：导航条存在时占页头主位；独立使用时回退到文字标题。
  Widget _buildHeader() {
    // 「添加来源」已从页头收敛到「常驻来源」区头（TODO-2930），页头只留导航条。
    const List<Widget> actions = <Widget>[];
    final Widget? navigation = widget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(title: navigation, actions: actions);
    }
    return FushiPageHeader(
      title: t.media_source_manage_title,
      actions: actions,
    );
  }

  /// 「本地」段：快速导入区 + 常驻来源。
  Widget _buildLocalSegment() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 快速导入区：单卷 / 单文件入口（与书 / 视频「导入」视图同构同位；
        // 对话框内含文件 / 文件夹 / OCR 向导）。
        QuickImportSection(
          heroIcon: FushiIcons.manga,
          formats: const <String>['CBZ', 'ZIP', 'MOKURO', 'JPG', 'PNG'],
          actions: <QuickImportAction>[
            QuickImportAction(
              icon: FushiIcons.manga,
              label: t.manga_import_action,
              onTap: _importManga,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return DesktopContentLayout(
      kind: DesktopContentKind.readerShelf,
      child: Column(
        children: <Widget>[
          if (!widget.embedded && !isCupertinoPlatform(context))
            _buildHeader(),
          Expanded(
            // 顶部让出库页壳浮动工具区的高度（不在壳里时为 0）：内容滚到工具区
            // 底下，工具区收起后上方不再留一条空白。
            child: FushiEntranceScope(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  tokens.spacing.page,
                  FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
                  tokens.spacing.page,
                  tokens.spacing.page,
                ),
                children: <Widget>[_buildLocalSegment()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
