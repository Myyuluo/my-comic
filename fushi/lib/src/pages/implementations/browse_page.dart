import 'package:flutter/foundation.dart' show listEquals;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookRepository, AudiobookStorage, SrtBookRepository;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/audiobook/audiobook_transcribe_tasks_section.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_core/fushi_core.dart'
    show VideoDownloadJobFileRow, VideoDownloadJobRow;

import 'package:fushi/src/media/manga/discovery/manga_discovery_page.dart';
import 'package:fushi/src/media/manga/manga_sources_page.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/ai/ai_media_acquisition_assistant.dart'
    show AiMediaAcquisitionDomain;

import 'package:fushi/src/pages/implementations/browse_online_sources_view.dart';

import 'package:fushi/src/pages/implementations/media_discovery_page.dart';

import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeController,
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeOverlay,
        FushiFloatingChromeScope;
import 'package:fushi/src/utils/components/glass/fushi_apple_scroll_chrome.dart'
    show fushiNotificationFromVisibleSubtree;
import 'package:fushi/utils.dart';

/// 「浏览」页签（Mihon 的 Browse 形态）：在线源 / 发现 / 导入。
///
/// 2026-09-27 由「下载」模块改名而来（持久化键 `module_downloads_enabled` 冻结），
/// 同时把散在各库页与导入页的在线入口收拢到这里：
/// - **在线源**：小说（LNReader）/ 漫画（Mihon）/ 视频（Aniyomi）三域已装扩展
///   提供的在线源；「来源 / 扩展」在页签内由二级胶囊切换，扩展仓库挂在「仓库」
///   动作上（Mihon 把 repo 放在 Extensions 的工具栏）；
/// - **发现**：书 / 漫画 / 游戏 / 视频四域的生产发现页（原「资源」页签）；
/// - **导入**：漫画的 Local import（快速导入、常驻扫描根、互联对端），2026-11-05
///   从漫画页搬来。
///
/// 下载任务列表 2026-11-07 迁出为一级「下载」页（`HomeTab.downloads`），这里不再
/// 有「下载」视图页签。
///
/// 每个页签内先选内容域，再直接复用各域自己的生产组件，不另写第二套 UI。
class BrowsePage extends ConsumerStatefulWidget {
  const BrowsePage({super.key});

  @override
  ConsumerState<BrowsePage> createState() => _BrowsePageState();
}

/// 「浏览」的页签。**用枚举而不是下标**：页签随平台 / 模块开关增减，按位置
/// 记账会在页签少一个时静默落错页。
enum BrowseTab { sources, discover, localImport, extensions }

/// 顶层页签接力（二级标签越界横滑）时，目标页签的二级标签要不要按衔接方向
/// 重新落端（往后落首段、往前落末段）。
///
/// 来源 ↔ 扩展之间**不**落端：两者共用同一份内容域选择（来回切不丢选择），
/// 改它就等于在拖动途中改被拖那一页的二级下标，标签条与页面错位（PR #1735）。
/// 其余页签各持自己的二级状态，照常落端。
bool browseHandOffRealignsSections(BrowseTab from, BrowseTab to) {
  bool isOnline(BrowseTab tab) =>
      tab == BrowseTab.sources || tab == BrowseTab.extensions;
  return !(isOnline(from) && isOnline(to));
}

/// 测试入口：直接挂一份浏览页的「二级标签 + 横滑页面」（真页面要起 Mihon /
/// LNReader manager，widget 测试挂不起来）。
@visibleForTesting
Widget debugBrowseSwipeSections<T extends Object>({
  required List<LibrarySectionTab<T>> tabs,
  required T selected,
  required Widget Function(T value) pageBuilder,
  Widget? trailing,
}) => _BrowseSwipeSections<T>(
  pickerKey: const ValueKey<String>('debug-browse-swipe-sections'),
  tabs: tabs,
  selected: selected,
  onChanged: (T _) {},
  focusIdPrefix: 'debug-browse-swipe-sections',
  pageBuilder: pageBuilder,
  onEdgeOverscroll: (int _) {},
  trailing: trailing,
);

class _BrowsePageState extends ConsumerState<BrowsePage>
    with TickerProviderStateMixin {
  /// 页签控制器由本页持有（不用 DefaultTabController）：页签随平台 / 模块开关增减
  /// 时要**按页签 id** 落回原来选中的页签——DefaultTabController 只保留下标，前面
  /// 少一个页签就静默落到相邻页签上。
  TabController? _tabController;

  /// [_tabController] 对应的页签序列。
  List<BrowseTab> _controllerTabs = const <BrowseTab>[];

  /// 当前选中的页签（按 id 记）；null = 尚未选中，落在第一个可见页签。
  BrowseTab? _selectedTab;

  /// 来源 / 扩展共用的内容域选择（在两者之间来回切不丢选择）。
  OnlineSourcesDomain _onlineDomain = OnlineSourcesDomain.novel;

  /// 「在线源」页签里此刻显示来源还是扩展（2026-10-14 用户：库页顶栏把来源 /
  /// 扩展并成「在线源」后，「浏览模块也可以做」）。两者共用一个顶层页签
  /// （[BrowseTab.sources] 这一槽），由二级行右侧的分段切换。
  OnlineSourcesSection _onlineSection = OnlineSourcesSection.sources;

  /// 访问过的在线源分区（惰性构建 + 保活，来回切不丢搜索词与滚动位置）。
  late final Set<OnlineSourcesSection> _onlineVisited = <OnlineSourcesSection>{
    _onlineSection,
  };

  _DownloadsResourceDomain _resourceDomain = _DownloadsResourceDomain.books;

  /// 页头动作（扩展的「仓库」等）登记的槽：由页签行右侧的悬浮按钮组胶囊画出
  /// （与库页壳 [MediaLibraryShell] 同构）。
  final FushiShellActionsSlot _actionsSlot = FushiShellActionsSlot();

  /// 头部（一级页签行 + 各页签的二级页签行）随滚动收放的状态：与四个库页
  /// 同一套规则（下滚收起、上滚弹回、只认主滚动区、平滑滚轮拉回不算）。头部
  /// 叠在正文上，收放不改正文视口（BUG-2975）。
  final FushiFloatingChromeController _chrome = FushiFloatingChromeController();

  bool _onScroll(ScrollNotification notification) {
    // 保活的离屏页签 / 内容域（TickerMode 关着）发来的通知不算；横向翻页在
    // controller 内按轴过滤。
    if (!fushiNotificationFromVisibleSubtree(notification)) return false;
    return _chrome.handleScrollNotification(notification);
  }

  @override
  void initState() {
    super.initState();
    // 初始域 = 第一个可见域，不再硬编码 books：books 模块关掉时旧实现会停在一个
    // 已被过滤掉的域上（分段条选中值不在选项里 → 分段控件直接 assert，发现页也
    // 会挂在一个用户已关掉的模块上）。四个域全关时保持字段原值，此时
    // [_buildResourceHub] 整块不渲染，字段不参与任何渲染判据。
    final AppModel initialAppModel = ref.read(appProvider);
    final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
      initialAppModel.moduleVisibility,
    );
    if (domains.isNotEmpty) _resourceDomain = domains.first;
    final List<OnlineSourcesDomain> onlineDomains = visibleOnlineSourcesDomains(
      initialAppModel.moduleVisibility,
    );
    if (onlineDomains.isNotEmpty) _onlineDomain = onlineDomains.first;
  }

  @override
  void dispose() {
    _actionsSlot.release(this);
    _actionsSlot.dispose();
    _tabController?.dispose();
    _chrome.dispose();
    super.dispose();
  }

  /// 按此刻可见的页签对齐 [_tabController]：页签序列没变就沿用；变了（模块 /
  /// 平台门增减页签）就按 [_selectedTab] 的 id 重新定位，已不可见时落第一个页签。
  TabController _syncTabController(List<BrowseTab> tabs) {
    final TabController? current = _tabController;
    if (current != null && listEquals(tabs, _controllerTabs)) return current;
    final BrowseTab? wanted = _selectedTab;
    final int found = wanted == null ? -1 : tabs.indexOf(wanted);
    final int index = found < 0 ? 0 : found;
    final TabController next = TabController(
      length: tabs.length,
      initialIndex: index,
      // eink：TabBarView 的 300ms 横滑 = 整页一串局部刷新的残影，归零。
      animationDuration: einkSafeDuration(context, kTabScrollDuration),
      vsync: this,
    );
    next.addListener(() {
      if (identical(next, _tabController)) {
        final BrowseTab tab = _controllerTabs[next.index];
        // 换了页签：新页面从顶部开始，头部回来、遮罩撤掉。
        if (tab != _selectedTab) _chrome.resetToTop();
        _selectedTab = tab;
      }
    });
    _tabController = next;
    _controllerTabs = List<BrowseTab>.unmodifiable(tabs);
    _selectedTab = tabs[index];
    // 旧控制器还挂在本帧之前的 TabBar / TabBarView 上：等这一帧换绑完再释放。
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  /// 此刻可见的页签，顺序即页头顺序：在线源 → 发现 → 导入。
  ///
  /// 在线源页签只在至少一个域有在线来源时出现；发现页签跟四个库模块走；
  /// 导入跟随浏览模块恒在。
  List<BrowseTab> _visibleTabs(AppModel appModel) {
    final bool online = visibleOnlineSourcesDomains(
      appModel.moduleVisibility,
    ).isNotEmpty;
    // 发现页签自己再问一次合规门，不只靠整个模块委托的 downloads 能力：两种能力
    // 今天都只在 iOS 缺席，但它们是两条独立的审核理由，日后范围分开时发现页签
    // 不能静默漏门。
    final bool discover =
        StoreRestrictedCapability.externalDiscovery.isAvailable &&
        _visibleResourceDomains(appModel.moduleVisibility).isNotEmpty;
    // 用户口径：浏览页签顺序 在线源 → 发现 → 导入；默认落地沿用「第一个可见
    // 页签」，因此打开浏览落在在线源。
    return <BrowseTab>[
      // 来源 / 扩展并成一个「在线源」页签（见 [_onlineSection]）。
      if (online) BrowseTab.sources,
      if (discover) BrowseTab.discover,
      // 导入跟着浏览页走，不额外看漫画模块开关。
      BrowseTab.localImport,
    ];
  }

  String _tabLabel(BrowseTab tab) => switch (tab) {
    BrowseTab.sources => t.media_import_segment_sources,
    BrowseTab.extensions => t.media_import_segment_extensions,
    BrowseTab.discover => t.library_view_discover,
    BrowseTab.localImport => t.library_view_import,
  };

  void _selectOnlineDomain(OnlineSourcesDomain domain) {
    if (domain == _onlineDomain) return;
    _chrome.resetToTop();
    setState(() => _onlineDomain = domain);
  }

  void _selectOnlineSection(OnlineSourcesSection section) {
    if (section == _onlineSection) return;
    _chrome.resetToTop();
    setState(() {
      _onlineSection = section;
      _onlineVisited.add(section);
    });
  }

  /// 在线源此刻选中的内容域（当前域已被模块开关关掉时回落第一个可见域）；
  /// 没有可见域时为 null。
  OnlineSourcesDomain? _selectedOnlineDomain() {
    final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
      ref.read(appProvider).moduleVisibility,
    );
    if (domains.isEmpty) return null;
    return domains.contains(_onlineDomain) ? _onlineDomain : domains.first;
  }

  /// 「在线源」页签：内容域选择条 + 来源 / 扩展切换 + 各域可横滑、保活的
  /// 在线来源面。
  Widget _buildOnlineTab() {
    final AppModel appModel = ref.watch(appProvider);
    final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
      appModel.moduleVisibility,
    );
    if (domains.isEmpty) return const SizedBox.shrink();
    final OnlineSourcesDomain selected = domains.contains(_onlineDomain)
        ? _onlineDomain
        : domains.first;
    const BrowseTab tab = BrowseTab.sources;
    return _BrowseSwipeSections<OnlineSourcesDomain>(
      pickerKey: ValueKey<String>('browse-${tab.name}-domain-picker'),
      tabs: <LibrarySectionTab<OnlineSourcesDomain>>[
        for (final OnlineSourcesDomain domain in domains)
          LibrarySectionTab<OnlineSourcesDomain>(
            value: domain,
            label: onlineSourcesDomainLabel(domain),
          ),
      ],
      selected: selected,
      onChanged: _selectOnlineDomain,
      focusIdPrefix: 'browse-${tab.name}-domain',
      onEdgeOverscroll: (int delta) => _handOffFrom(tab, delta),
      // 来源 / 扩展与左边的内容域同一种二级胶囊页签（浏览页二级选择一律是
      // 页签，不用分段按钮）。
      trailing: LibrarySectionTabs<OnlineSourcesSection>(
        key: const ValueKey<String>('browse-online-section-picker'),
        tabs: <LibrarySectionTab<OnlineSourcesSection>>[
          LibrarySectionTab<OnlineSourcesSection>(
            value: OnlineSourcesSection.sources,
            label: t.library_view_sources,
          ),
          LibrarySectionTab<OnlineSourcesSection>(
            value: OnlineSourcesSection.extensions,
            label: t.media_import_segment_extensions,
          ),
        ],
        selected: _onlineSection,
        onChanged: _selectOnlineSection,
        focusIdPrefix: 'browse-online-section',
        secondary: true,
        floating: true,
      ),
      // 在线来源面的主滚动视图自己把头部高度加成顶部 sliver（内容滚到头部底下）。
      pageHandlesInset: true,
      pageBuilder: (OnlineSourcesDomain domain) => Stack(
        children: <Widget>[
          for (final OnlineSourcesSection section
              in OnlineSourcesSection.values)
            if (_onlineVisited.contains(section))
              Offstage(
                offstage: section != _onlineSection,
                child: TickerMode(
                  enabled: section == _onlineSection,
                  child: SectionVisibilityScope(
                    visible: section == _onlineSection,
                    // 来源 / 扩展同时保活：各给一份主滚动控制器，共用外层
                    // 那一个会让两个主滚动视图附着同一控制器、Scrollbar 断言。
                    child: SectionPrimaryScrollScope(
                      child: BrowseOnlineSourcesView(
                        key: ValueKey<String>(
                          'browse-${section.name}-${domain.name}',
                        ),
                        domain: domain,
                        section: section,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }

  /// 二级标签横滑越过首 / 尾段时，把手势交给相邻的顶层页签：从 [from] 往 [delta]
  /// 方向（+1 下一个 / -1 上一个）切过去，并让目标页签的二级标签落在衔接的那一端
  /// （往后落首段、往前落末段）——三个页签的二级标签连成一条可一路滑过去的带子。
  void _handOffFrom(BrowseTab from, int delta) {
    final TabController? controller = _tabController;
    if (controller == null || controller.indexIsChanging) return;
    final int index = _controllerTabs.indexOf(from);
    final int target = index + delta;
    if (index < 0 || index != controller.index) return;
    if (target < 0 || target >= _controllerTabs.length) {
      // 越过首 / 末顶层页签：再往外交给首页外壳切功能模块（手机布局）。
      SectionSwipeOverflowScope.maybeOf(context)?.call(forward: delta > 0);
      return;
    }
    // 来源 / 扩展共用同一份内容域：两者之间接力只切顶层页签、落在同一个域上。
    // 若按「往后首段 / 往前末段」去改共享域，被拖的那一页的二级控制器会在拖动
    // 途中被改下标（TabBarView 拖动中不跟随跳页），标签条与页面就此错位。
    if (!browseHandOffRealignsSections(from, _controllerTabs[target])) {
      controller.animateTo(target);
      return;
    }
    final bool toFirst = delta > 0;
    final AppModel appModel = ref.read(appProvider);
    setState(() {
      switch (_controllerTabs[target]) {
        case BrowseTab.sources || BrowseTab.extensions:
          final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
            appModel.moduleVisibility,
          );
          if (domains.isNotEmpty) {
            _onlineDomain = toFirst ? domains.first : domains.last;
          }
        case BrowseTab.discover:
          final List<_DownloadsResourceDomain> domains =
              _visibleResourceDomains(appModel.moduleVisibility);
          if (domains.isNotEmpty) {
            _resourceDomain = toFirst ? domains.first : domains.last;
          }
        case BrowseTab.localImport:
          // 导入页没有二级分区，无须落端。
          break;
      }
    });
    controller.animateTo(target);
  }

  /// 「补对齐文件」：把已下完的孤立音频直接喂进统一导入对话框。
  ///
  /// 本仓有声书是字幕对齐驱动的，`download-only-audiobook` 任务落地的只有音频
  /// （CoreAudio/TMW 单卷 m4b），自动导入链路进不去。这里把该任务真实落盘的音频
  /// 预填进 [BookImportDialog]，用户只需再给一个字幕就能成书。
  ///
  /// 取不到音频路径（文件被手动删掉/移走）时照常开框、只是不预填——把死路留成
  /// 用户仍可自选文件的活路，好过弹一句错误后什么也做不了。
  ///
  /// 素材库里配得到字幕/正文时一并预填：身份键取任务记的 [externalId]（发现页
  /// 下载时写的作品主键），没有就退到音频文件名里的键。
  ///
  /// 注：my-comic 移除非漫画域后这条入口没有生产者（富任务浏览器未接线），但
  /// 按 spec「不清理与下载视图迁移无关的其它未接线下载代码」原样保留。
  // ignore: unused_element
  Future<void> _pairDownloadedAudiobook(VideoDownloadJobRow job) async {
    final AppModel appModel = ref.read(appProvider);
    final List<VideoDownloadJobFileRow> rows = await appModel.database
        .getVideoDownloadJobFiles(job.jobId);
    final List<String> audioPaths = <String>[
      for (final VideoDownloadJobFileRow row in rows)
        if (row.selected &&
            (row.finalAbsolutePath?.trim().isNotEmpty ?? false) &&
            AudiobookStorage.audioExtensions.contains(
              p.extension(row.finalAbsolutePath!).toLowerCase(),
            ))
          row.finalAbsolutePath!,
    ]..sort();
    final AudiobookMaterialMatch match = await _matchAudiobookMaterials(
      appModel,
      job: job,
      audioPaths: audioPaths,
    );
    if (!mounted) return;
    await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        prefs: appModel.prefsRepo,
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
        initialAudioPaths: audioPaths.isEmpty ? null : audioPaths,
        initialSubtitlePath: match.subtitlePath,
        initialEpubPath: match.contentPath,
      ),
    );
  }

  /// 从素材库给这条任务配字幕/正文；没配素材库或配不到时返回空匹配。
  Future<AudiobookMaterialMatch> _matchAudiobookMaterials(
    AppModel appModel, {
    required VideoDownloadJobRow job,
    required List<String> audioPaths,
  }) async {
    final AudiobookMaterialScan scan = await appModel.audiobookMaterialService
        .scan();
    if (scan.index.isEmpty) return const AudiobookMaterialMatch();
    final String? externalId = job.externalId?.trim();
    final String? key = (externalId != null && externalId.isNotEmpty)
        ? externalId
        : audioPaths
              .map(audiobookKeyFromAudioPath)
              .firstWhere((String? k) => k != null, orElse: () => null);
    return matchAudiobookMaterial(scan.index, key: key, title: job.title);
  }

  String _resourceDomainLabel(_DownloadsResourceDomain domain) =>
      switch (domain) {
        _DownloadsResourceDomain.books => t.books,
        _DownloadsResourceDomain.manga => t.manga_library,
      };

  void _selectResourceDomain(_DownloadsResourceDomain domain) {
    if (domain == _resourceDomain) return;
    _chrome.resetToTop();
    setState(() => _resourceDomain = domain);
  }

  /// 漫画发现（「发现」页签里）的「管理来源」去处：回到本页并切到「来源 › 漫画」。
  /// 漫画域此刻不可见时为 null（空态只给文案、不给点了没反应的按钮）。
  ///
  /// 以本页自己的路由为界弹掉上面压着的路由（全源搜索页、详情页），与压了几层
  /// 无关——与库页壳 `MediaLibraryShell` 的「回到壳」同一口径。
  VoidCallback? _mangaSourcesAction() {
    final List<OnlineSourcesDomain> domains = visibleOnlineSourcesDomains(
      ref.read(appProvider).moduleVisibility,
    );
    if (!domains.contains(OnlineSourcesDomain.manga)) return null;
    return () {
      final ModalRoute<Object?>? route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        Navigator.of(
          context,
        ).popUntil((Route<dynamic> above) => above == route);
      }
      final int index = _controllerTabs.indexOf(BrowseTab.sources);
      if (index < 0) return;
      setState(() => _onlineDomain = OnlineSourcesDomain.manga);
      _tabController?.animateTo(index);
    };
  }

  Widget _buildResourceDomain(_DownloadsResourceDomain domain) =>
      switch (domain) {
        _DownloadsResourceDomain.books => MediaDiscoveryPage(
          kinds: const <DiscoveryMediaKind>[
            DiscoveryMediaKind.novel,
            DiscoveryMediaKind.audiobook,
          ],
        ),
        _DownloadsResourceDomain.manga => MangaDiscoveryPage(
          embedded: true,
          onOpenSources: _mangaSourcesAction(),
        ),
      };

  /// 二级标签页只负责选择内容域；域内筛选、搜索与结果展示全部沿用各模块
  /// 自己的生产发现页。四个固定目的地直接可见，避免无标签的表单型下拉框
  /// 单独悬在搜索区上方。域页可横滑切换，首次访问后保持挂载，来回切换不丢
  /// 搜索词、结果和滚动位置。
  Widget _buildResourceHub() {
    // 模块门控：四个域分属 books / manga / games / video，关掉的模块不出段，
    // 它的发现页也一并不建（隐藏域不该继续挂在树上跑网络）。
    final AppModel appModel = ref.watch(appProvider);
    final List<_DownloadsResourceDomain> domains = _visibleResourceDomains(
      appModel.moduleVisibility,
    );
    // 四个域全关：整块资源分区不渲染——空的标签条 + 空页面是「渲染出来但点不
    // 出任何东西」，正是要消灭的形态。
    if (domains.isEmpty) return const SizedBox.shrink();
    // 当前域在渲染期回落到第一个可见域：用户在设置里关掉当前域后本页可能仍挂着
    // （保活 tab），选中值不在标签里时标签条会落到错误的下标上。
    final _DownloadsResourceDomain selected = domains.contains(_resourceDomain)
        ? _resourceDomain
        : domains.first;
    return _BrowseSwipeSections<_DownloadsResourceDomain>(
      pickerKey: const ValueKey<String>('downloads-resource-type-picker'),
      tabs: <LibrarySectionTab<_DownloadsResourceDomain>>[
        for (final _DownloadsResourceDomain domain in domains)
          LibrarySectionTab<_DownloadsResourceDomain>(
            value: domain,
            label: _resourceDomainLabel(domain),
          ),
      ],
      selected: selected,
      onChanged: _selectResourceDomain,
      focusIdPrefix: 'browse-discover-domain',
      onEdgeOverscroll: (int delta) => _handOffFrom(BrowseTab.discover, delta),
      // 各域发现页把自己的搜索 / 筛选行叠进浮动工具区、主滚动视图自己让位
      // （内容在胶囊背后可见，不再被整块控件区底色盖住）。
      pageHandlesInset: true,
      pageBuilder: (_DownloadsResourceDomain domain) => KeyedSubtree(
        key: ValueKey<String>('downloads-resource-${domain.name}'),
        child: _buildResourceDomain(domain),
      ),
    );
  }

  Widget _buildHeader(TabController controller, List<BrowseTab> tabs) {
    // 下拉框会临时 push PopupRoute；只看本页自己的 PageRoute，避免展开菜单时
    // 左上角凭空出现返回键。
    final bool showBackButton = ModalRoute.of(context)?.isFirst == false;
    // 不在首页外壳里（没有外壳大标题）时，工具栏行顶上留一点呼吸位。
    final bool shellTitle = FushiShellTitleScope.maybeTitleOf(context) != null;
    final double page = FushiDesignTokens.of(context).spacing.page;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final BrowseTab current =
            tabs[controller.index.clamp(0, tabs.length - 1)];
        final OnlineSourcesDomain? storesDomain =
            current == BrowseTab.sources &&
                _onlineSection == OnlineSourcesSection.extensions
            ? _selectedOnlineDomain()
            : null;
        final List<Widget> actions = <Widget>[
          // 扩展的「仓库」是整页动作，与下载页签的动作同处顶栏右侧动作组
          // （2026-10-14 用户截图：夹在内容域胶囊与来源 / 扩展切换之间不自然）。
          if (storesDomain != null)
            FushiIconButton(
              key: const ValueKey<String>('browse-extensions-stores'),
              icon: Icons.hub_outlined,
              tooltip: t.media_import_segment_stores,
              label: t.media_import_segment_stores,
              onTap: () => openOnlineSourceStores(context, storesDomain),
            ),
        ];
        if (actions.isEmpty) {
          _actionsSlot.release(this);
        } else {
          _actionsSlot.claimActions(
            this,
            visible: true,
            actions: FushiShellHeaderActions(actions: actions),
          );
        }
        return FushiFloatingChromeBar(
          slot: _actionsSlot,
          padding: shellTitle
              ? null
              : EdgeInsets.fromLTRB(page, page / 2, page, 4),
          leading: !showBackButton
              ? null
              : isGlassDesign(context)
              ? FushiRouteBackButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : fushiFloatingLeading(
                  FushiIconButton(
                    icon: Icons.arrow_back,
                    tooltip: t.back,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
          tabs: child!,
        );
      },
      child: LibrarySectionTabs<BrowseTab>.controlled(
        tabs: <LibrarySectionTab<BrowseTab>>[
          for (final BrowseTab tab in tabs)
            LibrarySectionTab<BrowseTab>(value: tab, label: _tabLabel(tab)),
        ],
        controller: controller,
        focusIdPrefix: 'browse-tab',
        floating: true,
      ),
    );
  }

  /// 「导入」页签：复用漫画的 Local import 页（快速导入 + 常驻来源 + 互联对端）。
  Widget _buildLocalImportTab() => const MangaSourcesPage(embedded: true);

  Widget build(BuildContext context) {
    final List<BrowseTab> tabs = _visibleTabs(ref.watch(appProvider));
    // 初始页签：尚未选中时落在第一个可见页签（见 [_syncTabController]）。
    final TabController controller = _syncTabController(tabs);
    // 作为 home tab 时外层已有 SafeArea，这里的 SafeArea 兜的是独立 push
    // 进来（设置入口）时的状态栏避让，双层无副作用。
    return Scaffold(
      body: SafeArea(
        bottom: false,
        // 头部（一级页签行）叠在正文上、随滚动收放（与库页同一套，见
        // [FushiFloatingChromeOverlay]）；各页签的二级页签行在 [_BrowseSwipeSections]
        // 里同样叠放，排在这一行下面、一起收。
        child: FushiFloatingChromeScope(
          controller: _chrome,
          child: FushiFloatingChromeOverlay(
            chrome: isCupertinoPlatform(context)
                ? const SizedBox.shrink()
                : _buildHeader(controller, tabs),
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              // 只在选中页签变化时重建（controller 的 notifyListeners 只在下标
              // 变化时触发），用来给隐藏页签关焦点。
              child: AnimatedBuilder(
                animation: controller,
                builder: (BuildContext context, Widget? _) => TabBarView(
                  // 页签序列一变就整个换新：旧 TabBarView 的 PageController 停在
                  // 旧下标上，换绑新控制器的那一帧会先把旧下标处（多半是新插进来
                  // 的「来源」）建出来再跳走——白建一个页签还被保活。
                  key: ValueKey<String>(
                    tabs.map((BrowseTab tab) => tab.name).join(','),
                  ),
                  controller: controller,
                  children: <Widget>[
                    for (final BrowseTab tab in tabs)
                      _BrowseTabKeepAlive(
                        key: ValueKey<BrowseTab>(tab),
                        active: tabs[controller.index] == tab,
                        child: switch (tab) {
                          BrowseTab.sources ||
                          BrowseTab.extensions => _buildOnlineTab(),
                          BrowseTab.discover => _buildResourceHub(),
                          BrowseTab.localImport => _buildLocalImportTab(),
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 页面内一排二级标签 + 可横滑的对应页面（MD3 secondary tabs + [TabBarView]），
/// 「浏览」各页签共用：来源 / 扩展的内容域、发现的内容域。
///
/// * 标签条是贴合内容宽的紧凑分段胶囊（`floating` + `secondary`），摆不下时
///   在胶囊里横滑。
/// * 页面可左右横滑（移动端触屏；桌面鼠标不拖页，走标签 / 方向键），首次滑到 /
///   点到的页面保活，来回切不丢搜索词、结果与滚动位置。
/// * 横滑越过首 / 尾段时经 [onEdgeOverscroll] 把手势交给宿主切顶层页签：内层
///   [TabBarView] 在手势竞技场里恒先于外层胜出，不接力的话滑到末段就再也滑不到
///   下一个顶层页签。
///
/// 选中值的真相在宿主（[selected] / [onChanged]），本组件的 [TabController] 是它的
/// 投影：宿主改值（顶层接力落端）时就地跟过去。
class _BrowseSwipeSections<T extends Object> extends StatefulWidget {
  const _BrowseSwipeSections({
    required this.pickerKey,
    required this.tabs,
    required this.selected,
    required this.onChanged,
    required this.focusIdPrefix,
    required this.pageBuilder,
    required this.onEdgeOverscroll,
    this.trailing,
    this.pageHandlesInset = false,
    super.key,
  });

  /// true：[pageBuilder] 的页面自己消费 [FushiFloatingChromeInset]（主滚动视图
  /// 加顶部 sliver）；false：页面整体下移头部高度（[FushiFloatingChromeInsetPadding]）。
  final bool pageHandlesInset;

  /// 标签条的稳定 key（焦点导航与行为验证用）。
  final Key pickerKey;
  final List<LibrarySectionTab<T>> tabs;
  final T selected;
  final ValueChanged<T> onChanged;
  final String focusIdPrefix;
  final Widget Function(T value) pageBuilder;

  /// 越过首段（-1）/ 末段（+1）继续横滑时回调（每次拖动手势至多一次）。
  final ValueChanged<int> onEdgeOverscroll;

  /// 标签条右侧的动作（如扩展页签的「仓库」）。
  final Widget? trailing;

  @override
  State<_BrowseSwipeSections<T>> createState() =>
      _BrowseSwipeSectionsState<T>();
}

/// 越界横滑累计到这个距离（逻辑像素）才接力给顶层页签：边缘的轻微误拖不该把
/// 整页切走。
const double _kSectionEdgeHandOffDistance = 48.0;

class _BrowseSwipeSectionsState<T extends Object>
    extends State<_BrowseSwipeSections<T>>
    with TickerProviderStateMixin {
  TabController? _controller;

  /// [_controller] 对应的段值序列。
  List<T> _controllerValues = <T>[];

  double _edgeOverscroll = 0;
  bool _handedOff = false;

  int get _selectedIndex {
    final int index = widget.tabs.indexWhere(
      (LibrarySectionTab<T> tab) => tab.value == widget.selected,
    );
    return index < 0 ? 0 : index;
  }

  /// 段序列变了（模块开关增减内容域）才换控制器；否则沿用，并把下标对齐到宿主
  /// 的 [_BrowseSwipeSections.selected]。
  TabController _syncController() {
    final List<T> values = <T>[
      for (final LibrarySectionTab<T> tab in widget.tabs) tab.value,
    ];
    final TabController? current = _controller;
    if (current != null && listEquals(values, _controllerValues)) {
      final int index = _selectedIndex;
      if (!current.indexIsChanging && current.index != index) {
        // 宿主改了选中值（顶层接力落端）：此刻多半不在屏上，直接跳。
        current.index = index;
      }
      return current;
    }
    final TabController next = TabController(
      length: values.length,
      initialIndex: _selectedIndex,
      // eink：横滑动画 = 一串局部刷新的残影，归零。
      animationDuration: einkSafeDuration(context, kTabScrollDuration),
      vsync: this,
    );
    next.addListener(() {
      if (!identical(next, _controller)) return;
      final T value = _controllerValues[next.index];
      if (value != widget.selected) widget.onChanged(value);
    });
    _controller = next;
    _controllerValues = List<T>.unmodifiable(values);
    // 旧控制器还挂在本帧之前的标签条 / TabBarView 上：等这一帧换绑完再释放。
    if (current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  bool _handleScroll(ScrollNotification notification) {
    // 只看本层 TabBarView 的横向翻页；页面里的列表 / 横排封面自己的滚动不算。
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.horizontal) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _edgeOverscroll = 0;
      _handedOff = false;
    } else if (notification is OverscrollNotification &&
        notification.dragDetails != null &&
        !_handedOff) {
      // 只接力手指拖动的越界；惯性滑到头的越界不算（那不是「还要往下一个滑」）。
      _edgeOverscroll += notification.overscroll;
      if (_edgeOverscroll.abs() >= _kSectionEdgeHandOffDistance) {
        _handedOff = true;
        widget.onEdgeOverscroll(_edgeOverscroll > 0 ? 1 : -1);
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TabController controller = _syncController();
    // 只剩一个段（其余内容域被模块开关 / 平台门关掉）：一排只有一个标签的二级
    // 页签既不能切换、又占一整行纵向空间，还会被误读成标题。此时不画标签条，
    // 只在有尾随动作时留下那一行放动作。
    final bool showTabs = widget.tabs.length > 1;
    // 二级页签行叠在页面上、与一级页签行同一份显隐（[FushiFloatingChromeOverlay]
    // 读同一个作用域），收放不改页面视口。
    return FushiFloatingChromeOverlay(
      chrome: !(showTabs || widget.trailing != null)
          ? const SizedBox.shrink()
          : Padding(
              // 与上面的一级页签浮动胶囊、页面内容同一条页边（左缘对齐）；
              // 顶上 8 + 浮动工具栏底边 4 = 两级页签之间 12。
              padding: EdgeInsets.fromLTRB(
                tokens.spacing.page,
                tokens.spacing.gap,
                tokens.spacing.page,
                tokens.spacing.gap,
              ),
              child: Row(
                children: <Widget>[
                  if (showTabs)
                    Expanded(
                      // 二级内容域：贴合内容宽的紧凑扁平分段胶囊（比一级悬浮
                      // 页签胶囊矮一档、不浮），摆不下在胶囊里横滑。
                      child: LibrarySectionTabs<T>.controlled(
                        key: widget.pickerKey,
                        tabs: widget.tabs,
                        controller: controller,
                        focusIdPrefix: widget.focusIdPrefix,
                        secondary: true,
                        floating: true,
                      ),
                    )
                  else
                    const Spacer(),
                  if (widget.trailing != null) widget.trailing!,
                ],
              ),
            ),
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScroll,
        // 只在选中段变化时重建，用来给离屏段关焦点与 ticker。
        child: AnimatedBuilder(
          animation: controller,
          builder: (BuildContext context, Widget? _) => TabBarView(
            // 段序列一变就整个换新（同顶层页签的理由）。
            key: ValueKey<String>(_controllerValues.join(',')),
            controller: controller,
            children: <Widget>[
              for (final T value in _controllerValues)
                _BrowseTabKeepAlive(
                  key: ValueKey<T>(value),
                  active: _controllerValues[controller.index] == value,
                  child: widget.pageHandlesInset
                      ? widget.pageBuilder(value)
                      : FushiFloatingChromeInsetPadding(
                          child: widget.pageBuilder(value),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [TabBarView] 的页签外壳：横滑离开的页签**保活**（TabBarView 默认把离屏页签
/// dispose 掉，回来时发现页重拉网络、在线来源丢搜索与滚动）；未选中的页签排除出
/// 焦点遍历——保活的离屏页签仍在树上，不排除的话 Tab / 方向键会走进看不见的页签；
/// 也关掉它的 ticker（离屏页的转圈 / 动画不该继续跑）。
class _BrowseTabKeepAlive extends StatefulWidget {
  const _BrowseTabKeepAlive({
    required this.active,
    required this.child,
    super.key,
  });

  final bool active;
  final Widget child;

  @override
  State<_BrowseTabKeepAlive> createState() => _BrowseTabKeepAliveState();
}

class _BrowseTabKeepAliveState extends State<_BrowseTabKeepAlive>
    with AutomaticKeepAliveClientMixin<_BrowseTabKeepAlive> {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 保活页签同时挂在树上：各给一份主滚动控制器，否则多个页签的主滚动视图
    // 附着同一个外壳控制器、Scrollbar 断言。
    return TickerMode(
      enabled: widget.active,
      child: ExcludeFocus(
        excluding: !widget.active,
        child: SectionPrimaryScrollScope(child: widget.child),
      ),
    );
  }
}

enum _DownloadsResourceDomain { books, manga }

/// 资源域 → 所属功能模块（穷尽 switch：加域时编译器强制补齐这张表）。
///
/// 四个域各自复用对应库的生产发现页，所以门控判据就是那个库的模块开关——关掉
/// 视频模块还留着「视频」资源域，等于给一个已经关掉的库继续找片源。
ModuleId _moduleOfResourceDomain(_DownloadsResourceDomain domain) =>
    switch (domain) {
      _DownloadsResourceDomain.books => ModuleId.books,
      _DownloadsResourceDomain.manga => ModuleId.manga,
    };

/// 此刻可见的资源域，顺序即标签顺序（枚举声明序）。
///
/// games 域是「找 galgame 资源下到本机」，只对本机游戏库形态成立；非 Windows
/// 的 games 模块是串流接收端（游戏装在 Windows 主机上），不出这个域。
List<_DownloadsResourceDomain> _visibleResourceDomains(
  ModuleVisibility visibility,
) => <_DownloadsResourceDomain>[
  for (final _DownloadsResourceDomain domain in _DownloadsResourceDomain.values)
    if (visibility.isEnabled(_moduleOfResourceDomain(domain))) domain,
];
