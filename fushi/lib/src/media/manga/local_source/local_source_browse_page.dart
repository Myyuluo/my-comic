import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/manga_cover_placeholder.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/online/online_source_browse_page.dart';
import 'package:fushi/src/media/online/online_source_error_text.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
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
/// 不再复用在线源浏览页外壳（[OnlineSourceBrowsePage]）：页头是返回键 + 浮动
/// 标题胶囊 + 标题右侧「全部 / 未入架 / 已入架」页签（与「浏览 / 图源 / 发现」
/// 同款 [LibrarySectionTabs] 浮动分段页签），搜索框在标题行下方；正文保留扫描、
/// 搜索、封面网格与加载 / 空态 / 错误态。
///
/// 只展示、不登记：点封面进作品页（未入库的走
/// [LocalSourceMangaSeriesTarget]），用户在作品页显式「加入书架」才写 Library。
/// 封面由 ticket 04 的 [LocalSourceCoverService] 在后台逐部补齐。
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
    setState(() => _filter = filter);
  }

  void _search(String value) {
    setState(() => _query = value.trim());
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
    return FushiPageScaffold(
      title: t.local_source_title,
      headerTitle: _buildHeaderTitle(context),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: FushiSearchBar(
                fieldKey: const ValueKey<String>('local_source_search_field'),
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
            Expanded(child: _buildResults(context)),
          ],
        ),
      ),
    );
  }

  /// 页头主位：浮动标题胶囊 + 紧挨其右侧的状态页签。
  ///
  /// 结构留好页头的 `actions` 位（ticket 06 的「选择」按钮走脚手架 actions，
  /// 不需要重排这一行）。
  Widget _buildHeaderTitle(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FushiPageChromeTitle(title: Text(t.local_source_title)),
        SizedBox(width: tokens.spacing.gap),
        Flexible(
          child: LibrarySectionTabs<LocalSourceShelfFilter>(
            key: const ValueKey<String>('local_source_filter_tabs'),
            tabs: <LibrarySectionTab<LocalSourceShelfFilter>>[
              LibrarySectionTab<LocalSourceShelfFilter>(
                value: LocalSourceShelfFilter.all,
                label: t.local_source_filter_all,
                labelKey: const ValueKey<String>('local_source_filter_all'),
              ),
              LibrarySectionTab<LocalSourceShelfFilter>(
                value: LocalSourceShelfFilter.notInLibrary,
                label: t.local_source_filter_not_in_library,
                labelKey: const ValueKey<String>(
                  'local_source_filter_not_in_library',
                ),
              ),
              LibrarySectionTab<LocalSourceShelfFilter>(
                value: LocalSourceShelfFilter.inLibrary,
                label: t.local_source_filter_in_library,
                labelKey: const ValueKey<String>(
                  'local_source_filter_in_library',
                ),
              ),
            ],
            selected: _filter,
            onChanged: _selectFilter,
            focusIdPrefix: 'local-source-filter',
            floating: true,
          ),
        ),
      ],
    );
  }

  Widget _buildResults(BuildContext context) {
    final List<LocalSourceManga> items = _visibleItems;
    // 加载 = 与封面网格同轮廓的骨架；错误 / 空态统一 FushiPlaceholderMessage。
    if (_loading && items.isEmpty) {
      return _buildSkeleton(context);
    }
    final Object? error = _error;
    if (error != null && items.isEmpty) {
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          key: const ValueKey<String>('local_source_error'),
          icon: FushiIcons.error,
          tone: FushiPlaceholderTone.error,
          message: error is LocalSourceRootUnavailable
              ? t.local_source_scan_failed
              : describeOnlineSourceError(error),
          action: FushiFilledButton.tonalIcon(
            onPressed: () => unawaited(_retry()),
            icon: const FushiIcon(FushiIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );
    }
    if (items.isEmpty) {
      // 扫描结果本身为空 = 「尚未发现任何漫画」；扫描到东西但被页签 / 搜索筛掉
      // = 现有的无结果态（不新增另一套文案）。
      final bool emptyScan = _catalog.scanned.isEmpty;
      final bool noResults = !emptyScan || _query.isNotEmpty;
      return SafeArea(
        bottom: false,
        child: FushiPlaceholderMessage(
          icon: noResults ? FushiIcons.searchOff : FushiIcons.books,
          message: noResults ? t.no_search_results : t.local_source_empty,
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiEntranceScope(
          child: GridView.builder(
            key: const ValueKey<String>('local_source_grid'),
            padding: withBottomSafeInset(
              context,
              const EdgeInsets.fromLTRB(16, 16, 16, 16),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: items.length,
            itemBuilder: fushiStaggeredItemBuilder((
              BuildContext context,
              int index,
            ) {
              final LocalSourceManga manga = items[index];
              return FushiCard(
                key: ValueKey<String>(
                  'local_source_item_${manga.directoryPath}',
                ),
                padding: EdgeInsets.zero,
                onTap: () => unawaited(_openManga(manga)),
                // FushiCard 内部已按同一圆角 token 裁剪，这里不再多包 ClipRRect。
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Expanded(child: _buildCover(manga)),
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
              );
            }),
          ),
        );
      },
    );
  }

  /// 封面沿用 `cover.jpg/jpeg/png` 约定；缺失时用现有占位封面。后台补齐后
  /// catalog 会通知页面重建，对应卡片自动换成生成好的 `cover.jpg`。
  Widget _buildCover(LocalSourceManga manga) {
    final String? relative = manga.coverRelativePath;
    if (relative == null) return const MangaCoverPlaceholder();
    final String path = p.join(manga.directoryPath, relative);
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      // 坏封面 / 扫描后被移走的文件退回占位，不让网格解码报错。
      errorBuilder: (_, Object error, __) => const MangaCoverPlaceholder(),
    );
  }

  /// 首屏加载骨架：与结果网格同列数、同比例的封面块 + 两条标题条。
  Widget _buildSkeleton(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = (constraints.maxWidth / 180).floor().clamp(2, 8);
        return FushiSkeletonShimmer(
          child: GridView.builder(
            key: const ValueKey<String>('local_source_skeleton'),
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              childAspectRatio: 0.62,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: columns * 3,
            itemBuilder: (BuildContext context, int index) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: FushiSkeleton(borderRadius: FushiM3eShape.cardRadius),
                ),
                const SizedBox(height: 10),
                FushiSkeleton.line(widthFactor: 0.9),
                const SizedBox(height: 6),
                FushiSkeleton.line(widthFactor: 0.5),
              ],
            ),
          ),
        );
      },
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
/// [OnlineSourceCatalog] 的适配方法（[fetch] / [buildCover] / 空态文案等）保留
/// 给既有测试与在线源适配器契约使用；独立页只消费 [scanned] 与 [changes]。
class LocalSourceBrowseCatalog extends OnlineSourceCatalog<LocalSourceManga> {
  LocalSourceBrowseCatalog({required this.root, required this.db});

  /// Local source root（`<Content root>/local`）。
  final Directory root;

  /// 已登记作品的 `coverPath` 同步（生成封面的副作用）。
  final FushiDatabase db;

  List<LocalSourceManga> _scanned = const <LocalSourceManga>[];
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);
  Future<void> _coversGenerated = Future<void>.value();
  int _coverGenerationId = 0;

  /// 本轮扫描结果（后台补齐封面后原地更新对应条目）。
  List<LocalSourceManga> get scanned =>
      List<LocalSourceManga>.unmodifiable(_scanned);

  @override
  Listenable get changes => _revision;

  /// 本轮后台封面补齐完成（进页时启动一次；测试可等待它）。
  Future<void> get coversGenerated => _coversGenerated;

  @override
  String get title => t.local_source_title;

  @override
  String get searchHint => t.local_source_search_hint;

  @override
  String get keyPrefix => 'local_source';

  @override
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
    _coversGenerated = _generateMissingCovers();
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

  @override
  void dispose() {
    // 让在途的后台循环在下一个作品前停下，之后不再触碰已释放的 notifier。
    _coverGenerationId++;
    _revision.dispose();
    super.dispose();
  }

  @override
  List<OnlineBrowseListing> get listings => const <OnlineBrowseListing>[];

  @override
  bool get hasFilters => false;

  @override
  Future<OnlineBrowseFilterTarget?> editFilters(BuildContext context) async =>
      null;

  @override
  Future<OnlineBrowsePageResult<LocalSourceManga>> fetch(
    OnlineBrowseQuery query,
    int page,
  ) async {
    final List<LocalSourceManga> matched = _scanned
        .where(
          (LocalSourceManga manga) => matchesMediaSearch(
            query: query.isSearch ? query.text : '',
            titles: <String>[manga.title],
          ),
        )
        .toList();
    matched.sort(
      (LocalSourceManga a, LocalSourceManga b) =>
          naturalCompare(a.title, b.title),
    );
    return (items: matched, hasNextPage: false);
  }

  @override
  String keyOf(LocalSourceManga item) => item.directoryPath;

  @override
  String titleOf(LocalSourceManga item) => item.title;

  @override
  Widget buildCover(BuildContext context, LocalSourceManga item) {
    final String? relative = item.coverRelativePath;
    if (relative == null) return const MangaCoverPlaceholder();
    final String path = p.join(item.directoryPath, relative);
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, Object error, __) => const MangaCoverPlaceholder(),
    );
  }

  @override
  void Function(BuildContext context, LocalSourceManga item)? get openDetail =>
      (BuildContext context, LocalSourceManga manga) {
        Navigator.of(context).push(
          adaptivePageRoute<void>(
            context: context,
            builder: (BuildContext context) =>
                MangaSeriesPage(target: LocalSourceMangaSeriesTarget(manga)),
          ),
        );
      };

  @override
  Widget buildVerifyAction(
    BuildContext context, {
    required Object? error,
    required Future<void> Function() onVerified,
  }) => const SizedBox.shrink();

  @override
  String describeError(Object error) => error is LocalSourceRootUnavailable
      ? t.local_source_scan_failed
      : describeOnlineSourceError(error);

  /// 空态：不搜索时是书架图标 +「尚未发现任何漫画」；搜索无命中仍是放大镜。
  @override
  IconData emptyIcon({required bool searching}) =>
      searching ? FushiIcons.searchOff : FushiIcons.books;

  @override
  String emptyTextFor({required bool searching}) =>
      searching ? t.no_search_results : t.local_source_empty;
}
