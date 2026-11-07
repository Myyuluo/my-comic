import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/import/quick_import_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「浏览 › 导入」视图：漫画 Local import 的入口。
///
/// 2026-11-07 storage-layout：这里的「导入本地漫画」只扫描当前 Content root 的
/// `localcomic` 并原地登记（ADR 0013），**不再**把文件夹 / 压缩包复制进受管
/// `fushi_books`。旧的 `MangaImportDialog` 受管导入保留给拖入的 `.mokuro` / PDF
/// 与其它既有入口，不再是本页的导入路径。来源库扫描根已随非漫画域移除。
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
  /// 手动「导入本地漫画」：扫描 `localcomic`，原地登记，不复制任何文件。
  ///
  /// 这是 spec 故事 26 的入口；旧的受管导入对话框不从这里进入（见类注释）。
  Future<void> _importLocalComics() async {
    final AppModel appModel = ref.read(appProvider);
    try {
      final LocalSourceImportReport report = await LocalSourceLibrary(
        db: appModel.database,
        root: appModel.appPaths.localComicRoot,
      ).importFromRoot();
      if (!mounted) return;
      if (report.added + report.refreshed > 0) {
        ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
        ref.invalidate(srtBooksProvider);
      }
      FushiToast.show(
        msg: t.manga_import_batch_done(
          imported: report.added + report.refreshed,
          skipped: report.skippedTombstoned,
          failed: report.failed,
        ),
        severity: report.failed > 0
            ? ToastSeverity.warning
            : ToastSeverity.success,
      );
    } on Object catch (error) {
      if (!mounted) return;
      FushiToast.show(
        msg: t.data_storage_import_local_comics_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
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
          formats: const <String>['CBZ', 'JPG', 'PNG'],
          actions: <QuickImportAction>[
            QuickImportAction(
              icon: FushiIcons.manga,
              label: t.data_storage_import_local_comics_title,
              onTap: _importLocalComics,
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
