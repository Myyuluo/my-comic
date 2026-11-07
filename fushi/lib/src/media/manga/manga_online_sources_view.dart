import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/manga/local_source/local_source_browse_page.dart';
import 'package:fushi/src/media/manga/local_source/local_source_entry_row.dart';
import 'package:fushi/src/media/manga/mihon/mihon_extensions_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_installed_sources_section.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeInset;
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show MangaOnlineSourceRow;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';

/// 「浏览」模块里漫画域的在线来源面：扩展仓库 / 扩展目录 / 在线源三节之一
/// （由 [section] 选）。
///
/// 2026-09-27 前这三节是漫画库「导入」视图的后三段；按 Mihon 的 Browse 形态
/// （Sources / Extensions）它们搬进顶层「浏览」。该导入子视图已于 2026-11-08
/// 退役（本地漫画改由图源列表里的「本地图源」承担）。代码随迁移原样保留。
///
/// - [OnlineSourcesSection.stores]：Mihon 扩展仓库；
/// - [OnlineSourcesSection.extensions]：可装扩展目录 + 已装扩展启停 / 卸载 +
///   导入本地 APK；
/// - [OnlineSourcesSection.sources]：扩展提供的源（启停 / 排序 / 偏好 / 清数据 /
///   置顶，[MihonInstalledSourcesSection]）；点已启用的行进该源的浏览页，与
///   小说 / 视频域同一交互。应用不内置任何 Source；没有扩展源时只显示提示。
///
/// 🔴 滚动容器必须是 [CustomScrollView]（BUG-1441）：扩展目录要渲染整个扩展仓库
/// （keiyoushi 有 1900+ 条），只有 sliver 才能懒建。
///
/// 平台差异只在**内容**：没有 Mihon 扩展宿主的平台渲染不可用提示。
/// `AppModel.mihonManager` 在这些平台会抛 [UnsupportedError]，故一切读它的路径
/// 都必须先过 [MihonRuntimeFactory.isSupported]。iOS 上整个「浏览」模块不存在
/// （[StoreRestrictedCapability.onlineMangaSource]），这里再判一次只是纵深防御。
class MangaOnlineSourcesView extends ConsumerStatefulWidget {
  const MangaOnlineSourcesView({required this.section, super.key});

  /// 渲染哪一节。
  final OnlineSourcesSection section;

  @override
  ConsumerState<MangaOnlineSourcesView> createState() =>
      _MangaOnlineSourcesViewState();
}

class _MangaOnlineSourcesViewState
    extends ConsumerState<MangaOnlineSourcesView> {
  MihonManager? _manager;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!MihonRuntimeFactory.isSupported) return;
    final MihonManager manager = ref.read(appProvider).mihonManager;
    if (identical(manager, _manager)) return;
    _manager?.removeListener(_changed);
    _manager = manager..addListener(_changed);
  }

  @override
  void dispose() {
    _manager?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// 点内置「本地图源」行进它的封面网格。进页即扫描 `localcomic`（不复制、
  /// 不移动文件）；扫描结果只展示，用户逐部点开作品页再加入书架。
  void _openLocalSource() {
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => const LocalSourceBrowsePage(),
      ),
    );
  }

  /// 点已启用的漫画源进它的浏览页（热门 / 最新 / 搜索），与小说 / 视频源同一
  /// 交互：来源页签的一行就是进源的入口，不必绕到「发现」。
  void _openMihonSource(MangaOnlineSourceRow source) {
    final MihonManager? manager = _manager;
    if (manager == null) return;
    Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(source),
        ),
      ),
    );
  }

  /// 扩展宿主不可用时统一的占位（iOS）。结构不变，只是这一节没内容。
  Widget _unavailableNote() => Padding(
    padding: const EdgeInsets.all(24),
    child: Text(t.mihon_runtime_unavailable, textAlign: TextAlign.center),
  );

  @override
  Widget build(BuildContext context) {
    final MihonManager? manager = _manager;
    final bool onlineSourcesAvailable =
        StoreRestrictedCapability.onlineMangaSource.isAvailable;
    final OnlineSourcesSection section = widget.section;
    // 内置「本地图源」不依赖扩展宿主：没有扩展也能进 localcomic 的封面网格。
    final Widget localSourceRow = LocalSourceEntryRow(
      onOpen: _openLocalSource,
    );
    final List<Widget> slivers = <Widget>[
      if (section == OnlineSourcesSection.sources)
        if (onlineSourcesAvailable && manager != null)
          MihonInstalledSourcesSection(
            key: const ValueKey<String>('manga_mihon_sources'),
            manager: manager,
            emptyLabel: t.mihon_source_empty,
            onOpenSource: _openMihonSource,
            // 固定排在图源列表第一位（含「已置顶」分组之上）；参与本节的
            // 搜索 / 状态筛选，但没有任何排序 / 清数据 / 卸载菜单。
            builtInRows: <BuiltInSourceListRow>[
              BuiltInSourceListRow(
                child: localSourceRow,
                searchTerms: <String>[t.local_source_title],
                enabled: () => ref.read(appProvider).localSourceEnabled,
              ),
            ],
          )
        else
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                localSourceRow,
                if (onlineSourcesAvailable) ...<Widget>[
                  const SizedBox(height: 12),
                  _unavailableNote(),
                ],
              ],
            ),
          )
      else if (onlineSourcesAvailable && manager != null)
        MihonExtensionsPage(
          key: ValueKey<String>('manga_mihon_extensions_${section.name}'),
          embedded: true,
          sections: <MihonExtensionsSection>[
            if (section == OnlineSourcesSection.stores)
              MihonExtensionsSection.stores
            else
              MihonExtensionsSection.catalog,
          ],
        )
      else if (onlineSourcesAvailable)
        SliverToBoxAdapter(child: _unavailableNote()),
    ];
    final double page = FushiDesignTokens.of(context).spacing.page;
    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          // 库页壳不再给「来源」「扩展」套固定下移：顶部让出浮动工具区的实测
          // 高度（不在库页壳里时为 0）+ M3E 行内间距 8，内容滚到工具区底下，
          // 工具区收起后不留空白。
          padding: EdgeInsets.fromLTRB(
            page,
            FushiFloatingChromeInset.of(context) + 8,
            page,
            page,
          ),
          sliver: SliverMainAxisGroup(slivers: slivers),
        ),
      ],
    );
  }
}
