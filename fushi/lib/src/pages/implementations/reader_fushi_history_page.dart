import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'dart:async' show StreamSubscription, Timer, unawaited;
import 'dart:io';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/epub/book_file_location.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'package:fushi_engine/sync/epub_repackage.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi/src/media/audiobook/srt_book_reimport_dialog.dart';
import 'package:fushi/src/media/audiobook/tts/studio/tts_studio_page.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/drag_drop/card_drop_registry.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/drop_decision.dart';
import 'package:fushi/src/media/drag_drop/image_archive_probe.dart';
import 'package:fushi/src/media/tags/tag_drop.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/manga_download_planner.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_download_state.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_unread.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart'
    show OnlineMangaRefreshResult;
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_drop.dart';



import 'package:fushi/src/pages/implementations/book_drag_target.dart';

import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart'
    show DiscoveryMediaKind;
import 'package:fushi/src/pages/implementations/name_input_dialog.dart';
import 'package:fushi/src/pages/implementations/library_filter_dropdown.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';
import 'package:fushi/src/pages/implementations/tag_filter_bar.dart';
import 'package:fushi/src/utils/components/fushi_header_search.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetPadding,
        FushiFloatingChromeOverlay;
import 'package:fushi_core/fushi_core.dart';
// BUG-813：构造 ReaderPositionsCompanion 回填下载书的阅读进度需要 drift 的 Value（
// fushi_core 未再导出它）。
import 'package:drift/drift.dart' show Value;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/library_progress_reset.dart';
import 'package:fushi/src/pages/implementations/library_progress_reset_dialog.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/media/metadata/book_cover_scrape_dialog.dart';
import 'package:fushi_engine/media/collections/shelf_sort.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/shelf_card_layout.dart';
import 'package:fushi/src/media/selection/media_selection_controller.dart';
import 'package:fushi/src/media/selection/selection_gestures.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressActions;
import 'package:fushi/src/sync/cloud_remote_book_client.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/local_file_delete_feedback.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:fushi/src/sync/deletion_propagation_availability.dart';
import 'package:fushi/src/sync/deletion_prompt_preferences.dart';

import 'package:fushi/src/sync/hidden_remote_books.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/remote_download_progress_badge.dart';
import 'package:fushi/src/sync/remote_download_temp_file.dart';
import 'package:fushi/src/sync/remote_cover_image.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_deletion_filter.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi_engine/sync/sync_asset_package_service.dart';
import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi/src/sync/sync_progress_banner.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi/src/utils/components/section_visibility.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/cover_image.dart';

part 'reader_history/card_widgets.part.dart';
part 'reader_history/remote.part.dart';
part 'reader_history/books.part.dart';
part 'reader_history/dialogs.part.dart';

/// Stable gamepad/keyboard focus ids for the shelf chrome, used both to place
/// [FushiFocusTarget]s and to wire directional anchors (see
/// [FushiFocusController.registerDirectionalAnchor]). Kept as constants (not
/// derived per-instance ids) precisely so anchors can point at them by name.
const FushiFocusId kShelfImportFocusId = FushiFocusId('reader-shelf-import');

/// 书架「继续阅读」hero 的最大宽度：宽屏不拉满整行（一条 1600px 的长卡读起来
/// 像横幅广告），窄屏照常撑满。
const double _kContinueHeroMaxWidth = 720;

/// 库页条目分流：漫画独立书架只收 manga 源条目，普通书架反向排除它们。
///
/// PR#474 让同一个页面按 `mangaOnly` 服务两个入口。这条分流是用户直接可见的
/// （漫画从普通书架消失、只在漫画书架出现），提成纯函数后两侧共用同一个谓词：
/// 写反任何一侧都会同时破坏「漫画不在普通书架露出」和「漫画书架非空」，
/// 也就不可能只坏一半而没人发现（BUG-1164）。
///
/// 用一次相等判断代替两个分支：两页的条件天然互补，不需要 if/else。
List<MediaItem> filterShelfEntriesByMangaSplit(
  List<MediaItem> books, {
  required bool mangaOnly,
}) =>
    books
        .where((MediaItem item) =>
            (item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey) ==
            mangaOnly)
        .toList();

class ReaderFushiHistoryPage extends HistoryReaderPage {
  const ReaderFushiHistoryPage({
    this.mangaOnly = false,
    this.navigation,
    this.remoteBookClientLoader,
    this.remoteBookDownloadDestination,
    this.remoteBookImporter,
    this.remoteAudiobookFetcher,
    this.remoteAudiobookImporter,
    super.key,
  });

  /// 独立漫画书架只显示 `format='manga'`；普通书架则排除漫画。
  ///
  /// 两个入口仍复用本页的搜索、排序、标签、合集、进度和删除管线，不另建数据表。
  final bool mangaOnly;

  /// 库页视图导航条（由 [MediaLibraryShell] 传入，作为页头主内容与动作同一行）。
  /// 本页作为独立页面使用时为 null，页头与此前逐像素一致。
  final Widget? navigation;

  final Future<RemoteBookClient?> Function()? remoteBookClientLoader;
  final Future<File> Function(RemoteBookInfo book)?
      remoteBookDownloadDestination;
  // 返回本地入库的 bookKey（生产路径来自 EpubImporter.importFromPath）。
  final Future<String?> Function(File file)? remoteBookImporter;

  /// 测试注入：按远端 bookKey 下载有声书包，返回包文件（绕过真实互联后端）。
  final Future<File> Function(String remoteBookKey)? remoteAudiobookFetcher;

  /// 测试注入：导入有声书包（package + bookKeyOverride），绕过真实解包落盘。
  final Future<void> Function(File package, String? bookKeyOverride)?
      remoteAudiobookImporter;

  /// 测试钩子：按 mediaIdentifier 确定性打开书（绕开离屏不可靠的焦点卡激活——
  /// 焦点+Enter 在离屏 IndexedStack 下偶发不触发书卡 onTap）。走与书卡 onTap 同一
  /// 路径 appModel.openMedia。仅 debug/profile build 在 build 注册。
  @visibleForTesting
  static Future<void> Function(String mediaIdentifier)? debugOpenBook;

  @override
  BaseHistoryPageState<BaseHistoryPage> createState() =>
      _ReaderFushiHistoryPageState();
}

class _ReaderFushiHistoryPageState<T extends HistoryReaderPage>
    extends HistoryReaderPageState {
  ReaderFushiHistoryPage get _pageWidget => widget as ReaderFushiHistoryPage;
  bool get _mangaOnly => _pageWidget.mangaOnly;

  /// 「同时删除统计数据」勾选行的副标题：漫画库与书架各说各的统计口径。
  String get _statisticsSubtitle => _mangaOnly
      ? t.delete_statistics_manga_desc
      : t.delete_statistics_book_desc;

  @override
  MediaType get mediaType => mediaSource.mediaType;

  /// 本页自己的滚动控制器。书架与漫画库是同一个页面类、取同一个
  /// `ReaderFushiSource.instance.mediaType`，两个 tab 保活并存；共用
  /// `mediaType.scrollController` 会让一个控制器附着两个位置，`thumbVisibility`
  /// 常显的滚动条（现为 [FushiScrollbar]）每次依赖变化都断言（BUG-1181 遗留）。
  final ScrollController _shelfScrollController = ScrollController();

  @override
  ReaderFushiSource get mediaSource => ReaderFushiSource.instance;

  Future<Map<String, _AudiobookInfo>>? _batchAudiobookInfoFuture;
  Map<String, _AudiobookInfo> _batchAudiobookInfoResult = const {};

  /// 拖拽导入：书卡登记表，范型 = bookKey。书卡经 [CardDropZone] 注册自身屏幕
  /// 矩形，落点命中后据此找到目标书 key（字幕/音频附加到该书）。
  final CardDropRegistry<String> _cardDropRegistry = CardDropRegistry<String>();

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  void _rebuild(VoidCallback fn) => setState(fn);

  /// 「功能模块」可见性快照（书架与它全部 part 共用的唯一读取口）。
  ///
  /// 用 [appModelNoUpdate]：本 getter 也会在 prefsRepo 回调 / 拖放回调等 build 之外
  /// 的时机被调用，那里 `ref.watch` 非法（与本页 `_shouldLoadRemoteBooks` 同款理由）；
  /// AppModel 是全局单例，读到的 pref 恒为当前真值。
  /// [AppModel.moduleVisibility] 每读一次都重新合成一个 Set——同一帧要连问几个模块
  /// 时先落成局部变量。
  ModuleVisibility get _moduleVisibility => appModelNoUpdate.moduleVisibility;

  Future<Map<String, _AudiobookInfo>> _loadAllAudiobookInfo() async {
    // my-comic 的漫画-only live schema（37 表）没有 audiobooks：表不存在 = 本端
    // 没有有声书信息，返回空表而不是让整页 FutureBuilder 落到缺表异常。
    if (!await appModel.database.hasAudiobooksTable) {
      return const <String, _AudiobookInfo>{};
    }
    final repo = AudiobookRepository(appModel.database);
    final allAudiobooks = await repo.buildBookKeyMap();
    final result = <String, _AudiobookInfo>{};
    // 一次前缀查询取完全部健康度覆盖，替代每本一条 getPref 的 N+1。
    final Map<String, AudiobookHealth> healths =
        await repo.resolveAllHealth(allAudiobooks);
    for (final entry in allAudiobooks.entries) {
      result[entry.key] = _AudiobookInfo(
        hasAudiobook: true,
        healthKind: healths[entry.key]?.kind ?? HealthKind.notApplicable,
      );
    }
    _batchAudiobookInfoResult = result;
    return result;
  }

  _AudiobookInfo _getAudiobookInfo(String bookKey) {
    return _batchAudiobookInfoResult[bookKey] ??
        const _AudiobookInfo(
            hasAudiobook: false, healthKind: HealthKind.notApplicable);
  }

  /// 批量选择状态机（与视频库 tab 共用同一个 [MediaSelectionController]）：模式位、
  /// 散卡选中集、合集整选集、Shift / 长按扫选的锚点全在里面。下面三个 getter 保留
  /// 旧字段名，让本页几十处读取点原样成立。
  final MediaSelectionController _selection = MediaSelectionController();

  bool get _selectionMode => _selection.active;

  Set<String> get _selectedKeys => _selection.looseKeys;

  List<MediaItem> _visibleEpubBooks = const [];
  List<SrtBook> _visibleSrtBooks = const [];
  Map<String, String> _epubCoverUrisByBookKey = const {};
  // BUG-728：EPUB-backed 有声书在书架**只渲染成 SRT 卡**（其 EpubBooks 行被
  // `srtBookKeys` 过滤出 EPUB 卡列表），而 SRT 卡以前不画进度条。这里收录当前
  // `books`（fushiBooksProvider）里每本 EpubBooks 行**已算好的** position/duration
  // （经 [ReaderFushiSource.computeBookProgress]，含听书 normCharOffset 回退），
  // 供 SRT 卡按 bookKey 复用同一进度，无需重复读 DB / 重算。
  Map<String, ({int position, int duration})> _epubProgressByBookKey = const {};

  Future<_RemoteBookState?>? _remoteBooksFuture;
  // BUG-992：上次成功的远端书态，自动刷新重拉（future→waiting）时沿用，避免闪屏。
  _RemoteBookState? _lastRemoteState;

  /// 排序交互重设计层次 A：当前排序方式（偏好 `shelf_sort_mode` 持久化，默认
  /// 最近阅读=历史序，现状零变化）。旧 `ShelfEntries.sortOrder` 手动权重已废弃。
  Future<void>? _shelfMapsFuture;
  ShelfSortMode _sortMode = ShelfSortMode.recent;

  /// P5-A：书架搜索词（原文，匹配时才归一化）。**刻意不持久化**——下次进书架还
  /// 挂着上次的搜索词只会让人以为书没了（与游戏库页同一决定）。
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// 单行页头的可展开搜索（2026-10-14）：平时是页头里的 🔍，点开整行换成搜索
  /// 栏；搜索词仍是上面的 [_searchQuery]（不落库）。书架 / 漫画库各一份焦点 id。
  late final FushiHeaderSearchController _headerSearch =
      FushiHeaderSearchController(
    textController: _searchController,
    buttonFocusId: FushiFocusId(
      _mangaOnly ? 'manga-library-search' : 'book-library-search',
    ),
    hintText: t.library_search,
    fieldKey: const ValueKey<String>('shelf_search_field'),
    onQueryChanged: (String value) => setState(() => _searchQuery = value),
  );

  /// 页头「排序与筛选」按钮打开的菜单（常驻锚点见 [_buildSortMenuAnchor]）。
  final MenuController _sortMenu = MenuController();

  /// BUG-2327：书架搜索命中判据，**四路**卡源（本地 EPUB / 本地 SRT / 远端 EPUB
  /// 占位 / 远端 SRT 占位）共用同一口径 [matchesMediaSearch]（空查询恒命中）。
  /// 此前只裁本地 EPUB 列表，其余三路走未过滤源——挂了有声书的书本身就以 SRT 卡
  /// 渲染，用户实报「书架搜索不生效」。
  bool _matchesShelfSearch(Iterable<String> titles) =>
      matchesMediaSearch(query: _searchQuery, titles: titles);

  /// 搜索栏「阅读状态」下拉（null = 全部）。与搜索词不同，**持久化**到偏好
  /// `shelf_read_status_filter`：这是用户刻意选的视图（同排序方式、游戏库页游玩
  /// 状态筛选），重启就丢等于每次打开都要重选（用户实报）。initState 读回。
  ShelfReadStatus? _readStatusFilter;

  /// 本帧漫画页标签页签的有效选中值（默认「书架」）。选中的标签在标签管理页
  /// 被删除后回落到「书架」；字段在 build 里按 [mangaTagTabSelectionProvider]
  /// 与本帧标签池解析，供同一帧的筛选与页签渲染共用。
  MangaTabSelection _mangaTagTabSelection = const MangaShelfTabSelection();

  /// 本帧每个页签在当前搜索词 / 阅读状态 / 漫画下载筛选下会显示的漫画数
  /// （key = 页签）。
  Map<MangaTabSelection, int> _mangaTagTabCounts =
      const <MangaTabSelection, int>{};

  /// 「漫画下载」筛选（null = 全部）。会话内状态，不持久化；与阅读状态、当前
  /// 页签是 AND 关系。
  _MangaDownloadFilter? _mangaDownloadFilter;

  /// 至少有一章本地可读的漫画 `bookKey` 集合，随 [_loadShelfMaps] 批量预取
  /// （在线看 Download library，本地图源看章节是否真的读得出来；Missing 不计）。
  Set<String> _mangaDownloadedBookKeys = const <String>{};

  /// 最近一次书架快照里的漫画章节来源行：下载任务表变化时据此重算
  /// [_mangaDownloadedBookKeys]，不用重跑整份书架映射。
  List<MangaShelfChapterSource> _mangaChapterSources =
      const <MangaShelfChapterSource>[];

  /// 漫画下载任务表的订阅（仅漫画书架）。后台下载完成 / 取消 / 删除后，
  /// 「已下载」筛选与页签数量必须跟着变，不能等下次重进页面。
  StreamSubscription<void>? _mangaDownloadJobsWatch;

  /// 上次重算时的任务 `(jobId, status)` 签名。进度更新（pagesDone 变化）不改
  /// 签名，避免每落一页就整份重探磁盘；完成 / 删除 / 状态迁移才触发重算。
  String _mangaDownloadJobsSignature = '';

  bool _mangaDownloadsRefreshing = false;
  bool _mangaDownloadsRefreshQueued = false;

  /// 漫画书架搜索用的附加元数据（`bookKey → 描述符 / 作者`），随
  /// [_loadShelfMaps] 一次批量预取。`MediaItem` 不携带在线描述符（它的
  /// `sourceMetadata` 是阅读进度用的另一份 JSON），源分类 / 简介只能从
  /// `epub_books.sourceMetadata` 解码。
  Map<String, _MangaShelfMeta> _mangaMetaByBookKey =
      const <String, _MangaShelfMeta>{};

  /// 本帧标签页签筛选前，漫画书架是否有条目。用于区分空态文案：整个书架为空
  /// （引导入库）还是当前页签 / 搜索无命中（「没有符合筛选的书」）。
  bool _mangaShelfUnfilteredNonEmpty = false;

  void _setReadStatusFilter(ShelfReadStatus? value) {
    setState(() => _readStatusFilter = value);
    unawaited(
      appModel.prefsRepo.setShelfReadStatusFilterName(value?.name ?? ''),
    );
  }

  /// 阅读状态筛选命中判据，本地 EPUB / 漫画卡与 SRT 有声书卡共用：读完看
  /// [_completedBookKeys]，在读 / 未读看进度（无进度 = 未读），口径即
  /// [classifyShelfReadStatus]（与书架概览统计同一判据）。
  bool _matchesReadStatusFilter({
    required String? bookKey,
    required ({int position, int duration})? progress,
  }) {
    final ShelfReadStatus? filter = _readStatusFilter;
    if (filter == null) return true;
    return classifyShelfReadStatus(
          completed: bookKey != null &&
              bookKey.isNotEmpty &&
              _completedBookKeys.contains(bookKey),
          position: progress?.position ?? 0,
          duration: progress?.duration ?? 0,
        ) ==
        filter;
  }

  /// 漫画页当前搜索词 + 阅读状态 + 漫画下载筛选是否放行该条目。页签数量与实际
  /// 渲染共用这一判据，保证「切过去能看到多少」不说谎。
  bool _mangaItemPassesActiveFilters(MediaItem item) {
    if (!_matchesShelfSearch(_mangaSearchTexts(item))) return false;
    if (!_matchesReadStatusFilter(
      bookKey: _parseBookKey(item.mediaIdentifier),
      progress: (position: item.position, duration: item.duration),
    )) {
      return false;
    }
    return _matchesMangaDownloadFilter(item);
  }

  /// 「已下载」= 这本书至少有一章在本地可读（[_mangaDownloadedBookKeys] 批量
  /// 预取）；「未下载」= 不在该集合里。全部（null）恒放行。
  bool _matchesMangaDownloadFilter(MediaItem item) {
    final _MangaDownloadFilter? filter = _mangaDownloadFilter;
    if (filter == null) return true;
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final bool downloaded =
        bookKey != null && _mangaDownloadedBookKeys.contains(bookKey);
    return filter == _MangaDownloadFilter.downloaded ? downloaded : !downloaded;
  }

  void _setMangaDownloadFilter(_MangaDownloadFilter? value) {
    if (_mangaDownloadFilter == value) return;
    setState(() => _mangaDownloadFilter = value);
  }

  String _mangaDownloadFilterKey(_MangaDownloadFilter? filter) =>
      switch (filter) {
        null => 'all',
        _MangaDownloadFilter.downloaded => 'downloaded',
        _MangaDownloadFilter.notDownloaded => 'not_downloaded',
      };

  String _mangaDownloadFilterLabel(_MangaDownloadFilter filter) =>
      switch (filter) {
        _MangaDownloadFilter.downloaded =>
          t.shelf_filter_download_downloaded,
        _MangaDownloadFilter.notDownloaded =>
          t.shelf_filter_download_not_downloaded,
      };

  /// 「排序与筛选」里的「漫画下载」单选组（全部 / 已下载 / 未下载）。
  List<LibraryViewOption> _mangaDownloadFilterOptions() =>
      <LibraryViewOption>[
        for (final _MangaDownloadFilter? filter
            in <_MangaDownloadFilter?>[
              null,
              ..._MangaDownloadFilter.values,
            ])
          LibraryViewOption(
            key: ValueKey<String>(
              'shelf_filter_download_${_mangaDownloadFilterKey(filter)}',
            ),
            label: filter == null
                ? t.home_filter_all
                : _mangaDownloadFilterLabel(filter),
            selected: filter == _mangaDownloadFilter,
            onSelected: () => _setMangaDownloadFilter(filter),
          ),
      ];

  /// 排序按钮的筛选标记：阅读状态或漫画下载任一生效。
  bool get _sortFilterActive =>
      _readStatusFilter != null || _mangaDownloadFilter != null;

  /// 一部漫画参与搜索的全部字段（ticket 06）：
  /// 显示标题、原始标题、作者行（作者优先、画师兜底）、源分类、简介。
  ///
  /// 用户标签**刻意不参与**——标签已经是独立页签。本地图源没有源分类 / 简介，
  /// 只会命中标题与作者。字段来源：`MediaItem`（标题 / 编辑过的作者）+
  /// [_loadShelfMaps] 预取的描述符（在线条目的源分类 / 简介 / 源作者行）。
  List<String> _mangaSearchTexts(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final _MangaShelfMeta? meta =
        bookKey == null ? null : _mangaMetaByBookKey[bookKey];
    final OnlineMangaLibraryEntry? entry =
        meta?.onlineEntry ??
        OnlineMangaLibraryEntry.tryParse(item.sourceMetadata);
    final String? itemAuthor = item.author?.trim();
    final String? metaAuthor = meta?.author?.trim();
    final String? byline = itemAuthor != null && itemAuthor.isNotEmpty
        ? itemAuthor
        : metaAuthor != null && metaAuthor.isNotEmpty
        ? metaAuthor
        : entry?.series.byline;
    final String? description = entry?.series.description?.trim();
    return <String>[
      mediaSource.getDisplayTitleFromMediaItem(item),
      item.title,
      if (byline != null && byline.isNotEmpty) byline,
      if (entry != null) ...entry.series.genreLabels,
      if (description != null && description.isNotEmpty) description,
    ];
  }

  /// 选中漫画页某个标签页签。
  void _selectMangaTagTab(MangaTabSelection selection) {
    if (ref.read(mangaTagTabSelectionProvider) == selection) return;
    ref.read(mangaTagTabSelectionProvider.notifier).state = selection;
  }

  String _readStatusLabel(ShelfReadStatus status) => switch (status) {
        ShelfReadStatus.unread => t.shelf_filter_read_status_unread,
        ShelfReadStatus.reading => t.shelf_filter_read_status_reading,
        ShelfReadStatus.finished => t.shelf_filter_read_status_finished,
      };

  /// 层次 C：`'mediaType|entryKey' → 该条目在其主折叠合集里的 sortIndex`（组内序
  /// 真相源，与详情页 `getCollectionItems` 同源）。
  Map<String, int> _memberSortIndex = const <String, int>{};

  /// 「导入时间」排序用：epub bookKey → importedAt 毫秒（MediaItem 不携带导入
  /// 时间；SRT 卡的 SrtBook 自带）。
  Map<String, int> _epubImportedAtByKey = const <String, int>{};

  /// v82：epub bookKey → 稳定 uid（[bookLastReadAtProvider] 的键换算表，与
  /// [_epubImportedAtByKey] 同批预取）。v83 起同时是合集域的换算表：成员表
  /// epub entryKey = uid，页面身份（选择键/MediaItem）仍是 bookKey，查归属映射
  /// 或落 addToCollection 前都经此表单向换算。
  Map<String, String> _epubUidByKey = const <String, String>{};

  /// 已标记「读完」的书 bookKey 集合（EpubBooks.completedAt 非 null 的单一真值）。
  /// EPUB 小说卡按自身 bookKey、有声书 SRT 卡按其配对 bookKey 命中同一集合，供概览
  /// 「Completed」统计、卡片完成视觉、菜单「标记/取消」标签联动。随 [_loadShelfMaps]
  /// 一次性预取，手动切换或删书后 `_shelfMapsFuture = _loadShelfMaps()` 重取。
  Set<String> _completedBookKeys = const <String>{};

  /// 漫画卡右上角未读章节数（bookKey → 未读章数；0 未读不出现）。随
  /// [_loadShelfMaps] 用一次批量快照算好，卡片渲染只查这张内存表——滚动路径上
  /// 不逐卡查库、不逐卡探测文件。刷新时机与 [_completedBookKeys] 完全相同：
  /// 阅读器关闭 / 批量标记已读 / 从作品页返回。
  Map<String, int> _mangaUnreadCountsByBookKey = const <String, int>{};

  RemoteBookClient? _remoteBookClient;

  /// 远端清单的共享 TTL 缓存（BUG-1180）。与视频页 / 首页 dashboard 同一实例
  /// （app 级 provider），所以「首页刚拉过书列表、切到书架」不会再问对端要一次。
  RemoteLibraryCache get _remoteCache => ref.read(remoteLibraryCacheProvider);

  /// 上一次取数时 [_shouldLoadRemoteBooks] 的值（BUG-1182）。null = 还没取过。
  /// 用于识别「显示远端条目」开关翻转，翻转时重新取数。
  bool? _remoteGateAtLastLoad;

  /// 上次取远端列表时的「仅从本机移除」清单签名（见 [_onPrefsChangedForRemoteGate]）。
  String _hiddenRemoteBooksAtLastLoad = '';

  // 远端书 / 纯 SRT 有声书的下载进度与失败态不再挂本页 State（旧
  // `_downloadingBooks` 已删，BUG-1561 书侧补齐）：任务活在 app 级
  // InterconnectDownloadManager，占位卡经 _remoteBookTaskBadge 按任务状态渲染。

  /// 正在下载有声书包的本地书（key = 导入后的本地 bookKey，BUG-990）。远端有声书
  /// 走「先下 EPUB 后下有声书」两阶段：EPUB 一落库，书架 provider 自动刷新把远端占位
  /// 卡（带下载转圈）顶替成本地卡，此刻有声书还没落库 → 本地卡若无指示就露出「无转圈
  /// 的普通书」。下载有声书期间把本地 bookKey 记进这里，本地 EPUB 卡 / SRT 卡据此继续
  /// 显示加载覆盖层，直到有声书下完（成功或失败都在 finally 清除）。
  final Set<String> _downloadingAudiobookKeys = <String>{};

  /// 已在本机落地、但远端清单还没按新本地状态重新去重的对端书（键 =
  /// [RemoteBookInfo.downloadId]，BUG-3452）。渲染时跳过它们的占位卡；由
  /// [_onRemoteBookLanded] 写入，那一轮远端清单回来后摘除。
  final Set<String> _landedRemoteDownloadIds = <String>{};

  /// 本地卡在「有声书还在下」时叠的居中加载覆盖层（BUG-990）；[bookKey] 不在下载集合
  /// 时返回 null（不叠）。
  Widget? _audiobookDownloadingOverlay(String? bookKey) {
    if (bookKey == null || !_downloadingAudiobookKeys.contains(bookKey)) {
      return null;
    }
    return RemoteDownloadProgressBadge(
      key: ValueKey<String>('audiobook_downloading_$bookKey'),
      progress: null,
      tooltip: t.remote_book_downloading,
    );
  }

  double _gridExtent(BuildContext context, BoxConstraints constraints) {
    return readerShelfGridExtentForLayout(
      mediaWidth: MediaQuery.sizeOf(context).width,
      contentWidth: constraints.maxWidth,
    );
  }

  void _refreshSrtBooks() {
    ref.invalidate(srtBooksProvider);
    _batchAudiobookInfoFuture = null;
    _batchAudiobookInfoResult = const {};
    _refreshRemoteBooks();
  }

  void _toggleSelectionMode() {
    setState(_selection.toggleMode);
  }

  void _exitSelectionMode() {
    setState(_selection.exit);
  }

  /// 散卡点击：普通点击切换 + 设锚点，Shift + 点击选中锚点到该卡的可见区间。
  void _toggleSelection(String key) {
    setState(() => _selection.applyTap(
          SelectionSlot.loose(key),
          selectionTapKind(),
        ));
  }

  /// 桌面 Ctrl/⌘/Shift + 点击：直接进入多选并选中该项。
  /// 触屏（含外接键盘）只允许从明确的「选择」入口进入。
  void _enterSelectionWith(SelectionSlot slot) {
    setState(() => _selection.enterWith(slot));
  }

  /// 散卡组的多选键（与 [_selectAll] 同一套：EPUB 用 `mediaIdentifier`、SRT 用
  /// `srt_` 前缀 uid；远端占位卡用 [_remoteBookSelectionKey] /
  /// [_remoteSrtSelectionKey]）。
  ///
  /// BUG-2458：远端占位卡此前返回 null = 不可多选，多选态点云书直接开下载。远端
  /// 键与本地键同住一个选中集（卡片勾选态 / 计数 / Shift 区间选 / 长按扫选全复用），
  /// 只在批量动作那层按 [_isRemoteSelectionKey] 分流：本地三动作只吃本地键；
  /// 「下载」只吃远端**漫画**键（纯 SRT 有声书与非漫画远端书在下载执行 / 可用态
  /// 里被排除，ticket 02 复审 B）。
  String? _looseSelectionKey(_ShelfBookSlot slot) {
    final MediaItem? epub = slot.epub;
    if (epub != null) return epub.mediaIdentifier;
    final SrtBook? srt = slot.srt;
    if (srt != null) return 'srt_${srt.uid}';
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _remoteBookSelectionKey(remote);
    final RemoteAudiobookInfo? remoteSrt = slot.remoteSrt;
    if (remoteSrt != null) return _remoteSrtSelectionKey(remoteSrt);
    return null;
  }

  /// 选中集里的本地条目键（EPUB / SRT）：组合 / 打标签 / 删除三个本地动作的输入。
  Set<String> get _selectedLocalKeys => <String>{
        for (final String key in _selectedKeys)
          if (!_isRemoteSelectionKey(key)) key,
      };

  /// 选中集里的远端占位键：批量「下载」的输入。
  Set<String> get _selectedRemoteKeys => <String>{
        for (final String key in _selectedKeys)
          if (_isRemoteSelectionKey(key)) key,
      };

  @override
  void initState() {
    super.initState();
    mediaType.tabRefreshNotifier.addListener(_reloadShelfMapsOnTabRefresh);
    // BUG-992：顶层 tab IndexedStack 保活（BUG-750）后，切回书架不再隐式重拉远端书 →
    // 远端占位卡 + 书库概览总数要等用户手动下拉刷新才补齐。监听全局 tab 信号，切回
    // 书架 tab 时自动重拉一次远端（缓存 _lastRemoteState 顶住 waiting、不闪屏）。
    //
    // 互联完整支持批次：漫画实例现在也消费远端（远端漫画占位卡 + 漫画包下载），
    // 两个实例都订阅。BUG-1181 担心的重复网络由共享 TTL 清单缓存（BUG-1180）吸收，
    // 两个实例命中同一份清单。
    homeShellTabNotifier.addListener(_onShellTabActivated);
    // BUG-1182：「显示远端条目」开关落在 prefsRepo（独立 ChangeNotifier），不经
    // AppModel 通知，本页不会因它重建 → 门控翻转后既不重取也不重渲染。显式订阅。
    // 用 appModelNoUpdate：initState 里读 appModel 会走 ref.watch，触发
    // 「initState 完成前依赖 InheritedWidget」断言。
    appModelNoUpdate.prefsRepo.addListener(_onPrefsChangedForRemoteGate);
    _hiddenRemoteBooksAtLastLoad = _hiddenRemoteBooksSignature();
    _readStatusFilter = ShelfReadStatus.values
        .asNameMap()[appModelNoUpdate.prefsRepo.shelfReadStatusFilterName];
    if (_mangaOnly) _watchMangaDownloadJobs();
  }

  /// 订阅漫画下载任务表。只在漫画书架；服务 / 数据库尚未就绪时跳过（书架页
  /// 建立时数据库已就绪，这里的兜底只防测试壳）。
  void _watchMangaDownloadJobs() {
    if (_mangaDownloadJobsWatch != null) return;
    if (!appModelNoUpdate.isDatabaseReady) return;
    _mangaDownloadJobsWatch = appModelNoUpdate.mangaDownloadService
        .watchJobs()
        .listen(
          (_) => unawaited(_refreshMangaDownloadedBookKeys()),
          onError: (Object error, StackTrace stack) {
            ErrorLogService.instance.log(
              'ReaderFushiHistoryPage.watchMangaDownloads',
              error,
              stack,
            );
          },
        );
  }

  /// 下载任务表变了：重算「已下载」集合（在线看 Download library，本地图源看
  /// 章节是否读得出来），随后重建页面让筛选结果与页签数量立即生效。
  ///
  /// 同一时刻只跑一轮，期间到达的通知合并成一次尾随重算；进度更新（签名不变）
  /// 直接跳过。
  Future<void> _refreshMangaDownloadedBookKeys() async {
    if (_mangaDownloadsRefreshing) {
      _mangaDownloadsRefreshQueued = true;
      return;
    }
    _mangaDownloadsRefreshing = true;
    try {
      do {
        _mangaDownloadsRefreshQueued = false;
        final MangaDownloadService downloads =
            appModelNoUpdate.mangaDownloadService;
        final List<MangaDownloadJobRow> jobs = await downloads.listJobs();
        final String signature = <String>[
          for (final MangaDownloadJobRow job in jobs)
            '${job.jobId}:${job.status}',
        ].join('|');
        if (signature == _mangaDownloadJobsSignature) break;
        _mangaDownloadJobsSignature = signature;
        final Set<String> downloaded = await computeMangaShelfDownloadedBookKeys(
          _mangaChapterSources,
          database: appModelNoUpdate.database,
          localSourceRoot: appModelNoUpdate.appPathsOrNull?.localComicRoot,
          downloadsRoot: appModelNoUpdate.appPathsOrNull?.downloadsRoot,
        );
        if (!mounted) return;
        final bool changed =
            downloaded.length != _mangaDownloadedBookKeys.length ||
            !downloaded.containsAll(_mangaDownloadedBookKeys);
        if (changed) {
          setState(() => _mangaDownloadedBookKeys = downloaded);
        }
      } while (_mangaDownloadsRefreshQueued);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'ReaderFushiHistoryPage.refreshMangaDownloads',
        error,
        stack,
      );
    } finally {
      _mangaDownloadsRefreshing = false;
    }
  }

  /// prefsRepo 变更回调：只关心「显示远端条目」门控是否翻转（BUG-1182）。其余偏好
  /// 变动一概忽略——prefsRepo 的通知很频繁，不能每次都去动远端 future。
  ///
  /// 翻转时只触发一次重建，真正的重新取数交给 build 里那段门控比对（单一路径，避免
  /// 这里和 build 各自重取一遍）。
  void _onPrefsChangedForRemoteGate() {
    if (!mounted) return;
    // 「仅从本机移除」清单变了（隐藏 / 撤销 / 找回列表里恢复）：重取远端列表。
    final String hidden = _hiddenRemoteBooksSignature();
    if (hidden != _hiddenRemoteBooksAtLastLoad) {
      _hiddenRemoteBooksAtLastLoad = hidden;
      _refreshRemoteBooks();
      return;
    }
    if (_remoteGateAtLastLoad == null) return;
    if (_remoteGateAtLastLoad == _shouldLoadRemoteBooks) return;
    _rebuild(() {});
  }

  /// 隐藏清单的比对签名（偏好通知很频繁，只在清单真变时重取）。
  String _hiddenRemoteBooksSignature() => <String>[
        for (final HiddenRemoteBook h
            in appModelNoUpdate.prefsRepo.hiddenRemoteBooks)
          h.key,
      ].join('|');

  /// 切回书架 tab 时自动重拉远端书（BUG-992）。非书架 tab 的切换忽略。
  void _onShellTabActivated() {
    if (!mounted) return;
    if (homeShellTabNotifier.value == HomeTab.books) {
      _refreshRemoteBooks();
    }
  }

  /// tabRefreshNotifier 回调：重载书架合集折叠映射。后台合集同步（仅
  /// collectionsUpdated>0）现也触发 refreshTab（[AppModel.refreshAfterSyncRun]），
  /// 落到这里重载 _shelfMapsFuture，让新同步进来的合集成员立即成组。
  void _reloadShelfMapsOnTabRefresh() {
    if (!mounted) return;
    // 同步拉回对端更远的阅读进度（localBookProgressPulled>0 同样走 refreshTab）
    // 时，书列表 / 最近阅读时刻 provider 的缓存也必须失效——否则书架进度条与
    // 「最近阅读」排序停在旧值，要下拉刷新或重启才对（BUG-686 只修了触发信号，
    // 消费端一直没接上这两个缓存）。
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(bookLastReadAtProvider);
    setState(() {
      _shelfMapsFuture = _loadShelfMaps();
    });
  }

  @override
  void dispose() {
    _claimedChromeTabs?.release(this);
    _headerSearch.dispose();
    _searchController.dispose();
    _shelfScrollController.dispose();
    unawaited(_mangaDownloadJobsWatch?.cancel());
    _mangaDownloadJobsWatch = null;
    mediaType.tabRefreshNotifier.removeListener(_reloadShelfMapsOnTabRefresh);
    homeShellTabNotifier.removeListener(_onShellTabActivated);
    appModelNoUpdate.prefsRepo.removeListener(_onPrefsChangedForRemoteGate);
    assert(() {
      ReaderFushiHistoryPage.debugOpenBook = null;
      return true;
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 读到末尾阅读器写 completedAt、关书时该 provider 失效：同步本页的读完集，
    // 「继续阅读」才会跳过刚读完的那本。
    ref.listen<AsyncValue<Set<String>>>(completedEpubBookKeysProvider, (
      _,
      AsyncValue<Set<String>> next,
    ) {
      final Set<String>? keys = next.valueOrNull;
      if (keys != null) _completedBookKeys = keys;
    });
    final AsyncValue<List<MediaItem>> books =
        ref.watch(fushiBooksProvider(JapaneseLanguage.instance));
    assert(() {
      ReaderFushiHistoryPage.debugOpenBook = (String mediaId) async {
        final List<MediaItem> items = ref
                .read(fushiBooksProvider(JapaneseLanguage.instance))
                .valueOrNull ??
            const <MediaItem>[];
        MediaItem? target;
        for (final MediaItem m in items) {
          if (m.mediaIdentifier == mediaId) {
            target = m;
            break;
          }
        }
        if (target == null) {
          return;
        }
        await appModel.openMedia(
          ref: ref,
          mediaSource: target.getMediaSource(appModel: appModel),
          item: target,
        );
      };
      return true;
    }());
    // 漫画页的标签筛选是独立的单选页签（书架 + 用户标签），与共享的彩色多选
    // selectedTagIdsProvider 无关；其他媒体库继续走 filteredBookIdsProvider。
    final AsyncValue<Set<String>?> filteredIds = _mangaOnly
        ? const AsyncData<Set<String>?>(null)
        : ref.watch(filteredBookIdsProvider);
    final allTags = ref.watch(allTagsProvider);
    final List<BookTagRow> allTagRows =
        allTags.valueOrNull ?? const <BookTagRow>[];
    final Map<String, List<BookTagRow>> mangaTagMap = _mangaOnly
        ? ref.watch(bookTagMapProvider).valueOrNull ??
            const <String, List<BookTagRow>>{}
        : const <String, List<BookTagRow>>{};
    final MangaTabSelection requestedMangaTagTab = _mangaOnly
        ? ref.watch(mangaTagTabSelectionProvider)
        : const MangaShelfTabSelection();
    // 选中的标签可能刚在标签管理页被删除：本帧按「书架」渲染，并顺手把状态修回去。
    final bool mangaTagTabExists = switch (requestedMangaTagTab) {
      MangaShelfTabSelection() => true,
      MangaTagTabSelection(:final int tagId) =>
        allTagRows.any((BookTagRow tag) => tag.id == tagId),
    };
    final MangaTabSelection mangaTagTab = mangaTagTabExists
        ? requestedMangaTagTab
        : const MangaShelfTabSelection();
    if (!mangaTagTabExists) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted) return;
        if (ref.read(mangaTagTabSelectionProvider) == requestedMangaTagTab) {
          ref.read(mangaTagTabSelectionProvider.notifier).state =
              const MangaShelfTabSelection();
        }
      });
    }
    _mangaTagTabSelection = mangaTagTab;
    // 页签数量只基于已加载的书架条目计算；搜索 / 阅读状态 / 漫画下载筛选在
    // [_mangaItemPassesActiveFilters] 里统一生效（与正文渲染同一判据）。
    final List<MediaItem> mangaBooksForTabs =
        _mangaOnly && books.valueOrNull != null
            ? filterShelfEntriesByMangaSplit(
                books.valueOrNull!,
                mangaOnly: true,
              )
            : const <MediaItem>[];
    _mangaTagTabCounts = _mangaOnly
        ? countMangaTagTabItems(
            mangaBooksForTabs,
            bookKeyOf: (MediaItem item) =>
                _parseBookKey(item.mediaIdentifier),
            tagMap: mangaTagMap,
            tagIds: <int>{for (final BookTagRow tag in allTagRows) tag.id},
            visible: _mangaItemPassesActiveFilters,
          )
        : const <MangaTabSelection, int>{};
    // 漫画页在库页壳里时，视图页签位由标签页签胶囊取代：页签位是壳画的，标签
    // 数据与交互在本书架里，所以像页头动作一样把标签行登记给壳。
    final MediaLibraryChromeTabsSlot? chromeTabs = _mangaOnly
        ? MediaLibraryShellScope.maybeOf(context)?.chromeTabsSlot
        : null;
    // 搜索展开且已有关键词时，chrome 页签位整行被搜索栏取代；此时再登记标签
    // 胶囊会让外壳在每次输入后重建 chrome 行，打断正在输入的搜索框焦点
    // （用户实报「第一次输入就失焦」）。收起/清空后恢复登记。
    if (!(_mangaOnly && _headerSearch.hasQuery)) {
      _syncChromeTabsClaim(chromeTabs, allTagRows);
    }

    // BUG-250: 书架批量选择模式（[_selectionMode]）活在本 tab 内容里，不是独立
    // route。顶层 HomePage 的 PopScope 对它无感，返回键会直接弹掉 root route 退
    // 出 App，而不是退出选择模式。这里像查词 tab（home_dictionary_page）一样用
    // 嵌套 PopScope 拦截：选择模式开启时 canPop=false，返回先退出选择模式。
    // 只在书架所在分区可见时拦（HBK-AUDIT-017）：停在「发现」等视图时，背后保活
    // 的书架多选不能吃掉返回键。
    return SectionPopScope(
      intercepting: _selectionMode,
      onIntercept: _exitSelectionMode,
      child: FushiFileDropTarget(
        debugLabel: 'reader-shelf',
        onDrop: _handleShelfDrop,
        child: CardDropScope<String>(
          registry: _cardDropRegistry,
          child: DesktopContentLayout(
            kind: DesktopContentKind.readerShelf,
            child: Column(
              children: [
                // 页头 / 搜索筛选行 / 标签行（连同同步横幅）与库页外壳的浮动
                // 工具栏是同一组工具区：往下滚一起收起、往上滚一起弹回（同一个
                // [FushiFloatingChromeController]，与视频库同构）。工具区叠在
                // 正文上，收起只滑出画面、不改正文视口高度（BUG-2975）；正文主
                // 滚动视图把 [FushiFloatingChromeInset] 加成顶部内边距。不在外壳
                // 里时原样常驻（竖排）。
                Expanded(
                  child: FushiFloatingChromeOverlay(
                    chrome: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        // 单行页头（2026-10-14）：页签 + 右侧 🔍 / 多选 / 排序 /
                        // 管理标签，搜索点开整行换成搜索栏。漫画页的页签位已换成
                        // 漂浮 chrome 行里的 Tag chips（ticket 06），标题下不再
                        // 单独占一行；其余库页照旧在页头下画标签行。Cupertino
                        // 旧版面保留常驻搜索行，标签 chip 不再重复嵌进工具栏。
                        if (!isCupertinoPlatform(context)) ...<Widget>[
                          _buildPageHeader(),
                          _buildSortMenuAnchor(allTagRows),
                          if (chromeTabs == null) _buildTagBar(allTagRows),
                        ] else ...<Widget>[
                          // 漫画页的标签栏是独立的单选页签胶囊，不再并进 legacy
                          // 工具行的「多选标签」菜单；其他媒体库保持原菜单。
                          _buildSearchBar(
                            allTagRows,
                            hideTagChips: chromeTabs != null || _mangaOnly,
                          ),
                          if (_mangaOnly && chromeTabs == null)
                            _buildTagBar(allTagRows),
                        ],
                        // 下拉同步可能跑几十秒，光一个转圈看不出进展；没同步在飞时
                        // 零高度。
                        SyncProgressBanner(compact: _compactLibraryToolbar),
                      ],
                    ),
                  // 多选态才接管长按：长按落在卡上 = 起手扫选，不抬手滑动即刷出
                  // 一段区间。非多选态原样透传（长按仍归卡片自身的菜单）。
                  child: SelectionDragArea(
                    enabled: _selectionMode,
                    onDragBegin: (SelectionSlot slot) =>
                        setState(() => _selection.beginRangeDrag(slot)),
                    onDragUpdate: (SelectionSlot slot) =>
                        setState(() => _selection.updateRangeDrag(slot)),
                    onDragEnd: () => setState(_selection.endRangeDrag),
                    child: books.when(
                      // BUG-3337：书集合一变（下载 / 导入落库）fushiBooksProvider
                      // 就因依赖变化重算，AsyncValue 进 reload 态。默认
                      // skipLoadingOnReload=false 会把整个网格换成转圈再换回来——
                      // CustomScrollView 被卸掉重建，滚动位置归零跳回顶部，卡片
                      // 错峰进场再放一遍（用户：「整个书架刷新回流重排、回到顶部」）。
                      // 重算期间留着旧数据，新数据到了原地替换对应条目。
                      skipLoadingOnReload: true,
                      data: (bookList) {
                        _batchAudiobookInfoFuture ??= _mangaOnly
                            ? Future<Map<String, _AudiobookInfo>>.value(
                                const <String, _AudiobookInfo>{},
                              )
                            : _loadAllAudiobookInfo();
                        // BUG-1182：「显示远端条目」门控已前移进 _loadRemoteBooks
                        // （关掉就不联网，而不是拉完再丢）。开关从关翻到开时 `??=` 不会
                        // 重跑，故这里显式比对上轮门控值，翻转时重新取数——否则用户在设置
                        // 里打开开关后要下拉刷新才看得到远端卡。
                        if (_remoteGateAtLastLoad != null &&
                            _remoteGateAtLastLoad != _shouldLoadRemoteBooks) {
                          _remoteBooksFuture = null;
                        }
                        _remoteGateAtLastLoad = _shouldLoadRemoteBooks;
                        _remoteBooksFuture ??= _loadRemoteBooks();
                        _shelfMapsFuture ??= _loadShelfMaps();
                        final List<MediaItem> shelfBooks =
                            filterShelfEntriesByMangaSplit(
                          bookList,
                          mangaOnly: _mangaOnly,
                        );
                        _mangaShelfUnfilteredNonEmpty = shelfBooks.isNotEmpty;
                        final Set<String>? filterSet = filteredIds.valueOrNull;
                        List<MediaItem> filtered;
                        if (_mangaOnly) {
                          // 排他归属：书架 = 无任何标签；标签页签 = 带该标签。
                          // 与页签数量共用 [mangaBookBelongsToTab]。
                          final MangaTabSelection selectedTab =
                              _mangaTagTabSelection;
                          filtered = shelfBooks.where((MediaItem item) {
                            final String? key =
                                _parseBookKey(item.mediaIdentifier);
                            final List<BookTagRow>? tags =
                                key == null ? null : mangaTagMap[key];
                            return mangaBookBelongsToTab(tags, selectedTab);
                          }).toList();
                        } else if (filterSet == null) {
                          filtered = shelfBooks;
                        } else {
                          filtered = shelfBooks.where((item) {
                            final String? key =
                                _parseBookKey(item.mediaIdentifier);
                            if (key == null) return false;
                            return filterSet.contains(key);
                          }).toList();
                        }
                        // P5-A：搜索按**显示名 + DB 原名**双口径匹配——改过名的书
                        // 用户既可能记得新名也可能记得旧名，只匹配其一都会「搜不到
                        // 明明在书架上的书」。归一化走与游戏库页同一份
                        // [matchesMediaSearch]（全角/片假名/标点折叠）。
                        //
                        // 漫画页（ticket 06）搜索扩围到作者 / 源分类 / 简介，且需要
                        // [_loadShelfMaps] 预取的描述符——统一在正文的
                        // buildBody（`_shelfMapsFuture` 完成后）经
                        // `_mangaItemPassesActiveFilters` 应用，这里不再先裁一刀。
                        if (!_mangaOnly && _searchQuery.trim().isNotEmpty) {
                          filtered = filtered.where((MediaItem item) {
                            return _matchesShelfSearch(<String>[
                              ReaderFushiSource.instance
                                  .getDisplayTitleFromMediaItem(item),
                              item.title,
                            ]);
                          }).toList();
                        }
                        return FutureBuilder<Map<String, _AudiobookInfo>>(
                          future: _batchAudiobookInfoFuture,
                          builder: (context, abSnapshot) =>
                              FutureBuilder<_RemoteBookState?>(
                            future: _remoteBooksFuture,
                            builder: (context, remoteSnapshot) =>
                                FutureBuilder<void>(
                              future: _shelfMapsFuture,
                              builder: (context, _) =>
                                  buildBody(filtered, remoteSnapshot),
                            ),
                          ),
                        );
                      },
                      error: (error, stack) => FushiFloatingChromeInsetPadding(
                        child: buildError(
                        error: error,
                        stack: stack,
                        refresh: () {
                          _refreshSrtBooks();
                          ref.invalidate(
                            fushiBooksProvider(JapaneseLanguage.instance),
                          );
                        },
                      ),
                      ),
                      // BasePage 家族历史样式（25×25 主色圈），参数化保留、视觉不变。
                      loading: () => FushiFloatingChromeInsetPadding(
                        child: buildLoading(
                            size: 25, color: theme.colorScheme.primary),
                      ),
                    ),
                  ),
                  ),
                ),
                // 批量栏是多选态的底部浮动工具栏：弹簧从底边浮起 / 沉下；
                // 退出多选后沉下去的那一程还画着上一帧的批量栏（只是不再接
                // 指针），沉到底才卸掉（容器见 [BatchActionBarHost]）。
                BatchActionBarHost(
                  visible: _selectionMode,
                  builder: (BuildContext context) => _buildBatchActionBar(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 上次登记页签位内容的壳槽（换槽 / 卸载时先撤回旧登记）。
  MediaLibraryChromeTabsSlot? _claimedChromeTabs;

  /// 把标签页签胶囊登记到壳的视图页签位（漫画页）。独立使用（无壳）时不登记，
  /// 页签行仍在标题下自成一行。`inlineTags` 去掉行内页边，让胶囊从页签原来的
  /// 左缘开始、高度与浮动 chrome 行一致。
  void _syncChromeTabsClaim(
    MediaLibraryChromeTabsSlot? slot,
    List<BookTagRow> allTags,
  ) {
    if (!identical(_claimedChromeTabs, slot)) {
      _claimedChromeTabs?.release(this);
      _claimedChromeTabs = slot;
    }
    if (slot == null) return;
    slot.claim(
      this,
      // 可见 = 没被保活外壳停帧且所在分区在台上（与页头动作登记同一判据）。
      visible:
          TickerMode.valuesOf(context).enabled && SectionVisibility.of(context),
      content: _buildTagBar(allTags, inlineTags: true),
    );
  }

  bool get _compactLibraryToolbar =>
      windowSizeClassReal(
        MediaQuery.sizeOf(context).width,
        FushiAppUiScale.of(context),
      ) ==
      WindowSizeClass.compact;

  /// [part]：工具行行尾的「管理标签 / 批量选择 / 排序」（[FushiTagFilterBarPart.actions]，
  /// 窄屏用 44 触控尺寸；管理标签常驻，key `library_tag_settings`）或工具行下方的
  /// 标签 chip 段（无标签时零高度）。
  Widget _buildTagBar(
    List<BookTagRow> allTags, {
    FushiTagFilterBarPart part = FushiTagFilterBarPart.tags,
    bool tagsInMenu = false,
    bool inlineTags = false,
  }) {
    // 漫画页用单选分段胶囊（书架 + 用户标签），共享彩色多选 chip 只服务其他媒体
    // 库。动作段（actions）仍是共享动作组，页头「管理标签」入口不受影响。
    if (_mangaOnly &&
        (part == FushiTagFilterBarPart.tags ||
            part == FushiTagFilterBarPart.full)) {
      return MangaTagTabBar(
        key: const ValueKey<String>('manga_tag_tab_bar'),
        tags: allTags,
        selection: _mangaTagTabSelection,
        counts: _mangaTagTabCounts,
        inline: inlineTags,
        onSelected: _selectMangaTagTab,
      );
    }
    return FushiTagFilterBar(
      tags: allTags,
      part: part,
      tagsInMenu: tagsInMenu,
      inlineTags: inlineTags,
      pinActions: _compactLibraryToolbar,
      onToggleFilter: _toggleFilter,
      onReorder: _reorderTags,
      selectionMode: _selectionMode,
      onToggleSelectionMode: _toggleSelectionMode,
      // 排序交互重设计层次 A：「排序方式」菜单（原「整理」按钮位置；整理页已删）。
      // 分组管理走批量「组合成合集」+ 合集详情页（改名/删除/移出成员/一键排序）。
      sortMode: _sortMode,
      sortModeLabel: _sortModeLabel,
      onSortModeChanged: _setSortMode,
      // 「阅读状态」单选组（原工具行上的下拉 chip，2026-10-10 用户：「阅读状态
      // 下拉框放在排序那」）。持久化仍是 `shelf_read_status_filter`；生效时排序
      // 按钮亮圆点。
      filterOptionsTitle: t.shelf_filter_read_status,
      filterActive: _sortFilterActive,
      filterOptions: _readStatusFilterOptions(),
      // 漫画页在「阅读状态」之后再挂一组「漫画下载」；其他媒体库不传。
      secondaryFilterOptionsTitle: _mangaOnly ? t.shelf_filter_download : null,
      secondaryFilterOptions: _mangaOnly
          ? _mangaDownloadFilterOptions()
          : const <LibraryViewOption>[],
      onTagsChanged: () => ref.invalidate(bookTagMapProvider),
    );
  }

  /// 「排序与筛选」菜单的零尺寸常驻锚点（贴在页头下沿右侧）：页头里的排序
  /// 按钮可能被收进「⋯」，菜单挂在这里才总能打开。
  Widget _buildSortMenuAnchor(List<BookTagRow> allTags) {
    return Align(
      alignment: AlignmentDirectional.topEnd,
      child: Padding(
        padding: EdgeInsetsDirectional.only(
          end: FushiDesignTokens.of(context).spacing.page,
        ),
        child: FushiTagFilterBar(
          tags: allTags,
          part: FushiTagFilterBarPart.sortMenuAnchor,
          sortMenuController: _sortMenu,
          onToggleFilter: _toggleFilter,
          onReorder: _reorderTags,
          sortMode: _sortMode,
          sortModeLabel: _sortModeLabel,
          onSortModeChanged: _setSortMode,
          filterOptionsTitle: t.shelf_filter_read_status,
          filterActive: _sortFilterActive,
          filterOptions: _readStatusFilterOptions(),
          secondaryFilterOptionsTitle: _mangaOnly
              ? t.shelf_filter_download
              : null,
          secondaryFilterOptions: _mangaOnly
              ? _mangaDownloadFilterOptions()
              : const <LibraryViewOption>[],
        ),
      ),
    );
  }

  List<LibraryViewOption> _readStatusFilterOptions() => <LibraryViewOption>[
        for (final ShelfReadStatus? status in <ShelfReadStatus?>[
          null,
          ...ShelfReadStatus.values,
        ])
          LibraryViewOption(
            key: ValueKey<String>(
              'shelf_filter_read_status_${status?.name ?? 'all'}',
            ),
            label: status == null
                ? t.home_filter_all
                : _readStatusLabel(status),
            selected: status == _readStatusFilter,
            onSelected: () => _setReadStatusFilter(status),
          ),
      ];

  Widget _buildPageHeader() {
    final List<Widget> actions = <Widget>[
      // 原工具行行尾的「批量选择 / 排序与筛选 / 管理标签」并进页头（单行页头，
      // 2026-10-14），放不下时按优先级逐颗收进 ⋯：多选 > 排序 > 管理标签。
      ...libraryHeaderTagActions(
        context,
        ref: ref,
        sortMenu: _sortMenu,
        sortGrouped: true,
        sortFilterActive: _sortFilterActive,
        selectionMode: _selectionMode,
        onToggleSelectionMode: _toggleSelectionMode,
        onTagsChanged: () => ref.invalidate(bookTagMapProvider),
      ),
      // 单件导入入口已统一收敛到库页「导入」视图的快速导入区（书 / 漫画 / 视频 /
      // 游戏四域同位，2026-08-13 定案）；页头只在书架被**独立使用**（无导航壳、
      // 够不到「导入」视图）时保留导入按钮兜底。漫画和书籍载体不同，兜底按钮
      // 仍指向两个不同的对话框。
      if (_pageWidget.navigation == null)
        if (_mangaOnly)
          MangaFushiSource.instance.buildMangaImportButton(
            context: context,
            ref: ref,
            appModel: appModel,
            focusId: kShelfImportFocusId,
            label: t.manga_import_action,
          )
        else
          mediaSource.buildBookImportButton(
            context: context,
            ref: ref,
            appModel: appModel,
            focusId: kShelfImportFocusId,
            label: t.srt_import,
          ),
      // 书 / 漫画页头不再挂「全部刮削」（用户定案 2026-10-14：批量刮削只有视频
      // 和 galgame 需要，入口留在视频来源页与游戏库页）；单本封面刮削仍在卡片菜单。
      // 「管理来源」在库页导航壳里已是一等视图（[MediaSourcesPage]），页头再放一个
      // 按钮就是同一件事的两个入口。书架独立使用（无导航条）时才保留书籍来源按钮；
      // 漫画入口由专属导入对话框负责，不复用书籍来源管理。
      // 统计入口已收敛到首页 dashboard（用户定案 2026-09-01：各媒体页头不再
      // 各挂一个「xx统计」，统一从首页进统计中心）。收藏夹入口同理（用户定案
      // 2026-10-14）：收藏夹不按模块隔离，各库页都挂一个只会误导，统一从首页进。
    ];
    final Widget? navigation = _pageWidget.navigation;
    if (navigation != null) {
      return FushiPageHeader.customTitle(
        title: navigation,
        actions: actions,
        search: _headerSearch,
      );
    }
    return FushiPageHeader(
      title: _mangaOnly ? t.manga_library : t.books,
      actions: actions,
      search: _headerSearch,
    );
  }

  Widget _headerAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return FushiIconButton(
      tooltip: tooltip,
      // 页头动作宽窗展开文字（tooltip 即标签文案）；窄窗由组件自动回落纯图标。
      label: tooltip,
      icon: icon,
      onTap: onTap,
    );
  }

  /// 一次性预取书架排序所需映射：epub 导入时间、uid 换算、读完集合，
  /// 外加偏好里的排序方式。
  ///
  /// 2026-11-05：合集功能已删除，不再自动分卷、不再读取合集字典/成员序。
  Future<void> _loadShelfMaps() async {
    _sortMode = ShelfSortMode.fromName(appModel.prefsRepo.shelfSortModeName);
    final List<EpubBookMeta> epubRows =
        await appModel.database.getEpubBookMetas();
    _epubImportedAtByKey = <String, int>{
      for (final EpubBookMeta r in epubRows) r.bookKey: r.importedAt,
    };
    // v82：reader_positions 键 = uid；书架条目身份仍是 bookKey，查 recency 前
    // 经此表换算（同一批行零额外查询）。空 uid 行不进表（视同无阅读记录）。
    _epubUidByKey = <String, String>{
      for (final EpubBookMeta r in epubRows)
        if (r.uid.isNotEmpty) r.bookKey: r.uid,
    };
    _completedBookKeys = await appModel.database.getCompletedEpubBookKeys();
    // 漫画书架才需要未读角标 / 搜索元数据 / 下载状态；书籍 / 视频书架没有漫画卡，
    // 省掉这条快照查询。
    final MangaShelfReadSnapshot mangaSnapshot = _mangaOnly
        ? await appModel.database.getMangaShelfReadSnapshot()
        : const MangaShelfReadSnapshot(
            books: <MangaShelfChapterSource>[],
            readChapterKeysByBookUid: <String, Set<String>>{},
          );
    // 下载任务表变化（后台下载完成 / 取消）时，用这批章节来源行重算「已下载」
    // 集合，不必重跑整份书架映射。
    _mangaChapterSources = mangaSnapshot.books;
    _mangaUnreadCountsByBookKey = _mangaOnly
        ? computeMangaShelfUnreadCounts(mangaSnapshot)
        : const <String, int>{};
    _mangaMetaByBookKey = _mangaOnly
        ? <String, _MangaShelfMeta>{
            for (final MangaShelfChapterSource book in mangaSnapshot.books)
              book.bookKey: _MangaShelfMeta(
                author: book.author,
                onlineEntry: OnlineMangaLibraryEntry.tryParse(
                  book.sourceMetadata,
                ),
              ),
          }
        : const <String, _MangaShelfMeta>{};
    // 「漫画下载」筛选：在线看 Download library 至少一章完整落盘，本地图源看
    // 至少一章真的读得出来；Missing 不计。随本快照一次批量算好，卡片与页签
    // 数量只查内存集合。
    _mangaDownloadedBookKeys = _mangaOnly
        ? await computeMangaShelfDownloadedBookKeys(
            mangaSnapshot.books,
            database: appModel.database,
            localSourceRoot: appModel.appPathsOrNull?.localComicRoot,
            downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
          )
        : const <String>{};
    // 漫画页页签数量要按「阅读状态」筛选统计，读完集合是异步预取的；集合就绪后
    // 补一帧，让浮动 chrome 里的数量与正文同一口径（正文由 FutureBuilder 重建，
    // chrome 不在它下面）。
    if (mounted) setState(() {});
  }

  /// 用户切换排序方式：立即重排 + 偏好持久化（跨启动记住）。
  void _setSortMode(ShelfSortMode mode) {
    if (mode == _sortMode) return;
    setState(() => _sortMode = mode);
    unawaited(appModel.prefsRepo.setShelfSortModeName(mode.name));
  }

  /// P5-A 书架工具行：搜索框 + 行尾「管理标签 / 批量选择 / 排序」，与视频库 /
  /// 游戏库同一个 [LibraryToolbar]。搜索词只影响本次会话、不落库。
  ///
  /// 2026-10-10「库页顶部只留两行」：阅读状态并进排序菜单；标签 chip 宽屏嵌在
  /// 搜索框与行尾工具之间（[LibraryToolbar.wideMiddle]），窄屏放不下就收进
  /// 排序菜单（多选组）。两种布局下工具条都只有一行。宽窄判据与
  /// [LibraryToolbar] 自己的同一个（同一宽度、同一断点）。
  Widget _buildSearchBar(
    List<BookTagRow> allTags, {
    bool hideTagChips = false,
  }) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide =
            constraints.maxWidth >= LibraryToolbar.wideBreakpoint;
        return _buildToolbar(
          allTags,
          wide: wide,
          hideTagChips: hideTagChips,
        );
      },
    );
  }

  Widget _buildToolbar(
    List<BookTagRow> allTags, {
    required bool wide,
    bool hideTagChips = false,
  }) {
    final Widget actions = _buildTagBar(
      allTags,
      part: FushiTagFilterBarPart.actions,
      tagsInMenu: !wide && !hideTagChips,
    );
    return LibraryToolbar(
      wideMiddle: wide && !hideTagChips && allTags.isNotEmpty
          ? _buildTagBar(allTags, inlineTags: true)
          : null,
      search: LibrarySearchField(
        fieldKey: const ValueKey<String>('shelf_search_field'),
        controller: _searchController,
        hintText: t.library_search,
        onChanged: (String value) => setState(() => _searchQuery = value),
        onClear: () {
          _searchController.clear();
          setState(() => _searchQuery = '');
        },
      ),
      // 行尾：管理标签（常驻，key `library_tag_settings`）+ 批量选择 + 排序
      // （含阅读状态 / 窄屏标签筛选）。
      trailing: actions,
    );
  }

  String _sortModeLabel(ShelfSortMode mode) => switch (mode) {
        ShelfSortMode.recent => t.sort_recent_read,
        ShelfSortMode.title => t.sort_title,
        ShelfSortMode.imported => t.sort_imported,
      };

  /// 每本书（书稳定身份 → reader_positions.updatedAt 毫秒）的最后阅读时间；
  /// v82 起键 = epub uid（bookKey 经 [_epubUidByKey] 换算后查）。关书时经
  /// [ReaderFushiSource.onSourceExit] 与书列表同点失效（BUG-777）。
  Map<String, int> get _lastReadAtByBookKey =>
      ref.watch(bookLastReadAtProvider).valueOrNull ?? const <String, int>{};

  /// 单卡排序键。recentScore = 最后阅读时间（[_lastReadAtByBookKey]，EPUB/SRT
  /// 同走 bookKey），没读过退 importedAt——与视频页 watch-stats 语义镜像
  /// （BUG-777）；importedAt 走 [_epubImportedAtByKey] / SRT 行自带。
  ///
  /// title 必须是卡片上**显示**的名字（改名覆盖层 ?? 原名）：读 DB 原始列会让
  /// 改过名的条目按看不见的旧名参与「名称」排序（BUG-3337）。
  ///
  /// 2026-11-05：合集已删除，排序单元从「合集组/散卡」收敛为单卡。
  ShelfSortKey _shelfSlotSortKey(_ShelfBookSlot slot) {
    final String title;
    final int importedAt;
    final int recentScore;
    final String tieKey;
    final SrtBook? srt = slot.srt;
    final MediaItem? epub = slot.epub;
    final RemoteBookInfo? remote = slot.remote;
    final RemoteAudiobookInfo? remoteSrt = slot.remoteSrt;
    if (srt != null) {
      title = displayTitleForBook(
        bookKey: srt.bookKey.isNotEmpty ? srt.bookKey : null,
        srtUid: srt.uid,
        rawTitle: srt.title,
      );
      importedAt = srt.importedAt;
      recentScore = lastReadAtForBookKey(
              _lastReadAtByBookKey, _epubUidByKey, srt.bookKey) ??
          importedAt;
      tieKey = 'srt|${srt.uid}';
    } else if (epub != null) {
      final String? bookKey = _parseBookKey(epub.mediaIdentifier);
      title = displayTitleForBook(item: epub, rawTitle: epub.title);
      importedAt = bookKey == null ? 0 : (_epubImportedAtByKey[bookKey] ?? 0);
      recentScore = lastReadAtForBookKey(
              _lastReadAtByBookKey, _epubUidByKey, bookKey) ??
          importedAt;
      tieKey = 'epub|${bookKey ?? epub.mediaIdentifier}';
    } else if (remote != null) {
      title = remote.title;
      importedAt = remote.importedAt ?? 0;
      recentScore =
          remote.progressUpdatedAtMs > 0 ? remote.progressUpdatedAtMs : 0;
      tieKey = 'epub|${remote.downloadId}';
    } else {
      final RemoteAudiobookInfo r = remoteSrt!;
      title = r.title ?? r.identity;
      importedAt = r.importedAt ?? 0;
      recentScore = r.positionUpdatedAtMs > 0 ? r.positionUpdatedAtMs : 0;
      tieKey = 'srt|${r.identity}';
    }
    return ShelfSortKey(
      recentScore: recentScore,
      title: title,
      importedAt: importedAt,
      tieKey: tieKey,
    );
  }

  void _toggleFilter(int tagId) {
    final current = Set<int>.from(ref.read(selectedTagIdsProvider));
    if (current.contains(tagId)) {
      current.remove(tagId);
    } else {
      current.add(tagId);
    }
    ref.read(selectedTagIdsProvider.notifier).state = current;
  }

  Future<void> _reorderTags(int oldIndex, int newIndex) async {
    final tags = ref.read(allTagsProvider).valueOrNull;
    if (tags == null) return;
    final reordered = List<BookTagRow>.from(tags);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);
    final orderedIds = reordered.map((t) => t.id).toList();
    final bool ok = await reorderTagsSafely(
      write: () => ref.read(appProvider).database.reorderTags(orderedIds),
    );
    if (!ok) return;
    ref.invalidate(allTagsProvider);
  }

  /// 给某媒体（epub/srt/video）打标签的共用流程：已有则提示并返回；否则写 DB →
  /// 失效相关 provider → 成功提示。三种媒体只差「标签表 provider / DB 方法 / filtered
  /// provider / 成功文案」，作参数注入（[alreadyHas] 由各调用方按自己的标签 map 算好，
  /// [successMsg] 区分书籍 `tag_added_to_book` vs 视频 `tag_added_to_video`）。
  ///
  /// 「查重 → 幂等提示 → 落库 → 失败提示」收口在 [addTagToTarget]（永不抛）；这里
  /// 只留 widget 层该管的两件事：拿到 [TagAddOutcome.added] 才刷新，`mounted` 才报成功。
  Future<void> _addTagToMedia({
    required bool alreadyHas,
    required BookTagRow tag,
    required Future<void> Function() addToDb,
    required List<ProviderOrFamily> invalidate,
    required String successMsg,
  }) async {
    final TagAddOutcome outcome = await addTagToTarget(
      tag: tag,
      isAlreadyTagged: () async => alreadyHas,
      addToDb: addToDb,
      alreadyTaggedMessage: t.tag_already_on_book(name: tag.name),
    );
    if (outcome != TagAddOutcome.added) return;
    for (final ProviderOrFamily p in invalidate) {
      ref.invalidate(p);
    }
    if (mounted) {
      FushiToast.show(msg: successMsg, severity: ToastSeverity.success);
    }
  }

  Future<void> _addTagToBook(String bookKey, BookTagRow tag) async {
    final existing = ref.read(bookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[bookKey]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToBook(bookKey, tag.id),
      invalidate: <ProviderOrFamily>[
        bookTagMapProvider,
        filteredBookIdsProvider
      ],
      successMsg: t.tag_added_to_book(name: tag.name),
    );
  }

  Future<void> _addTagToSrtBook(String srtUid, BookTagRow tag) async {
    final existing = ref.read(srtBookTagMapProvider).valueOrNull;
    await _addTagToMedia(
      alreadyHas: existing?[srtUid]?.any((t) => t.id == tag.id) ?? false,
      tag: tag,
      addToDb: () =>
          ref.read(appProvider).database.addTagToSrtBook(srtUid, tag.id),
      invalidate: <ProviderOrFamily>[
        srtBookTagMapProvider,
        filteredSrtBookUidsProvider,
      ],
      successMsg: t.tag_added_to_book(name: tag.name),
    );
  }

  /// 某媒体卡上挂的标签列：标签 map 为空 / 该 key 无标签都返回 null，否则渲染
  /// [_adaptiveTagColumn]。三种媒体（epub/srt/video）只差「watch 哪个标签 provider +
  /// key 类型」，故各 caller 自己 `ref.watch(provider).valueOrNull`（保响应式订阅）后
  /// 把解析好的 map 传进来，空/列逻辑收口于此泛型 helper。
  Widget? _tagLabelsFromMap<K>(Map<K, List<BookTagRow>>? tagMap, K key) {
    if (tagMap == null) return null;
    final tags = tagMap[key];
    if (tags == null || tags.isEmpty) return null;
    return _adaptiveTagColumn(tags);
  }

  Widget? _buildTagLabels(String bookKey) =>
      _tagLabelsFromMap(ref.watch(bookTagMapProvider).valueOrNull, bookKey);

  Widget buildBody(
    List<MediaItem> books, [
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ]) {
    final List<SrtBook> srtBooks = _mangaOnly
        ? const <SrtBook>[]
        : ref.watch(srtBooksProvider).valueOrNull ?? const <SrtBook>[];
    return _buildBodyWithSrtBooks(books, srtBooks, remoteSnapshot);
  }

  /// UI v2：书架顶部「继续阅读 hero + 书库概览」条（对齐视频页）。
  ///
  /// 数据边界（诚实外显）：hero = 在读（0<position<duration）EPUB-backed 书中
  /// 「最后阅读时间」（[bookLastReadAtProvider]，即 reader_positions.updatedAt）
  /// 最新者，显示「已读 x%」；无候选整块隐藏。BUG-777：旧实现取列表第一本
  /// 在读书，但列表序 = getAllEpubBooks 的 importedAt 倒序，选中的是「最近导入」
  /// 而非「最近阅读」的书。
  ///
  /// BUG-804：[progressBooks] 必须是**未按 srt 过滤的全量 EPUB-backed 列表**
  /// （`fushiBooksProvider` 全部行，含有声书——EPUB 正文 + SRT 字幕同 bookKey）。
  /// 旧实现只喂 srt 过滤后的 `epubBooks`，有声书虽有进度与 lastReadAt 却被整类
  /// 排除，读了有声书回书架「继续阅读」永不更新。过滤到纯 EPUB 只为主网格卡
  /// 去重（有声书渲染成 SRT 卡），与 hero 无关。
  ///
  /// 原并排的「统计」三格（总数/在读/已完成，BUG-991 的口径修正随之退役）已按
  /// 用户反馈移除——与右上角「阅读统计」入口重复。
  Widget _buildShelfOverviewSection(List<MediaItem> progressBooks) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ShelfProgressTally<MediaItem> tally = tallyShelfProgress<MediaItem>(
      progressBooks,
      (MediaItem item) => item.position,
      (MediaItem item) => item.duration,
      // 与阅读状态筛选同一判据：标了读完的书不再当「在读」顶进继续阅读。
      isCompleted: (MediaItem item) =>
          _completedBookKeys.contains(_parseBookKey(item.mediaIdentifier)),
    );
    final MediaItem? hero = pickShelfContinueHero(
      tally.inProgress,
      // BUG-2904：映射键是 uid，bookKey 必须经换算表一跳（与「最近阅读」排序同）。
      (MediaItem item) => lastReadAtForBookKey(
        _lastReadAtByBookKey,
        _epubUidByKey,
        _parseBookKey(item.mediaIdentifier),
      ),
    );
    if (hero == null) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.card,
        tokens.spacing.gap,
        tokens.spacing.card,
        0,
      ),
      child: _buildContinueReadingHero(hero, tokens),
    );
  }

  /// 继续阅读 hero（2026-10 书架重设计，M3 Expressive / Apple 两套）：封面走共享
  /// [ShelfCoverFrame]（圆角 + 投影 / Apple 内描边），右侧「继续阅读」小标题 +
  /// 书名 + 进度条（共享 [FushiLinearProgressIndicator]）+「已读 x%」，行尾一枚
  /// 强调色圆形继续按钮。整卡点击开书（[FushiCard] 自带按压下沉 / 焦点 / 状态层），
  /// 外包 [FushiHoverLift] 悬停抬升；进场随书架网格同一窗口错峰淡入。
  /// 宽屏不拉满整行（>[_kContinueHeroMaxWidth] 时左对齐收窄），窄屏撑满。
  Widget _buildContinueReadingHero(MediaItem hero, FushiDesignTokens tokens) {
    final double fraction = hero.duration > 0
        ? (hero.position / hero.duration).clamp(0.0, 1.0)
        : 0.0;
    final int percent = (fraction * 100).round();
    final bool apple = isGlassDesign(context) && !isEinkTheme(context);
    final ColorScheme cs = theme.colorScheme;
    final Color accent =
        apple ? appleColorsOf(context).accent : tokens.surfaces.primary;
    final bool wide = MediaQuery.sizeOf(context).width >= 840;
    final double coverWidth = wide ? 72 : 60;
    final Widget card = FushiCard(
      key: const ValueKey<String>('reader_shelf_continue_hero'),
      focusId: const FushiFocusId('reader-shelf-continue-hero'),
      padding: EdgeInsets.all(tokens.spacing.gap * 1.5),
      onTap: () async {
        final MediaSource source = hero.getMediaSource(appModel: appModel);
        await appModel.openMedia(ref: ref, mediaSource: source, item: hero);
      },
      child: Row(
        children: <Widget>[
          SizedBox(
            width: coverWidth,
            height: coverWidth * 1.5,
            child: ShelfCoverFrame(
              child: FadeInImage(
                imageErrorBuilder: (_, __, ___) =>
                    _coverPlaceholderIcon(Icons.menu_book_outlined),
                placeholder: MemoryImage(kTransparentImage),
                image: mediaSource.getDisplayThumbnailFromMediaItem(
                  appModel: appModel,
                  item: hero,
                ),
                fit: BoxFit.cover,
              ),
            ),
          ),
          SizedBox(width: tokens.spacing.gap * 2),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t.book_continue_reading,
                  style: tokens.type.sectionLabel.copyWith(color: accent),
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                // TODO-2497：两行仍放不下时，桌面悬停显示完整书名（与库页卡
                // 标题同款 ShelfTitleOverflowTooltip）。
                // BUG-1108：与同卡封面（getDisplayThumbnailFromMediaItem）同源，
                // 经 getDisplayTitleFromMediaItem 应用编辑弹窗写入的 override
                // 书名；直读 DB 原始列 hero.title 会在改名后仍显示旧名。
                Builder(builder: (BuildContext context) {
                  final String heroTitle =
                      mediaSource.getDisplayTitleFromMediaItem(hero);
                  final TextStyle titleStyle = tokens.type.listTitle.copyWith(
                    fontWeight: FontWeight.w600,
                  );
                  return ShelfTitleOverflowTooltip(
                    title: heroTitle,
                    style: titleStyle,
                    maxLines: 2,
                    child: Text(
                      heroTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: titleStyle,
                    ),
                  );
                }),
                SizedBox(height: tokens.spacing.gap),
                FushiLinearProgressIndicator(
                  key: const ValueKey<String>(
                    'reader_shelf_continue_hero_progress',
                  ),
                  value: fraction,
                  minHeight: 4,
                  borderRadius: const BorderRadius.all(Radius.circular(2)),
                  // 小卡上不要常驻波浪动画，走平直形态（同封面进度条）。
                  year2023: apple ? null : true,
                  color: accent,
                  backgroundColor: apple
                      ? appleColorsOf(context).tertiaryFill
                      : cs.surfaceContainerHighest,
                ),
                SizedBox(height: tokens.spacing.gap / 2),
                Text(
                  t.book_read_progress(percent: percent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.metadata,
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap * 1.5),
          // 行尾继续按钮：纯视觉暗示（整卡就是点击目标），不单独抢焦点。
          ExcludeSemantics(
            child: DecoratedBox(
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              child: Padding(
                padding: EdgeInsets.all(tokens.spacing.gap * 1.25),
                child: FushiIcon(
                  Icons.play_arrow_rounded,
                  size: 24,
                  color: apple ? appleColorsOf(context).onAccent : cs.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _kContinueHeroMaxWidth),
        child: FushiStaggeredEntrance(
          index: 0,
          child: FushiHoverLift(
            scale: 1.01,
            builder: (BuildContext _, bool __) => card,
          ),
        ),
      ),
    );
  }

  Widget _buildBodyWithSrtBooks(
    List<MediaItem> books,
    List<SrtBook> allSrtBooks,
    AsyncSnapshot<_RemoteBookState?>? remoteSnapshot,
  ) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // BUG-963：这三张「从 EPUB 借用」的展示映射（封面 / 有 EPUB 背书门控 / 借用进度）
    // 必须以**未筛选的全量 EpubBooks 行**为源，而不是筛选后的 `books`。标签筛选只裁剪
    // 参与网格展示的列表；合集内只打了标签的有声书（SRT）成员会向其关联 EPUB 借封面 /
    // 进度 / 「查看插画」门控，若以筛选子集构建，关联 EPUB 未命中同一标签即被筛掉 → 借不到
    // → 合集成员丢封面（BUG-937 让被筛合集能带命中成员显示后暴露此缺陷）。此处已 watch
    // 于上层 build（filteredBookIdsProvider 之上的 fushiBooksProvider），read 全量安全。
    // BUG-1164：PR#474 曾在这里插一个 `_mangaOnly ? books :` 三元，把借用源换成
    // 筛选后的列表。它零收益（mangaOnly 下 buildBody 把 srtBooks 写死成空，三张
    // 借用映射的消费方全是 SRT 卡，漫画书架上一个消费者都没有）却在 mangaOnly
    // 分支上破了上面这条不变量，等 mangaOnly 将来接 SRT 就复发丢封面。已删除。
    final List<MediaItem> allEpubBooksForBorrow =
        ref.read(fushiBooksProvider(JapaneseLanguage.instance)).valueOrNull ??
            books;
    final Map<String, String> epubCoverUrisByBookKey = {};
    // BUG-728：过滤前先收 EPUB 卡已算好的进度，供只以 SRT 卡出现的有声书复用。
    final Map<String, ({int position, int duration})> epubProgressByBookKey =
        {};
    for (final MediaItem item in allEpubBooksForBorrow) {
      final String? key = _parseBookKey(item.mediaIdentifier);
      if (key != null) {
        epubProgressByBookKey[key] =
            (position: item.position, duration: item.duration);
      }
      final String? imageUrl = item.imageUrl;
      if (key != null && imageUrl != null && imageUrl.isNotEmpty) {
        epubCoverUrisByBookKey[key] = imageUrl;
      }
    }
    final Set<String> srtBookKeys = {
      for (final b in allSrtBooks)
        if (b.bookKey.isNotEmpty) b.bookKey,
    };
    // 阅读状态筛选在这里而不在搜索那一层：读完判据 [_completedBookKeys] 由
    // [_loadShelfMaps] 异步预取，只有本函数（_shelfMapsFuture 完成后）读得到真值。
    // 继续阅读 hero 也吃这份列表——筛「未读」时不该再顶着一本在读的书。
    // （展示列表过滤走 books.where；借用映射仍只遍历上面的全量列表，BUG-963。）
    //
    // 漫画页（ticket 06）把搜索 / 阅读状态 / 漫画下载三项收进同一个谓词
    // [_mangaItemPassesActiveFilters]，与页签数量共用，避免「数量说有、切过去
    // 却没有」。它依赖 [_loadShelfMaps] 的异步快照，故必须在本 FutureBuilder
    // 之后应用。
    final List<MediaItem> shelfBooks = books
        .where((MediaItem item) => _mangaOnly
            ? _mangaItemPassesActiveFilters(item)
            : _matchesReadStatusFilter(
                bookKey: _parseBookKey(item.mediaIdentifier),
                progress: (position: item.position, duration: item.duration),
              ))
        .toList();
    final List<MediaItem> epubBooks = srtBookKeys.isEmpty
        ? shelfBooks
        : shelfBooks.where((item) {
            final String? key = _parseBookKey(item.mediaIdentifier);
            return key == null || !srtBookKeys.contains(key);
          }).toList();

    // 漫画页的标签页签本身就是筛选维度：书架里还有漫画但当前页签无命中时，
    // 空态要说「没有符合筛选的书」，不能落回「书架为空」。其他媒体库仍以共用的
    // 多选标签集判据。
    final bool hasActiveFilter = _mangaOnly
        ? _mangaShelfUnfilteredNonEmpty
        : ref.read(selectedTagIdsProvider).isNotEmpty;
    final Set<String>? srtFilterSet =
        ref.watch(filteredSrtBookUidsProvider).valueOrNull;
    final List<SrtBook> tagFilteredSrtBooks;
    if (srtFilterSet != null) {
      tagFilteredSrtBooks =
          allSrtBooks.where((b) => srtFilterSet.contains(b.uid)).toList();
    } else if (hasActiveFilter) {
      tagFilteredSrtBooks = const [];
    } else {
      tagFilteredSrtBooks = allSrtBooks;
    }
    // BUG-2327：SRT 卡与 EPUB 卡同口径过搜索（显示名 + DB 原名双匹配）。
    // 阅读状态按配对 bookKey 借 EPUB 的读完标记与进度（与卡片进度条同源）。
    final List<SrtBook> srtBooks = <SrtBook>[
      for (final SrtBook b in tagFilteredSrtBooks)
        if (_matchesShelfSearch(<String>[_srtDisplayTitle(b), b.title]) &&
            _matchesReadStatusFilter(
              bookKey: b.bookKey,
              progress: epubProgressByBookKey[b.bookKey],
            ))
          b,
    ];
    // 视频归「视频」tab（HomeVideoPage）独占，书架不再显示视频分区（用户反馈：
    // 书架是书的地方）。已导入视频只在视频 tab 呈现；书架拖入视频仍可导入（经
    // _handleShelfDrop → VideoImportDialog），落库后同样只在视频 tab 可见。
    _visibleEpubBooks = epubBooks;
    _visibleSrtBooks = srtBooks;
    // 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5）：把「远端有、本地无」的书
    // 混排成主网格占位卡。远端目录拉取失败/未配对/无后端（remoteState==null 或
    // failed）→ 占位卡不出现（离线=只剩本地）；「显示远端条目」开关关闭 → 同样不
    // 渲染；标签筛选激活时占位卡不参与（远端书无本地标签），只在无筛选时混排。
    // BUG-992：自动刷新（切回书架重拉远端）期间 future 切成 waiting → data 暂为 null。
    // 缓存上次成功的远端态、waiting 时沿用，避免每次切回远端占位卡 + 书库概览总数闪一
    // 下（仿视频页 _videosCache）。失败态不覆盖缓存（离线时下一次 waiting 仍能顶住旧数据）。
    final _RemoteBookState? snapState = remoteSnapshot?.data;
    if (snapState != null && !snapState.failed) {
      _lastRemoteState = snapState;
    }
    final _RemoteBookState? remoteState = snapState ?? _lastRemoteState;
    // 互联完整支持批次：漫画书架同样显示远端占位卡（_loadRemoteBooks 已按
    // _mangaOnly 分架过滤：漫画架只来 format='manga'+hasMangaContent 的条目）。
    // 「同步与备份 + 互联」模块关掉 → 远端占位卡（含其下载按钮与长按面板）整块不
    // 渲染。取数侧由 [_shouldLoadRemoteBooks] 同门挡住，两处合起来做到零网络请求。
    final bool showRemote = remoteState != null &&
        !remoteState.failed &&
        _remotePlaceholdersAllowed;
    // BUG-2327：远端占位卡同样过搜索——它们与本地卡混排在同一网格里，搜索时
    // 本地卡被裁、远端卡还满屏，用户看到的就是「搜索不生效」。
    final List<RemoteBookInfo> remoteBooks = <RemoteBookInfo>[
      if (showRemote)
        for (final RemoteBookInfo b in remoteState.books)
          if (!_landedRemoteDownloadIds.contains(b.downloadId) &&
              _matchesShelfSearch(<String>[b.title]))
            b,
    ];
    // 纯 SRT（standalone）远端有声书占位（互联后端 listRemoteAudiobooks 的 standalone
    // 项，本地无同 uid SrtBook）——与远端 EPUB 书同门控混排进主网格。
    final List<RemoteAudiobookInfo> remoteSrtBooks = <RemoteAudiobookInfo>[
      if (showRemote)
        for (final RemoteAudiobookInfo b in remoteState.srtAudiobooks)
          if (_matchesShelfSearch(<String>[b.title ?? b.identity])) b,
    ];
    // 2026-11-05：合集功能已删除，书架按单卡平铺后排序。「最近阅读」量纲 =
    // 最后阅读时间（[_lastReadAtByBookKey]，BUG-777），不再依赖列表下标假名次。
    final List<_ShelfBookSlot> shelfSlots = <_ShelfBookSlot>[
      for (final SrtBook srt in srtBooks) _ShelfBookSlot(srt: srt),
      for (final MediaItem epub in epubBooks) _ShelfBookSlot(epub: epub),
      for (final RemoteAudiobookInfo remoteSrt in remoteSrtBooks)
        _ShelfBookSlot(remoteSrt: remoteSrt),
      for (final RemoteBookInfo remote in remoteBooks)
        _ShelfBookSlot(remote: remote),
    ];
    // 每张卡的键只算一次：键要解析显示名，放进比较器会被重算 O(n log n) 次。
    final Map<_ShelfBookSlot, ShelfSortKey> sortKeys =
        <_ShelfBookSlot, ShelfSortKey>{
      for (final _ShelfBookSlot slot in shelfSlots)
        slot: _shelfSlotSortKey(slot),
    };
    shelfSlots.sort((_ShelfBookSlot a, _ShelfBookSlot b) =>
        compareShelfSortKeys(sortKeys[a]!, sortKeys[b]!, _sortMode));
    // Shift 区间选 / 长按扫选的顺序真值 = 本帧实际渲染顺序（排序 / 搜索 / 标签
    // 筛选都已作用其上）。顺序一变，控制器自动清锚点。
    final List<String> visibleLooseKeys = <String>[
      for (final _ShelfBookSlot slot in shelfSlots)
        if (_looseSelectionKey(slot) case final String key) key,
    ];
    // 可见序真变了就补一帧：它是 build 期算出来的（搜索 / 标签筛选 / 排序的
    // 结果），而底栏「已选 N」在同一帧更早的位置就读过选中集，会慢一拍且没有
    // 后续 setState 补上。只在多选态补（非多选态选中集恒空）。
    if (_selection.setVisibleOrder(
          loose: visibleLooseKeys,
          collections: const <int>[],
        ) &&
        _selectionMode) {
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (mounted) setState(() {});
      });
    }
    _epubCoverUrisByBookKey = epubCoverUrisByBookKey;
    _epubProgressByBookKey = epubProgressByBookKey;
    // BUG-1008：空态判定看**全部**会渲染成卡的列表（含纯 SRT 远端占位）。标签筛选
    // 激活时才可能落到 tag_no_books_for_filter；旧实现另有一个
    // `hasActiveFilter && epubBooks.isEmpty` 特殊分支——SRT 命中已渲染网格却仍
    // 无条件叠「无匹配」空态文案，且丢 RefreshIndicator / 合集横排行 / 书库概览。
    // 筛选态与常态统一走下方主分支组装（shelfGroups 已能承载纯 SRT 命中结果），
    // 特殊分支消灭。
    // BUG-2327：搜索零命中与标签筛选零命中同一空态（「没有符合筛选的书」），
    // 不能落到「书架为空」占位——那会把用户引去导入。
    final bool searching =
        _searchQuery.trim().isNotEmpty ||
        _readStatusFilter != null ||
        _mangaDownloadFilter != null;
    if (epubBooks.isEmpty &&
        srtBooks.isEmpty &&
        remoteBooks.isEmpty &&
        remoteSrtBooks.isEmpty) {
      return hasActiveFilter || searching
          ? FushiFloatingChromeInsetPadding(
              child: Center(
                child: FushiPlaceholderMessage(
                  icon: Icons.filter_list_off,
                  message: t.tag_no_books_for_filter,
                ),
              ),
            )
          : FushiFloatingChromeInsetPadding(child: buildPlaceholder());
    }
    // 2026-10 动效重做：书架首屏的散书卡错峰淡入（见 FushiStaggeredEntrance）；
    // 窗口关闭后滚动带出的卡瞬间出现，不拖影。
    return FushiEntranceScope(
      child: FushiScrollbar(
        controller: _shelfScrollController,
        child: LayoutBuilder(
          // 下拉刷新：保活后切回书架不再隐式重拉远端，给用户显式强制刷新入口。
          builder: (context, constraints) => RefreshIndicator(
            onRefresh: _pullToRefreshBooks,
            // 叠放工具区的高度（恒定，不随显隐变）：转圈从工具区下沿出来。
            edgeOffset: FushiFloatingChromeInset.of(context),
            child: CustomScrollView(
              controller: _shelfScrollController,
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              slivers: [
                // 叠放工具区让出的顶部高度（不在外壳里时为 0）+ 原有的 gap：内容
                // 从工具区下方开始、滚动时滚到工具区底下。
                SliverToBoxAdapter(
                  child: SizedBox(
                    height:
                        FushiFloatingChromeInset.of(context) + tokens.spacing.gap,
                  ),
                ),
                // 书架顶部「继续阅读 hero」条。原并排的「统计」三格（总数/在读/
                // 已完成）按用户反馈移除——右上角「阅读统计」已有完整入口，此处
                // 属重复信息。无在读候选时整条隐藏。
                // BUG-804：hero 喂**未过滤的全量 EPUB-backed `books`**（含有声书），
                // 不是 srt 过滤后的 `epubBooks`——否则读了有声书「继续阅读」永不更新。
                if (epubBooks.isNotEmpty || srtBooks.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _buildShelfOverviewSection(shelfBooks),
                  ),
                // TODO-902: 书架不再按类型分区，SRT 有声书卡与 EPUB 卡混排进同一
                // 网格（卡片本身的类型标识保留）。远端占位书同样作为单卡混排。
                // 2026-11-05：合集已删除，不再有合集格子。
                if (shelfSlots.isNotEmpty)
                  ..._buildShelfSlotSlivers(
                    shelfSlots,
                    epubCoverUrisByBookKey,
                    constraints,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 主网格 sliver 组装：合集折成网格里的**一个格子**（[_buildShelfCollectionCard]，
  /// 叠层封面），与散书同一个网格、按 [groups] 已排好的同一顺序混排（合集取成员的
  /// 代表值参与排序，见 `_shelfGroupSortKey`）。远端占位书归属合集时折进该合集格子，
  /// 要下载就进合集详情页点它（[_openCollectionMember]）。
  ///
  /// 2026-11-05：合集已删除，主网格收敛为「每张卡一个格子」。
  List<Widget> _buildShelfSlotSlivers(
    List<_ShelfBookSlot> slots,
    Map<String, String> epubCoverUrisByBookKey,
    BoxConstraints constraints,
  ) {
    final ({int columns, double cardWidth}) cardLayout = unifiedShelfCardLayout(
      availableWidth: constraints.maxWidth,
      targetWidth: _gridExtent(context, constraints),
      spacing: 0,
    );
    return <Widget>[
      SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cardLayout.columns,
          childAspectRatio: kShelfBookCardAspectRatio,
        ),
        itemCount: slots.length,
        itemBuilder: (_, int i) => FushiStaggeredEntrance(
          index: i,
          child: _buildShelfSlotCard(slots[i], epubCoverUrisByBookKey),
        ),
      ),
    ];
  }

  /// 单卡渲染：远端占位 / SRT / EPUB 三类卡片各走原有渲染。
  Widget _buildShelfSlotCard(
    _ShelfBookSlot slot,
    Map<String, String> epubCoverUrisByBookKey,
  ) {
    final RemoteBookInfo? remote = slot.remote;
    if (remote != null) return _buildRemoteBookCard(remote);
    final RemoteAudiobookInfo? remoteSrt = slot.remoteSrt;
    if (remoteSrt != null) return _buildRemoteSrtCard(remoteSrt);
    final SrtBook? srt = slot.srt;
    if (srt != null) {
      return _buildSrtCard(
        srt,
        epubCoverUri: epubCoverUrisByBookKey[srt.bookKey],
      );
    }
    return buildMediaItem(slot.epub!);
  }

  /// 远端占位卡能否混排的**唯一**门控（书架主网格 `showRemote` 与合集详情页
  /// [_detailRemoteState] 共用）：「显示远端条目」开关开 + 同步模块启用 + 无标签
  /// 筛选 + 无阅读状态筛选。远端书没有本地标签，也没有本机的阅读进度与读完标记，
  /// 归进任何一档筛选都是猜。两处以前各抄一份，新加条件时漏掉一处就会出现「合集
  /// 行头数字与详情页对不上」。
  bool get _remotePlaceholdersAllowed =>
      (_mangaOnly
          ? _mangaTagTabSelection == null
          : ref.read(selectedTagIdsProvider).isEmpty) &&
      _readStatusFilter == null &&
      // 远端占位卡没有本地的下载状态可判，归进「已下载 / 未下载」任何一档都是
      // 猜；有下载筛选时整块不混排（与阅读状态筛选同一条纪律）。
      _mangaDownloadFilter == null &&
      appModel.prefsRepo.showRemoteEntries &&
      _moduleVisibility.isEnabled(ModuleId.sync);

  /// 弹删除确认框，返回用户的 [DeleteDecision]（scope：[DeleteScope.syncEverywhere]
  /// = 同步删除到其他设备 / [DeleteScope.keepLocalOnly] = 仅本机；deleteLocalFiles：
  /// 是否连原始音频文件一起删，仅 [localFilesSubtitle] 非 null 时可勾）；取消或已 unmount 返回
  /// null。
  Future<DeleteDecision?> _confirmMediaDelete({
    required String title,
    required String message,
    DeletionDisclosure? disclosure,
    String? localFilesSubtitle,
    String? statisticsSubtitle,
  }) async {
    // TODO-2470 死角②：本机没有任何删除传播通道时不摆那个兑现不了的勾选框。
    // 纯本地零网络判据，在弹窗弹出前解析完（弹窗自身不做 IO）。
    final bool canSyncEverywhere =
        await hasDeletionPropagationChannel(SyncRepository(appModel.database));
    final DeletePromptPreferenceStore preferenceStore =
        DeletePromptPreferenceStore(appModel.database);
    final DeletePromptRememberedChoices? rememberedChoices =
        await preferenceStore.load();
    if (!mounted) return null;
    final DeleteDecision? decision = await showAppDialog<DeleteDecision>(
      context: context,
      builder: (ctx) => ReaderHistoryDeleteDialog(
        title: title,
        message: message,
        disclosure: disclosure,
        showSyncScope: canSyncEverywhere,
        localFilesSubtitle: localFilesSubtitle,
        statisticsSubtitle: statisticsSubtitle,
        rememberedChoices: rememberedChoices,
        onPersistChoices: preferenceStore.write,
        onConfirm: (DeleteDecision d) => Navigator.pop(ctx, d),
      ),
    );
    if (!mounted) return null;
    return decision;
  }

  @override
  Widget buildPlaceholder() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 在库页导航壳里：空态引导去「导入」视图（快速导入 + 常驻来源都在那），教会
    // 用户唯一入库位置；独立使用（无壳）时回退为直接开导入对话框。
    final MediaLibraryShellScope? shell =
        MediaLibraryShellScope.maybeOf(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FushiPlaceholderMessage(
            icon: mediaSource.icon,
            message: t.reader_no_books_added,
          ),
          // 2026-11-05：漫画的 Local import 已搬到「浏览」，空书架只留提示。
          // 普通书架仍保留原来的「去导入」引导。
          if (!_mangaOnly) ...[
            SizedBox(height: tokens.spacing.gap + tokens.spacing.gap / 2),
            if (shell != null)
              FushiFilledButton.icon(
                icon: const FushiIcon(Icons.library_add_outlined, size: 18),
                label: Text(t.library_empty_go_import),
                onPressed: () => shell.select(MediaLibraryViewKind.sources),
              )
            else
              FushiFilledButton.icon(
                icon: const FushiIcon(Icons.library_add_outlined, size: 18),
                label: Text(t.srt_import),
                onPressed: () async {
                  // 空态兜底与页头兜底指向同一个对话框：书架开书籍框。
                  final bool? imported = await showAppDialog<bool>(
                    context: context,
                    builder: (_) => BookImportDialog(
                      prefs: appModel.prefsRepo,
                      repo: SrtBookRepository(appModel.database),
                      audiobookRepo: AudiobookRepository(appModel.database),
                      db: appModel.database,
                    ),
                  );
                  if (imported == true) {
                    ref.invalidate(
                      fushiBooksProvider(JapaneseLanguage.instance),
                    );
                    ref.invalidate(srtBooksProvider);
                  }
                },
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget buildMediaItemContent(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    // Audiobook info is keyed by the book's bookKey (the Audiobooks table key),
    // NOT the MediaItem.uniqueKey (which is the source-prefixed identifier).
    final info = _getAudiobookInfo(bookKey ?? '');
    final bool hasAudiobook = info.hasAudiobook;
    final HealthKind healthKind = info.healthKind;
    final bool isManga = _isMangaItem(item);

    // 漫画封面左上角不再挂用户标签 chip（ticket 03）：封面空间让给未读角标，
    // 标签浏览走页签栏。其他媒体类型原样保留。
    final tagWidget =
        isManga ? null : (bookKey != null ? _buildTagLabels(bookKey) : null);

    return _bookCardLayout(
      title: mediaSource.getDisplayTitleFromMediaItem(item),
      cover: FadeInImage(
        imageErrorBuilder: (_, __, ___) =>
            _coverPlaceholderIcon(Icons.menu_book_outlined),
        placeholder: MemoryImage(kTransparentImage),
        image: mediaSource.getDisplayThumbnailFromMediaItem(
          appModel: appModel,
          item: item,
        ),
        alignment: Alignment.topCenter,
        fit: _bookCardCoverFit,
      ),
      tagLabels: tagWidget,
      // 漫画卡右上角是未读章节数（0 时整个角标不渲染），不再是书本图标；
      // 角标宽度随数字伸展，故不套固定 22px 方框。其余媒体类型仍用原图标角标。
      coverBadge: isManga
          ? _mangaUnreadBadge(bookKey)
          : hasAudiobook
              ? _audiobookBadge(healthKind)
              : _cardBadge(
                  icon: Icons.menu_book_outlined,
                  background: theme.colorScheme.surfaceContainerHighest,
                  foreground: theme.colorScheme.onSurfaceVariant,
                ),
      coverBadgeAutoWidth: isManga,
      metadata: _progressBar(
        item,
        completed: bookKey != null && _completedBookKeys.contains(bookKey),
      ),
      // BUG-990：这本书的有声书包还在下载 → 本地 EPUB 卡继续显示加载覆盖层。
      loadingOverlay: _audiobookDownloadingOverlay(bookKey),
    );
  }

  /// 漫画卡右上角的未读章节数角标：0 未读返回 null（整个角标不渲染），
  /// ≥100 封顶显示「99+」。底色 / 字号沿用共享 [CoverBadge]。
  Widget? _mangaUnreadBadge(String? bookKey) {
    if (bookKey == null) return null;
    final int unread = _mangaUnreadCountsByBookKey[bookKey] ?? 0;
    if (unread <= 0) return null;
    return CoverBadge(
      key: ValueKey<String>('manga_unread_badge_$bookKey'),
      label: unread >= 100 ? '99+' : '$unread',
    );
  }

  @override
  Widget buildMediaItem(MediaItem item) =>
      _buildEpubBookCard(item, selectable: true);

  /// EPUB 书卡渲染。[selectable]（默认经 [buildMediaItem] 传 true）= 多选态可单独勾选。
  /// [focusIdPrefix]：详情页渲染路径传 'collection-detail-' 隔离焦点 id 命名空间；
  /// 书架路径恒空串（id 不变）。
  Widget _buildEpubBookCard(MediaItem item,
      {bool selectable = true, String focusIdPrefix = ''}) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    final Widget card = _bookCardShell(
      slotAspectRatio: kShelfBookCardAspectRatio,
      cardKey: ValueKey<String>('book_entry_${item.mediaIdentifier}'),
      focusId: FushiFocusId(
          '${focusIdPrefix}reader-shelf-book-${item.mediaIdentifier}'),
      selectionKey: selectable ? item.mediaIdentifier : null,
      dragBookId: bookKey,
      onTagDropped:
          bookKey == null ? null : (tag) => _addTagToBook(bookKey, tag),
      // 拖卡进合集：EPUB / PDF / 漫画同为 EpubBooks 行，合集身份统一是
      // (epub, uid)（v83；bookKey 经 [_epubUidByKey] 换算，卡片渲染时映射已随
      // [_loadShelfMaps] 就绪）——漫画书架复用本卡，故一处接线两个书架都生效。
      dragMediaRef: bookKey == null
          ? null
          : MediaRef(
              kind: MediaKind.epub,
              entryKey: _epubUidByKey[bookKey] ?? bookKey,
            ),
      dragLabel: displayTitleForBook(item: item, rawTitle: item.title),
      onTap: () async {
        // 漫画先进作品页，不直接开书。
        //
        // 作品页**刻意不走 `openMedia`**：那条路是「媒体会话」语义——沉浸模式、
        // wakelock、audio handler、_currentMediaSource 全在里面开。作品页是个可
        // 浏览的库页面（章节列表、已读标记、刷新），当媒体会话打开会让它顶着
        // 隐藏的系统 UI、亮着屏。真正的会话由作品页内部再 `openMedia` 开阅读器
        // 时启动，语义与 v88 前逐字相同。
        if (_isMangaItem(item) && bookKey != null) {
          await Navigator.of(context).push(
            adaptivePageRoute<void>(
              context: context,
              builder: (BuildContext context) => MangaSeriesPage(
                target: _mangaSeriesTarget(bookKey, item),
              ),
            ),
          );
          // 作品页里可能读了几章 / 手动标记了已读：返回书架时重取一次未读
          // 角标（与「标记为已读完」菜单同一条刷新路径）。阅读器关闭另有
          // mediaType.refreshTab 信号，两条路都落到 [_loadShelfMaps]。
          if (!mounted) return;
          setState(() {
            _shelfMapsFuture = _loadShelfMaps();
          });
          return;
        }
        final MediaSource source = item.getMediaSource(appModel: appModel);
        await appModel.openMedia(
          ref: ref,
          mediaSource: source,
          item: item,
        );
      },
      onLongPress: () => _showEpubItemMenu(item),
      child: buildMediaItemContent(item),
    );
    // 仅 EPUB 书卡作为字幕/音频拖放目标；SRT 卡/视频卡不在 books 表面范围内。
    if (bookKey == null) return card;
    return CardDropZone<String>(meta: bookKey, child: card);
  }

  /// EPUB / 漫画 / PDF 书卡的长按 / 右键菜单。
  Future<void> _showEpubItemMenu(MediaItem item) async {
    await showAppDialog(
      context: context,
      builder: (BuildContext dialogCtx) => MediaItemDialogPage(
        item: item,
        isHistory: isHistory,
        showLaunchAction: false,
        // 漫画卡菜单（含作品页「管理本卷」）把「编辑信息」提到列表首项；
        // 其它书卡保持历史行为（内置动作追加在末尾）。
        editInfoFirst: _isMangaItem(item),
        extraActions: (MediaItem it) => _epubExtraActions(it),
      ),
    );
    if (isHistory && mounted) {
      setState(() {});
    }
  }

  /// 漫画作品页的目标。作品页「管理本卷」开的就是本页的 [_showEpubItemMenu]——
  /// 同一份动作、同一套刷新纪律。本页已销毁（作品页还开着时切走了书架）就什么都
  /// 不做，作品页照常收尾。
  ShelfMangaSeriesTarget _mangaSeriesTarget(String bookKey, MediaItem item) =>
      ShelfMangaSeriesTarget(
        bookKey,
        item: item,
        showShelfMenu: () async {
          if (!mounted) return;
          await _showEpubItemMenu(item);
        },
      );

  @override
  List<DialogAction> extraActions(MediaItem item) {
    return _epubExtraActions(item);
  }

  /// 本地 [bookKey] 这本书在对端的「只缺有声书」候选（BUG-2505）：最近一次远端清单
  /// 里对端有配套有声书、本端只有书没有有声书时非 null。远端清单没拉到 / 非互联 /
  /// 本端已有有声书都是 null → 菜单不露这一项。
  ///
  /// 与远端卡同一道门（[_shouldLoadRemoteBooks]）：`_lastRemoteState` 只在成功快照时
  /// 被替换、关掉「显示远端条目」/ 同步模块后不会清空，若只看它，远端卡已经消失、
  /// 本地书卡菜单还露着「从互联对端下载有声书」，点下去只能弹「不可用」。
  RemoteBookInfo? _remoteAudiobookOnlyFor(String bookKey) =>
      _shouldLoadRemoteBooks ? _lastRemoteState?.audiobookOnly[bookKey] : null;

  /// 本地 [bookKey] 这本书在对端的「重新拉取有声书 / 字幕」候选：本端已有书和有声书、
  /// 对端也有配套有声书时非 null。门与 [_remoteAudiobookOnlyFor] 相同。
  RemoteBookInfo? _remoteAudiobookRefetchFor(String bookKey) =>
      _shouldLoadRemoteBooks
          ? _lastRemoteState?.audiobookRefetch[bookKey]
          : null;

  /// EPUB 书卡长按菜单动作真身。
  ///
  /// 2026-11-05 用户口径：漫画页只保留阅读/管理必需动作。查看插画、识别文字OCR、
  /// 查看统计、内容语言、转换回书、加入合集、指定配置、编辑书籍CSS、作品页九项
  /// 不再提供；其中统计 / Profile / 内容语言 / 格式转换是跨模块共享设施，只删
  /// 入口，底层保留（见 ticket 20）。
  List<DialogAction> _epubExtraActions(MediaItem item) {
    final String? bookKey = _parseBookKey(item.mediaIdentifier);
    if (bookKey == null) return const [];
    // 本菜单是书卡通往**别的模块**的集散地（听书 / 漫画 / 在线服务），一次快照后
    // 逐条按模块过滤：被关掉的模块不留可点位置。
    final ModuleVisibility modules = _moduleVisibility;
    final bool isManga = _isMangaItem(item);
    return <DialogAction>[
      // 漫画卡：删除是列表末位的红色危险项（见方法末尾），不再单列危险区。
      // 非漫画书卡维持原布局。
      if (!isManga)
        DialogDangerAction(
          label: t.dialog_delete,
          onPressed: () => _confirmDeleteEpub(item, bookKey),
        ),
      // 有声书导入仍受听书模块门控（develop 侧）；「重命名」不受它管。
      if (!isManga && modules.isEnabled(ModuleId.listening))
        DialogQuickAction(
          label: t.audiobook_import,
          icon: Icons.headphones_outlined,
          onPressed: () => _openAudiobookImport(item, bookKey),
        ),
      if (!isManga && modules.isEnabled(ModuleId.listening))
        DialogQuickAction(
          label: t.audiobook_studio_title,
          icon: FushiIcons.voice,
          onPressed: () => _openAudiobookStudio(bookKey),
        ),
      // BUG-2505：本地已有这本书、还没有它的有声书、而对端有配套有声书 → 给一个
      // 显式的补拉入口。远端卡按「本端已有」被整条藏掉后，这里是唯一能到达对端
      // 有声书的地方（候选表由 _loadRemoteBooks 随远端清单一起算，见
      // [_RemoteBookState.audiobookOnly]）。同受听书模块门控。
      if (modules.isEnabled(ModuleId.listening) &&
          _remoteAudiobookOnlyFor(bookKey) != null)
        DialogQuickAction(
          label: t.remote_book_audiobook_download,
          icon: Icons.cloud_download_outlined,
          onPressed: () => _downloadRemoteAudiobookOnly(
              _remoteAudiobookOnlyFor(bookKey)!, bookKey),
        ),
      // 本机已有有声书、对端也有：host 上重新转录 / 换了字幕之后，从这里把新字幕
      // （或整本有声书）重新拉回来。只更新字幕不动音频，进度 / 断点 / 统计都保留。
      if (modules.isEnabled(ModuleId.listening) &&
          _remoteAudiobookRefetchFor(bookKey) != null) ...<DialogAction>[
        DialogListAction(
          label: t.remote_book_subtitles_refresh,
          icon: FushiIcons.subtitles,
          onPressed: () => _refetchRemoteAudiobook(
              _remoteAudiobookRefetchFor(bookKey)!, bookKey,
              subtitlesOnly: true),
        ),
        DialogListAction(
          label: t.remote_book_audiobook_redownload,
          icon: FushiIcons.cloudSync,
          onPressed: () => _refetchRemoteAudiobook(
              _remoteAudiobookRefetchFor(bookKey)!, bookKey,
              subtitlesOnly: false),
        ),
      ],
      // 三库页对称：视频卡/游戏卡的菜单里「重命名」都排在列表项首位，书卡对齐。
      // 漫画卡例外：2026-11-05 用户口径，漫画页菜单只保留阅读/管理必需动作。
      if (!isManga)
        DialogListAction(
          label: t.book_rename,
          icon: Icons.drive_file_rename_outline,
          onPressed: () => _renameBook(context, item),
        ),
      // 桌面才有文件管理器契约（[currentRevealHost] 在移动端返回 null）——整条隐藏，
      // 而不是画一个点了没反应的按钮。漫画卷要手改 mokuro 数据时，这一条直接把书目录
      // 里的 manga.json 选中，省掉「书在哪个 bookKey 目录」这层猜。
      if (currentRevealHost() != null)
        DialogListAction(
          label: t.media_file_location_open,
          icon: Icons.folder_open_outlined,
          onPressed: () => _openBookFileLocation(bookKey),
        ),
      DialogListAction(
        label: _completedBookKeys.contains(bookKey)
            ? t.book_mark_uncompleted_action
            : t.book_mark_completed_action,
        icon: _completedBookKeys.contains(bookKey)
            ? Icons.check_circle
            : Icons.check_circle_outline,
        onPressed: () => _toggleBookCompleted(bookKey),
      ),
      // 误点开一本书后把它变回「没读过」：进度归零 + 取消读完 + 离开继续阅读，
      // 学习记录可选撤销最近一次（默认不动），见 [_resetBookReadingState]。
      DialogListAction(
        label: t.library_progress_reset_action,
        icon: Icons.restart_alt_outlined,
        onPressed: () => _resetBookReadingState(item, bookKey),
      ),
      // 统一三库页刮削入口：书卡菜单直达「在线刮削封面」（视频/游戏的刮削都在
      // 卡菜单一层，书此前必须绕「编辑信息→封面字段小图标」两层，用户实报）。
      // 刮削要打第三方 API，属「在线服务」模块。
      if (modules.isEnabled(ModuleId.services))
        DialogListAction(
          label: t.book_scrape_cover,
          icon: Icons.image_search_outlined,
          onPressed: () => _scrapeEpubCover(item),
        ),
      // 统一三库页卡菜单：书卡与视频/游戏卡对称含「标签」项。TODO-455 曾拍板
      // 移除，用户 2026-07-28 正式推翻（守卫测试同步更新）；拖标签/批量打标签
      // 两条旧路径不受影响。
      DialogListAction(
        label: t.tag_label,
        icon: Icons.sell_outlined,
        onPressed: () => _openMediaTagPicker(
          MediaRef(kind: MediaKind.epub, entryKey: bookKey),
        ),
      ),
      // TODO-291 阶段2：书架长按「悬浮字幕」= 启动该书的后台听书会话（无正在播则用该书
      // 启动 + 拉起悬浮窗），不再只翻 bool。该书已是活动会话则改为「停止后台听书」。
      // 「悬浮字幕」= 用该书起一个后台听书会话，属听书模块。
      if ((Platform.isAndroid || Platform.isWindows) &&
          modules.isEnabled(ModuleId.listening))
        // 2026-10 体验优化：开启态不再拼「悬浮字幕 ✓」（看不出点了是开还是关），
        // 改成明确的「关闭悬浮字幕」+ 不同图标。
        DialogListAction(
          label: _isBackgroundListeningBook(bookKey)
              ? t.floating_lyric_stop_action
              : t.floating_lyric_toggle_action,
          icon: _isBackgroundListeningBook(bookKey)
              ? Icons.subtitles_off_outlined
              : Icons.subtitles_outlined,
          onPressed: () => _toggleFloatingLyricFromShelf(bookKey),
        ),
      // 漫画卡：删除排在列表末位（不再单列危险区），但保留危险红色；
      // 点击仍走 [_confirmDeleteEpub] 的原有确认流程。
      if (isManga)
        DialogListAction(
          label: t.dialog_delete,
          icon: FushiIcons.delete,
          destructive: true,
          onPressed: () => _confirmDeleteEpub(item, bookKey),
        ),
    ];
  }

  /// 单卡「在线刮削封面」（统一三库页刮削入口）：先收起长按菜单，弹既有
  /// [BookCoverScrapeDialog]（Bangumi 书籍条目，选中即下载临时文件），选中后
  /// 立即走与「编辑信息」保存完全相同的 override 通道落封面，卡面即时刷新。
  /// 书卡菜单直达「重命名」（EPUB / 漫画 / PDF / SRT 有声书共用——身份换算全在
  /// [MediaSource] 里，这一层只认 [MediaItem]）。
  ///
  /// 与上面「在线刮削封面」同一形状的入口下沉：改名的**能力**一直都在，但只长在
  /// 「编辑信息」弹窗的标题字段里，用户得先想到那是个改名入口再点进两层；视频卡和
  /// 游戏卡的菜单第一项就是「重命名」。书卡此前缺这一档，纯属三库页不对称。
  ///
  /// 落点是**显示名覆盖偏好**（`override_title://`），绝不写 `epub_books.title`：
  /// 那一列派生出主键 `bookKey`，改列等于换身份、十来张子表连坐重键（理由见
  /// `override_title_key.dart` 的文件头）。清空改名仍然只在「编辑信息」里做——本
  /// 弹窗按共享原语的约定拒绝空名，避免「确认键点不动」被误读成改名失败。
  ///
  /// [dialogContext] 是**要关掉的那个菜单**的 context：EPUB 卡菜单由页面 context
  /// 承载，SRT 卡菜单自带一个 dialogContext，两者不能混用（拿页面 context 去 pop
  /// SRT 菜单会连页面一起弹掉）。
  Future<void> _renameBook(BuildContext dialogContext, MediaItem item) async {
    Navigator.pop(dialogContext);
    final MediaSource mediaSource = item.getMediaSource(appModel: appModel);
    // 初值取**当前显示名**（override ?? 原名）而不是原始 title：否则改过一次名的
    // 书再次打开改名框会闪回原名，用户以为改名丢了。统一走显示名门面。
    final String current = displayTitleForBook(item: item, rawTitle: item.title);
    final String? name = await showNameInputDialog(
      context: context,
      title: t.book_rename,
      labelText: t.book_rename_label,
      initialName: current,
      leadingIcon: Icons.drive_file_rename_outline,
    );
    if (!mounted || name == null || name == current) return;
    await mediaSource.setOverrideTitleFromMediaItem(item: item, title: name);
    if (!mounted) return;
    // BUG-1018 同款刷新纪律：书架的响应式源按 key 集合去重，纯覆盖层写入不会
    // 自动重发，只 refreshTab 会拿旧的缓存 MediaItem 重绘、看着像"没保存"。
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
    _rebuild(() {});
  }

  Future<void> _scrapeEpubCover(MediaItem item) async {
    Navigator.pop(context);
    final MediaSource mediaSource = item.getMediaSource(appModel: appModel);
    final File? scraped = await showBookCoverScrapeDialog(
      context: context,
      initialQuery: displayTitleForBook(item: item, rawTitle: item.title),
    );
    if (scraped == null || !mounted) return;
    await MediaCoverService.applyBookCoverOverride(
      appModel: appModel,
      mediaSource: mediaSource,
      item: item,
      file: scraped,
      clearOverrideImage: false,
    );
    if (!mounted) return;
    ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance));
    ref.invalidate(srtBooksProvider);
    _rebuild(() {});
  }

  /// 单卡「标签」（统一三库页卡菜单，用户 2026-07-28 拍板推翻 TODO-455）：先收起
  /// 长按菜单，进共享标签池的 [TagPickerPage]（媒体路，epub/srt 通用）；返回后
  /// 失效标签 map 与筛选 provider，卡面 chip 与标签过滤立即刷新。
  Future<void> _openMediaTagPicker(MediaRef media) async {
    Navigator.pop(context);
    await showTagPicker(context, targets: TagTargets(media: <MediaRef>[media]));
    if (!mounted) return;
    ref.invalidate(allTagsProvider);
    ref.invalidate(bookTagMapProvider);
    ref.invalidate(filteredBookIdsProvider);
    ref.invalidate(filteredSrtBookUidsProvider);
  }

  /// 手动切换书 / 有声书「已读完」状态：写 EpubBooks.completedAt（单一真值，按
  /// bookKey），有声书 SRT 卡也调它（传其配对 bookKey）。已完成 → 清除；未完成 →
  /// 置当前时间。切换后重取完成集合并重绘，概览统计与卡片视觉下一帧即同步。
  ///
  /// 在线漫画（描述符里带 Chapter 列表）额外级联章状态：标记时把本书所有 Chapter
  /// 的已读时刻置为已读，取消时清空；两种情况都不碰每章上次页码，也不碰描述符里
  /// 的当前章位置（`currentChapterIndex`），下次仍从原页继续。标记级联还保留既有
  /// 行的 `updatedAt`（续读选章判据），新行用 0 不参与竞争——整批写 now 会让续读
  /// 跳到列表首章（ticket 02 复审 C）。本地卷没有 Chapter，只切换书级完成标记，
  /// 阅读位置与页进度保持真实。
  /// [bookKey] 为空（无 EPUB 正文的纯字幕书）时静默忽略——该书无进度维度、也无
  /// 完成真值载体，与 [_openSrtBook] 的 `srt_epub_not_ready` 门控一致。
  Future<void> _toggleBookCompleted(String bookKey) async {
    Navigator.pop(context);
    if (bookKey.isEmpty) return;
    final bool wasCompleted = _completedBookKeys.contains(bookKey);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    // 统一走 [_onlineMangaEntryFromRow]：它同时要求 `BookFormat.manga` + 带章节的
    // 在线描述符，与批量下载 / 阅读器判据同源（review D3：这里曾只 parse 描述符，
    // 非 manga 格式的残留描述符也会被当成在线漫画去级联章状态）。
    final OnlineMangaLibraryEntry? entry = _onlineMangaEntryFromRow(row);
    if (entry != null && row != null && row.uid.isNotEmpty) {
      if (wasCompleted) {
        await appModel.database.clearMangaChaptersRead(row.uid);
      } else {
        await appModel.database.markMangaChaptersRead(
          bookUid: row.uid,
          chapterKeys: <String>[
            for (final OnlineMangaChapter chapter in entry.chapters)
              chapter.key,
          ],
          // 书架级联：保留既有行的 updatedAt（续读选章判据），新行用 0 不参与竞争。
          preserveUpdatedAt: true,
        );
      }
    }
    await appModel.database.setEpubBookCompleted(
      bookKey,
      wasCompleted ? null : DateTime.now(),
    );
    if (!mounted) return;
    _shelfMapsFuture = _loadShelfMaps();
    _rebuild(() {});
    FushiToast.show(
      msg: wasCompleted ? t.book_marked_uncompleted : t.book_marked_completed,
      severity: ToastSeverity.success,
    );
  }

  /// 这张卡是不是漫画。判据与书架的漫画/书分流
  /// （[filterShelfEntriesByMangaSplit]）逐字相同：`mediaSourceIdentifier` 由
  /// `EpubBooks.format` 经 `ReaderFushiSource.mediaSourceKeyFor` 派生，卡上已有，
  /// 不必为了画一行菜单再去读一次库。
  bool _isMangaItem(MediaItem item) =>
      item.mediaSourceIdentifier == MangaFushiSource.kUniqueKey;

  /// 在系统文件管理器里定位这本书的磁盘文件（EPUB / PDF / 漫画同一条路径）。
  ///
  /// 读行 + 探磁盘都放在**点击后**，塞进菜单 build 会让书架每次重绘都吃一遍 IO。
  /// 定位不到（书目录已被外部删除、文件管理器起不来）时给一句提示，不静默——静默的
  /// 「打开文件位置」和坏掉的按钮无法区分。
  Future<void> _openBookFileLocation(String bookKey) async {
    Navigator.pop(context);
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    final bool revealed = row != null && await revealBookLocation(row);
    if (revealed || !mounted) return;
    FushiToast.show(
      msg: t.media_file_location_failed,
      severity: ToastSeverity.error,
    );
  }

  String? _parseBookKey(String mediaIdentifier) =>
      ReaderFushiSource.parseBookKey(mediaIdentifier);

  // ── 拖拽导入（books 表面） ──────────────────────────────────────────────────
}

/// 书架「继续阅读」hero 的候选选择：只有带**可用**最近阅读时间
/// （[ReaderHistoryPolicy.hasRecency]）的在读书才参与。
///
/// 无痕阅读首次读一本从没读过的书时，`reader_positions` 新行写
/// [ReaderHistoryPolicy.noRecency] 哨兵（没有旧时间戳可冻结）。它不是一次近期
/// 阅读：若参与选择，这次阅读就会让 hero 多出 / 换成本书。哨兵因此与「没有阅读
/// 历史」一样排除。排序仍选时间戳最大者（BUG-777）。
@visibleForTesting
MediaItem? pickShelfContinueHero(
  Iterable<MediaItem> inProgress,
  int? Function(MediaItem item) lastReadAtOf,
) {
  final List<({MediaItem item, int at})> candidates =
      <({MediaItem item, int at})>[
    for (final MediaItem item in inProgress)
      if (lastReadAtOf(item) case final int at
          when ReaderHistoryPolicy.hasRecency(at))
        (item: item, at: at),
  ];
  return mostRecentlyReadCandidate(
    candidates,
    (({MediaItem item, int at}) candidate) => candidate.at,
  )?.item;
}

/// 书架混排网格的单个排序槽（SRT / EPUB / 远端占位三类卡片到一个有序列表）。
/// BUG-2458：远端占位卡的多选键（库级私有，parts 共用）。
const String _kRemoteBookSelectionPrefix = 'remote_book_';
const String _kRemoteSrtSelectionPrefix = 'remote_srt_';

/// 漫画页「排序与筛选」里的「漫画下载」单选值（null = 全部）。
enum _MangaDownloadFilter {
  /// 至少有一章在本地可读。
  downloaded,

  /// 一章本地可读的都没有。
  notDownloaded,
}

/// 漫画书架搜索用的附加元数据：一条 `epub_books` 行的作者与在线描述符。
///
/// 只随 [_loadShelfMaps] 批量预取一次；`MediaItem` 上的 `sourceMetadata` 是
/// 阅读进度用的另一份 JSON，不能拿它解码源分类 / 简介。
class _MangaShelfMeta {
  const _MangaShelfMeta({required this.author, required this.onlineEntry});

  final String? author;
  final OnlineMangaLibraryEntry? onlineEntry;
}

/// 远端 EPUB 占位卡的多选键：身份是 host 的 `downloadId`（与 [_ShelfBookSlot]
/// 的 entryKey、下载任务 id 同源），不是可被 host 改名的显示名。
String _remoteBookSelectionKey(RemoteBookInfo book) =>
    '$_kRemoteBookSelectionPrefix${book.downloadId}';

/// 纯 SRT 远端有声书占位卡的多选键：身份是 `identity`（与 entryKey 同源）。
String _remoteSrtSelectionKey(RemoteAudiobookInfo book) =>
    '$_kRemoteSrtSelectionPrefix${book.identity}';

bool _isRemoteSelectionKey(String key) =>
    key.startsWith(_kRemoteBookSelectionPrefix) ||
    key.startsWith(_kRemoteSrtSelectionPrefix);

/// [srt]/[epub]/[remote] 恰有一个非空。「最近阅读」量纲不在槽里——由页面级
/// `_lastReadAtByBookKey`（reader_positions.updatedAt）按 bookKey 查（BUG-777）。
///
/// [remote] = 多端库联合视图（spec 2026-07-12 §2.1）的「远端有、本地无」占位卡：
/// 无本地 importedAt/lastReadAt，排序退化到目录序（注入时以 `-1-index` 编码进
/// CollectionOrderingItem.importedAt，稳定排在本地条目之后、组内保持目录序）。
class _ShelfBookSlot {
  const _ShelfBookSlot({
    this.srt,
    this.epub,
    this.remote,
    this.remoteSrt,
  });

  final SrtBook? srt;
  final MediaItem? epub;
  final RemoteBookInfo? remote;

  /// 纯 SRT（standalone）远端有声书占位卡（互联后端 listRemoteAudiobooks 的
  /// standalone 项，本地尚无同 uid 的 SrtBook）。与 [remote] 同为「远端占位」，无本地
  /// 阅读进度，排在本地条目之后；下载后原地变本地 SRT 卡。
  final RemoteAudiobookInfo? remoteSrt;
}
