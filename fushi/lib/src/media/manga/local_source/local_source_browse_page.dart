import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_cover_placeholder.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/online/cover_browse_shared.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

/// 「全部 / 未入架 / 已入架」页签：按作品是否已在 Library 里筛选扫描结果。
enum LocalSourceShelfFilter {
  /// 不筛：local 里扫描到的全部作品。
  all,

  /// 不在 Library 的作品（含已移出书架的 tombstone 作品）。
  notInLibrary,

  /// 已在 Library 里登记的作品。
  inLibrary,
}

/// 内置「本地图源」的独立浏览页：进入即扫描 Local source root（`local`），以
/// 封面网格展示扫描结果。
///
/// 不复用在线源浏览页外壳：页头是返回键 + 浮动标题胶囊 + 标题右侧「全部 /
/// 未入架 / 已入架」页签（与「浏览 / 图源 / 发现」同款 [LibrarySectionTabs]
/// 浮动分段页签），搜索框在标题行下方；正文保留扫描、搜索、封面网格与加载 /
/// 空态 / 错误态。
///
/// 单部作品不在这里隐式登记：普通单击进作品页（未入库的走
/// [LocalSourceMangaSeriesTarget]），用户在作品页显式「加入书架」才写 Library；
/// 批量入口（右上「选择」或鼠标长按卡片）进入选择模式后，可把选中的未入架作品
/// 批量加入书架、把已入架作品批量移出书架（只删条目 + 墓碑，**不删 `local`
/// 文件**）。封面由 ticket 04 的 [LocalSourceCoverService] 在后台逐部补齐。
class LocalSourceBrowsePage extends ConsumerStatefulWidget {
  const LocalSourceBrowsePage({super.key});

  @override
  ConsumerState<LocalSourceBrowsePage> createState() =>
      _LocalSourceBrowsePageState();
}

class _LocalSourceBrowsePageState extends ConsumerState<LocalSourceBrowsePage> {
  late final AppModel _appModel;
  late final LocalSourceBrowseCatalog _catalog;

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  LocalSourceShelfFilter _filter = LocalSourceShelfFilter.all;
  String _query = '';

  /// 批量选择状态机（与漫画书架页共用 [MediaSelectionController]）：模式位、
  /// 散卡选中集与可见序约束都在里面。选中键用作品目录路径（扫描结果的稳定身份）。
  final MediaSelectionController _selection = MediaSelectionController();

  /// 批量操作进行中：防止重复点击 / 并发两次登记。
  bool _batchRunning = false;

  bool get _selectionMode => _selection.active;

  /// 已在 Library 里登记的 bookKey 集合（ticket 04 的身份派生：
  /// [localSourceBookKeyFor]）。tombstone 行不在这里，所以算「未入架」。
  Set<String> _libraryKeys = <String>{};

  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _appModel = ref.read(appProvider);
    _catalog = LocalSourceBrowseCatalog(
      root: _appModel.appPaths.localComicRoot,
      db: _appModel.database,
    );
    _catalog.changes.addListener(_onCatalogChanged);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _catalog.changes.removeListener(_onCatalogChanged);
    _catalog.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// 每次进页重新扫描（不做文件监视、不做增量缓存），同时刷新书架状态。
  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _catalog.prepare();
      await _loadLibraryKeys();
      if (!mounted) return;
      setState(() => _loading = false);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('LocalSourceBrowse.prepare', error, stack);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  Future<void> _loadLibraryKeys() async {
    final List<EpubBookMeta> metas = await _appModel.database
        .getEpubBookMetas();
    _libraryKeys = <String>{
      for (final EpubBookMeta meta in metas) meta.bookKey,
    };
  }

  /// 后台逐部补齐封面后，catalog 通知内容变了：重建网格拿新的 `cover.jpg`。
  void _onCatalogChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _retry() => _initialize();

  void _selectFilter(LocalSourceShelfFilter filter) {
    if (filter == _filter) return;
    setState(() {
      _filter = filter;
      // 切换页签后旧选择要么已被筛掉、要么语义已变：立即退出选择并清空，
      // 不让用户对看不见的条目继续批量操作。
      _selection.exit();
    });
  }

  void _search(String value) {
    setState(() => _query = value.trim());
  }

  void _toggleSelectionMode() {
    if (_batchRunning) return;
    setState(_selection.toggleMode);
  }

  void _exitSelectionMode() {
    if (!_selectionMode) return;
    setState(_selection.exit);
  }

  /// 每帧把「页签 + 搜索 + 自然排序」之后的可见顺序登记给状态机：全选 / 反选
  /// 与「已选 N」都只认这份可见序（漫画书架页同一做法）。
  ///
  /// 可见序变了要补一帧：它是 build 期算出来的，批量栏 / 页头在同一帧更早的
  /// 位置已读过选中集，会慢一拍且没有后续 setState 把它补上。
  ///
  /// 这段 6 行补帧与漫画书架页有意保留为同一份小重复：两边各自持有 State，
  /// 抽成 helper 要传 `setState` + `mounted`，反而把「谁在重建」藏起来；批量栏
  /// 的弹簧容器已抽成 [BatchActionBarHost]，这里只剩这一个约定。
  void _syncVisibleSelectionOrder(List<LocalSourceManga> items) {
    final bool changed = _selection.setVisibleOrder(
      loose: <String>[
        for (final LocalSourceManga item in items) item.directoryPath,
      ],
      collections: const <int>[],
    );
    if (!changed || !_selectionMode) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) setState(() {});
    });
  }

  /// 卡片点击：选择模式内切换选中（Shift = 区间选）；普通模式打开作品页。
  void _handleCardTap(LocalSourceManga manga) {
    if (_selectionMode) {
      setState(() => _selection.applyTap(
        SelectionSlot.loose(manga.directoryPath),
        selectionTapKind(),
      ));
      return;
    }
    unawaited(_openManga(manga));
  }

  /// 鼠标 / 触屏长按：普通模式进入选择并选中该作品；选择模式内切换选中。
  void _handleCardLongPress(LocalSourceManga manga) {
    final SelectionSlot slot = SelectionSlot.loose(manga.directoryPath);
    setState(() {
      if (_selectionMode) {
        _selection.toggle(slot);
      } else {
        _selection.enterWith(slot);
      }
    });
  }

  void _selectAll() {
    setState(() => _selection.selectAll(
      loose: _selection.visibleLooseKeys,
      collections: const <int>[],
    ));
  }

  void _invertSelection() {
    setState(() => _selection.invert(
      loose: _selection.visibleLooseKeys,
      collections: const <int>[],
    ));
  }

  /// 当前可见列表里被选中的作品（批量动作的作用域；不可见项不参与）。
  List<LocalSourceManga> _selectedWorks() {
    final Set<String> keys = _selection.looseKeys;
    if (keys.isEmpty) return const <LocalSourceManga>[];
    return <LocalSourceManga>[
      for (final LocalSourceManga manga in _visibleItems)
        if (keys.contains(manga.directoryPath)) manga,
    ];
  }

  /// 批量「加入书架」：只登记选中且未入架的作品（tombstone 算未入架，插入行
  /// 会清墓碑）；已入架的不重复登记。
  Future<void> _batchAddToLibrary() async {
    if (_batchRunning) return;
    final List<LocalSourceManga> targets = _selectedWorks()
        .where((LocalSourceManga manga) => !_isInLibrary(manga))
        .toList(growable: false);
    if (targets.isEmpty) return;
    setState(() => _batchRunning = true);
    final LocalSourceLibrary library = LocalSourceLibrary(
      db: _appModel.database,
      root: _appModel.appPaths.localComicRoot,
    );
    int success = 0;
    int failed = 0;
    for (final LocalSourceManga manga in targets) {
      try {
        await library.registerScannedManga(manga);
        success++;
      } on Object catch (error, stack) {
        failed++;
        ErrorLogService.instance.log(
          'LocalSourceBrowse.batchAddToLibrary',
          error,
          stack,
        );
      }
    }
    await _finishBatch(
      success: success,
      failed: failed,
      message: t.local_source_batch_add_done(success: success, failed: failed),
    );
  }

  /// 批量「移出书架」：只删除选中且已入架的书架条目并写 tombstone，
  /// **绝不删除 `local` 文件**（与作品页的单部移出同一路径）。
  Future<void> _batchRemoveFromLibrary() async {
    if (_batchRunning) return;
    final List<LocalSourceManga> targets = _selectedWorks()
        .where(_isInLibrary)
        .toList(growable: false);
    if (targets.isEmpty) return;
    setState(() => _batchRunning = true);
    final LocalSourceLibrary library = LocalSourceLibrary(
      db: _appModel.database,
      root: _appModel.appPaths.localComicRoot,
    );
    int success = 0;
    int failed = 0;
    for (final LocalSourceManga manga in targets) {
      try {
        final bool removed = await library.removeFromLibrary(
          localSourceBookKeyFor(manga.directoryPath),
        );
        if (removed) {
          success++;
        } else {
          failed++;
        }
      } on Object catch (error, stack) {
        failed++;
        ErrorLogService.instance.log(
          'LocalSourceBrowse.batchRemoveFromLibrary',
          error,
          stack,
        );
      }
    }
    await _finishBatch(
      success: success,
      failed: failed,
      message: t.local_source_batch_remove_done(
        success: success,
        failed: failed,
      ),
    );
  }

  /// 批量动作收尾：刷新书架状态（页签 / 卡片判定），退出选择并清空——
  /// 不保留失败项；用 toast 报告成功 / 失败数量。
  Future<void> _finishBatch({
    required int success,
    required int failed,
    required String message,
  }) async {
    try {
      await _loadLibraryKeys();
    } on Object {
      // 刷新失败不改变批量已落库的事实：仍退出选择并照实报告计数。
    }
    if (!mounted) return;
    setState(() {
      _batchRunning = false;
      _selection.exit();
    });
    FushiToast.show(
      msg: message,
      severity: failed == 0 ? ToastSeverity.success : ToastSeverity.warning,
    );
  }

  bool _isInLibrary(LocalSourceManga manga) =>
      _libraryKeys.contains(localSourceBookKeyFor(manga.directoryPath));

  bool _matchesFilter(LocalSourceManga manga) {
    switch (_filter) {
      case LocalSourceShelfFilter.all:
        return true;
      case LocalSourceShelfFilter.notInLibrary:
        return !_isInLibrary(manga);
      case LocalSourceShelfFilter.inLibrary:
        return _isInLibrary(manga);
    }
  }

  /// 当前页签 + 搜索叠加后的可见列表：先按书架状态筛，再按标题搜。
  List<LocalSourceManga> get _visibleItems {
    final List<LocalSourceManga> items =
        <LocalSourceManga>[
          for (final LocalSourceManga manga in _catalog.scanned)
            if (_matchesFilter(manga) &&
                matchesMediaSearch(
                  query: _query,
                  titles: <String>[manga.title],
                ))
              manga,
        ]..sort(
          (LocalSourceManga a, LocalSourceManga b) =>
              naturalCompare(a.title, b.title),
        );
    return items;
  }

  Future<void> _openManga(LocalSourceManga manga) async {
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) =>
            MangaSeriesPage(target: LocalSourceMangaSeriesTarget(manga)),
      ),
    );
    // 作品页里可能刚「加入书架」：回来刷新「已入架 / 未入架」的判定。
    if (!mounted) return;
    try {
      await _loadLibraryKeys();
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final List<LocalSourceManga> items = _visibleItems;
    _syncVisibleSelectionOrder(items);
    // 选择模式吃返回键 / ESC：先退出选择，再允许离开页面（与书架页 BUG-250 同语义）。
    // 用 [SectionPopScope] 是为了不在保活分区里错误拦截（本页是独立路由，恒可见）。
    return SectionPopScope(
      intercepting: _selectionMode,
      onIntercept: _exitSelectionMode,
      child: FushiPageScaffold(
        title: t.local_source_title,
        headerTitle: _buildHeaderTitle(context),
        actions: <Widget>[_buildSelectToggle(context)],
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: FushiSearchBar(
                  fieldKey: const ValueKey<String>(
                    'local_source_search_field',
                  ),
                  focusId: const FushiFocusId('local-source-browse-search'),
                  controller: _searchController,
                  focusNode: _searchFocus,
                  hintText: t.local_source_search_hint,
                  onSubmitted: _search,
                  onClear: () {
                    _searchController.clear();
                    _search('');
                  },
                ),
              ),
              Expanded(child: _buildResults(context, items)),
              // 批量栏与漫画书架页同款：从底边弹簧浮入 / 沉下，收起后从树里
              // 移除；退出选择后沉下那一程继续画上一帧的批量栏（计数不会先
              // 闪成 0）。容器与书架页共用 [BatchActionBarHost]。
              BatchActionBarHost(
                visible: _selectionMode,
                builder: _buildBatchActionBar,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 页头右上角「选择」：与漫画书架页同款清单图标，选择模式内变成 X。
  Widget _buildSelectToggle(BuildContext context) {
    return FushiIconButton(
      key: const ValueKey<String>('local_source_select_toggle'),
      icon: _selectionMode ? FushiIcons.close : FushiIcons.checklist,
      tooltip: _selectionMode
          ? MaterialLocalizations.of(context).closeButtonTooltip
          : t.batch_select,
      selected: _selectionMode,
      onTap: _toggleSelectionMode,
    );
  }

  /// 底部批量栏（复用漫画书架页的 [BatchActionBar]）：已选 N / 全选 / 反选 +
  /// 「加入书架」/「移出书架」。两个动作始终显示；没有适用的选中项时置灰
  /// （加入只看未入架、移出只看已入架，混合选择各按适用子集执行）。
  Widget _buildBatchActionBar(BuildContext context) {
    final List<LocalSourceManga> selected = _selectedWorks();
    final bool hasAddable =
        selected.any((LocalSourceManga manga) => !_isInLibrary(manga));
    final bool hasRemovable = selected.any(_isInLibrary);
    return BatchActionBar(
      selectedCount: _selection.length,
      onSelectAll: _selectAll,
      onInvertSelection: _invertSelection,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('local_source_batch_add'),
          enabled: hasAddable && !_batchRunning,
          onTap: () => unawaited(_batchAddToLibrary()),
          icon: FushiIcons.libraryAdd,
          tooltip: t.mihon_add_to_bookshelf,
        ),
        FushiIconButton(
          key: const ValueKey<String>('local_source_batch_remove'),
          enabled: hasRemovable && !_batchRunning,
          onTap: () => unawaited(_batchRemoveFromLibrary()),
          icon: Icons.delete_outline,
          tooltip: t.manga_series_remove_from_bookshelf,
          enabledColor: Theme.of(context).colorScheme.error,
        ),
      ],
    );
  }

  /// 页头主位：浮动标题胶囊 + 紧挨其右侧的状态页签。
  ///
  /// 用共享的 [LibraryHeaderTitleWithTabs]：它把「胶囊 + 间距 + 页签」整行的
  /// 自然宽上报给页头，动作收纳预算不会少算胶囊那一段。结构留好页头的
  /// `actions` 位（ticket 06 的「选择」按钮走脚手架 actions，不需要重排这一行）。
  Widget _buildHeaderTitle(BuildContext context) {
    return LibraryHeaderTitleWithTabs<LocalSourceShelfFilter>(
      title: t.local_source_title,
      tabsKey: const ValueKey<String>('local_source_filter_tabs'),
      tabs: <LibrarySectionTab<LocalSourceShelfFilter>>[
        LibrarySectionTab<LocalSourceShelfFilter>(
          value: LocalSourceShelfFilter.all,
          label: t.local_source_filter_all,
          labelKey: const ValueKey<String>('local_source_filter_all'),
        ),
        LibrarySectionTab<LocalSourceShelfFilter>(
          value: LocalSourceShelfFilter.notInLibrary,
          label: t.local_source_filter_not_in_library,
          labelKey: const ValueKey<String>('local_source_filter_not_in_library'),
        ),
        LibrarySectionTab<LocalSourceShelfFilter>(
          value: LocalSourceShelfFilter.inLibrary,
          label: t.local_source_filter_in_library,
          labelKey: const ValueKey<String>('local_source_filter_in_library'),
        ),
      ],
      selected: _filter,
      onChanged: _selectFilter,
      focusIdPrefix: 'local-source-filter',
    );
  }

  Widget _buildResults(BuildContext context, List<LocalSourceManga> items) {
    // 加载 = 与封面网格同轮廓的骨架；错误 / 空态统一 FushiPlaceholderMessage
    // （与在线源浏览页共用同一套骨架 / 占位组件）。
    if (_loading && items.isEmpty) {
      return const FushiCoverGridSkeleton(
        keyPrefix: 'local_source',
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16),
      );
    }
    final Object? error = _error;
    if (error != null && items.isEmpty) {
      return FushiCoverBrowsePlaceholder(
        messageKey: const ValueKey<String>('local_source_error'),
        icon: FushiIcons.error,
        error: true,
        message: error is LocalSourceRootUnavailable
            ? t.local_source_scan_failed
            : describeOnlineSourceError(error),
        action: FushiFilledButton.tonalIcon(
          onPressed: () => unawaited(_retry()),
          icon: const FushiIcon(FushiIcons.refresh),
          label: Text(t.retry),
        ),
      );
    }
    if (items.isEmpty) {
      // 扫描结果本身为空 = 「尚未发现任何漫画」；扫描到东西但被页签 / 搜索筛掉
      // = 现有的无结果态（不新增另一套文案）。
      final bool emptyScan = _catalog.scanned.isEmpty;
      final bool noResults = !emptyScan || _query.isNotEmpty;
      return FushiCoverBrowsePlaceholder(
        icon: noResults ? FushiIcons.searchOff : FushiIcons.books,
        message: noResults ? t.no_search_results : t.local_source_empty,
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return FushiEntranceScope(
          child: GridView.builder(
            key: const ValueKey<String>('local_source_grid'),
            padding: withBottomSafeInset(
              context,
              const EdgeInsets.fromLTRB(16, 16, 16, 16),
            ),
            gridDelegate: coverGridDelegateFor(constraints.maxWidth),
            itemCount: items.length,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int index,
            ) {
              final LocalSourceManga manga = items[index];
              final bool selected = _selection.looseKeys.contains(
                manga.directoryPath,
              );
              return SelectionSlotTarget(
                slot: SelectionSlot.loose(manga.directoryPath),
                child: FushiCard(
                  key: ValueKey<String>(
                    'local_source_item_${manga.directoryPath}',
                  ),
                  padding: EdgeInsets.zero,
                  onTap: () => _handleCardTap(manga),
                  onLongPress: () => _handleCardLongPress(manga),
                  // FushiCard 内部已按同一圆角 token 裁剪，这里不再多包 ClipRRect。
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: _buildCover(manga, selected: selected)),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                        child: Text(
                          manga.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.fushiType.titleSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }

  /// 封面沿用 `cover.jpg/jpeg/png` 约定；缺失时用现有占位封面。后台补齐后
  /// catalog 会通知页面重建，对应卡片自动换成生成好的 `cover.jpg`。
  ///
  /// 选择模式下叠加漫画书架页的共享选中罩与左上角勾选圈
  /// （[ShelfSelectedOverlay] / [ShelfSelectionCheck]）；未选中时只画勾选圈，
  /// 保证用户知道哪些卡可以勾。
  Widget _buildCover(LocalSourceManga manga, {required bool selected}) {
    final String? relative = manga.coverRelativePath;
    final Widget cover = relative == null
        ? const MangaCoverPlaceholder()
        : Image.file(
            File(p.join(manga.directoryPath, relative)),
            fit: BoxFit.cover,
            // 坏封面 / 扫描后被移走的文件退回占位，不让网格解码报错。
            errorBuilder: (_, Object error, __) => const MangaCoverPlaceholder(),
          );
    if (!_selectionMode) return cover;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double checkInset = tokens.spacing.gap / 2;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        cover,
        if (selected) const Positioned.fill(child: ShelfSelectedOverlay()),
        PositionedDirectional(
          top: checkInset,
          start: checkInset,
          child: ShelfSelectionCheck(selected: selected),
        ),
      ],
    );
  }

}

/// Local source root 读不了（目录不存在 / 无权限）时抛给浏览页的错误态。
class LocalSourceRootUnavailable implements Exception {
  const LocalSourceRootUnavailable(this.path, [this.cause]);

  final String path;
  final Object? cause;

  @override
  String toString() =>
      'LocalSourceRootUnavailable($path)${cause == null ? '' : ': $cause'}';
}

/// 本地图源的扫描 / 封面数据源：一次扫描的结果就是全部内容。
///
/// [prepare] 每次进页扫描一次（不做文件监视、不做增量缓存），扫描完成即返回，
/// 让网格先显示结果；随后在后台**逐个**给缺封面的作品生成 `cover.jpg`，每完成
/// 一部就通过 [changes] 通知页面更新对应卡片。生成失败的作品保持占位，下次
/// 进页重试。扫描原地读取，不复制、不移动任何文件。
///
/// 独立页只消费 [scanned] 与 [changes]；这里刻意不再实现在线源目录适配器，
/// 避免留下一堆只有测试在用的空实现。
class LocalSourceBrowseCatalog {
  LocalSourceBrowseCatalog({required this.root, required this.db});

  /// Local source root（`<Content root>/local`）。
  final Directory root;

  /// 已登记作品的 `coverPath` 同步（生成封面的副作用）。
  final FushiDatabase db;

  List<LocalSourceManga> _scanned = const <LocalSourceManga>[];
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  int _coverGenerationId = 0;

  /// 本轮扫描结果（后台补齐封面后原地更新对应条目）。
  List<LocalSourceManga> get scanned =>
      List<LocalSourceManga>.unmodifiable(_scanned);

  /// 后台封面补齐有进展时通知页面（每补好一部 +1，页面据此重建网格）。
  Listenable get changes => _revision;

  Future<void> prepare() async {
    // 目录不在了（Content root 掉线 / 被删）是错误态，不是空态：空态只表示
    // 「文件夹里确实还没有漫画」。先探一次根目录，让读取失败冒泡给页面。
    if (!await root.exists()) {
      throw LocalSourceRootUnavailable(root.path);
    }
    try {
      root.listSync(followLinks: false);
    } on FileSystemException catch (error) {
      throw LocalSourceRootUnavailable(root.path, error);
    }
    _scanned = await scanLocalSourceRoot(root);
    unawaited(_generateMissingCovers());
  }

  /// 后台逐部补齐封面：不阻塞首屏；成功后替换扫描条目并通知页面刷新。
  ///
  /// 单部失败（坏页 / 写入失败）只跳过它，占位保留，下次进页再试。重复
  /// [prepare] 时旧循环在下一个作品前自停，避免两轮同时写同一批封面。
  Future<void> _generateMissingCovers() async {
    final int generation = ++_coverGenerationId;
    final LocalSourceCoverService service = LocalSourceCoverService(db: db);
    for (final LocalSourceManga manga in List<LocalSourceManga>.of(_scanned)) {
      if (generation != _coverGenerationId) return;
      try {
        final LocalSourceCoverResult result = await service
            .generateMissingCover(manga);
        if (generation != _coverGenerationId) return;
        final String? cover = result.coverRelativePath;
        if (cover == null || cover == manga.coverRelativePath) continue;
        _scanned = <LocalSourceManga>[
          for (final LocalSourceManga item in _scanned)
            p.equals(item.directoryPath, manga.directoryPath)
                ? withLocalSourceCoverRelativePath(item, cover)
                : item,
        ];
        _revision.value++;
      } on Object {
        // 保持占位；下次进入本地图源时重新扫描并重试。
      }
    }
  }

  /// 让在途的后台循环在下一个作品前停下，之后不再触碰已释放的 notifier。
  void dispose() {
    _coverGenerationId++;
    _revision.dispose();
  }
}
