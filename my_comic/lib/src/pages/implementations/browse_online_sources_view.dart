import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_comic/src/media/manga/manga_online_sources_view.dart';

import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/src/models/module_id.dart';
import 'package:my_comic/src/models/store_compliance.dart';
import 'package:my_comic/src/utils/components/my_comic_floating_chrome.dart';
import 'package:my_comic/utils.dart';

/// 「浏览」模块里在线来源的三节（Mihon 的 Browse 形态：Sources / Extensions，
/// 扩展仓库挂在扩展页的工具栏上）。
enum OnlineSourcesSection {
  /// 已装扩展提供的在线源：点进源的浏览页（热门 / 最新 / 搜索）。
  sources,

  /// 可装扩展目录 + 已装扩展的启停 / 卸载 / 更新。
  extensions,

  /// 扩展仓库（添加 / 改地址 / 删除 / 刷新）。
  stores,
}

/// 有在线来源的内容域。my-comic 只保留漫画。
enum OnlineSourcesDomain { manga }

/// [domain] 在当前平台上是否有在线来源宿主。
///
/// 判据只是把各域既有的门拼起来，不另写平台判断：小说 = LNReader 门，视频 =
/// Aniyomi 门，漫画 = 合规门。
///
/// 漫画域**不**再叠 Mihon 宿主门：内置的 mokuro.moe 是个网站、不需要扩展宿主，
/// 它的启停开关就在漫画域的「来源」里——叠了宿主门，Linux（没有 Mihon 宿主）上
/// 整个漫画域消失，mokuro.moe 开关随之没有任何入口。没有宿主时扩展相关的节由
/// [MangaOnlineSourcesView] 自己换成「本平台不可用」的说明。
bool isOnlineSourcesDomainAvailable(OnlineSourcesDomain domain) =>
    switch (domain) {
      OnlineSourcesDomain.manga =>
        StoreRestrictedCapability.onlineMangaSource.isAvailable,
    };

/// 在线域 → 所属功能模块（穷尽 switch）：关掉某个库模块，它的在线来源一并不出。
ModuleId moduleOfOnlineSourcesDomain(OnlineSourcesDomain domain) =>
    switch (domain) {
      OnlineSourcesDomain.manga => ModuleId.manga,
    };

/// 此刻可见的在线域：模块开着、且本平台有该域的在线来源宿主。
///
/// 「浏览」页签与各库页的来源 / 扩展子标签共用这一个判据。
List<OnlineSourcesDomain> visibleOnlineSourcesDomains(
  ModuleVisibility visibility,
) => <OnlineSourcesDomain>[
  for (final OnlineSourcesDomain domain in OnlineSourcesDomain.values)
    if (visibility.isEnabled(moduleOfOnlineSourcesDomain(domain)) &&
        isOnlineSourcesDomainAvailable(domain))
      domain,
];

/// 内容域的显示名（浏览页的域选择条、扩展仓库子页的标题）。
String onlineSourcesDomainLabel(OnlineSourcesDomain domain) => switch (domain) {
  OnlineSourcesDomain.manga => t.manga_library,
};

/// push [domain] 的扩展仓库管理（与扩展目录同一组组件的仓库形态）。
///
/// 「浏览 › 扩展」与各库页「扩展」子标签的「仓库」动作共用这一处。
void openOnlineSourceStores(BuildContext context, OnlineSourcesDomain domain) {
  Navigator.of(context).push(
    adaptivePageRoute<void>(
      context: context,
      builder: (BuildContext context) => BrowseSubPage(
        title:
            '${t.media_import_segment_stores} · '
            '${onlineSourcesDomainLabel(domain)}',
        child: BrowseOnlineSourcesView(
          domain: domain,
          section: OnlineSourcesSection.stores,
        ),
      ),
    ),
  );
}

/// 浏览页 / 库页 push 出来的二级页外壳：带返回键的统一门头 + 正文。
class BrowseSubPage extends StatelessWidget {
  const BrowseSubPage({required this.title, required this.child, super.key});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 统一页面壳：页头浮在正文上（M3E 悬浮胶囊，滚动收起），正文从窗口顶端画
    // 起、内容滚到页头底下。这里的正文（在线来源面 / 扩展仓库）按库页浮动工具区
    // 的约定经 [MyComicFloatingChromeInset] 让位，所以把脚手架下发的顶部让位
    // （状态栏 + 页头实测高度）转成同一个 inset；自己读 MediaQuery 的正文照常
    // 拿得到。返回键由脚手架默认插入。
    return MyComicPageScaffold(
      title: title,
      body: Builder(
        builder: (BuildContext context) => MyComicFloatingChromeInset(
          top: MediaQuery.paddingOf(context).top,
          child: child,
        ),
      ),
    );
  }
}

/// 一个内容域的一节在线来源面。
///
/// 三域的实现 2026-09-27 起统一搬进「浏览」的在线来源页签；书 / 视频的独立导入页
/// 随后随非漫画模块移除，漫画的批量导入子视图也于 2026-11-08 退役——在线来源只
/// 住在顶层的「图源」页签里。漫画域原样委托给 [MangaOnlineSourcesView]。
///
/// 🔴 滚动容器是 [CustomScrollView]：扩展目录是按仓库分组懒建的 sliver
/// （1400+ 条不能一次全建，BUG-1441）。
class BrowseOnlineSourcesView extends ConsumerStatefulWidget {
  const BrowseOnlineSourcesView({
    required this.domain,
    required this.section,
    super.key,
  });

  final OnlineSourcesDomain domain;
  final OnlineSourcesSection section;

  @override
  ConsumerState<BrowseOnlineSourcesView> createState() =>
      _BrowseOnlineSourcesViewState();
}

class _BrowseOnlineSourcesViewState
    extends ConsumerState<BrowseOnlineSourcesView> {
  @override
  Widget build(BuildContext context) {
    return MangaOnlineSourcesView(
      key: ValueKey<String>('manga_online_${widget.section.name}'),
      section: widget.section,
    );
  }

}
