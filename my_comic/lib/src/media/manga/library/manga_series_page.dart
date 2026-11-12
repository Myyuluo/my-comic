import 'dart:async';
import 'package:my_comic/src/media/downloads/download_source_method.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_cloudflare_action.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_web_login_page.dart';
import 'dart:io';

import 'package:drift/drift.dart'
    show ResultSetImplementation, TableUpdate, TableUpdateQuery;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic/src/media/manga/download/download_identity.dart';
import 'package:my_comic/src/media/manga/download/download_library_changes.dart';
import 'package:my_comic/src/media/manga/download/download_library_index.dart';
import 'package:my_comic/src/media/manga/download/manga_download_service.dart';
import 'package:my_comic/src/media/manga/history/manga_history.dart';
import 'package:my_comic/src/media/manga/library/manga_chapter_download_state.dart';
import 'package:my_comic/src/media/manga/library/manga_chapter_list.dart';
import 'package:my_comic/src/media/manga/library/manga_cover_resolution.dart';
import 'package:my_comic/src/media/manga/library/manga_download_planner.dart';
import 'package:my_comic/src/media/manga/library/manga_first_page_cover_service.dart';
import 'package:my_comic/src/media/manga/library/manga_resume_point.dart';
import 'package:my_comic/src/media/manga/library/manga_shelf_removal_dialog.dart';
import 'package:my_comic/src/media/manga/library/manga_shelf_removal_service.dart';
import 'package:my_comic/src/media/manga/manga_cover_placeholder.dart';
import 'package:my_comic/src/media/manga/manga_global_search_page.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_enabled_sources.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_manager.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:my_comic/src/media/selection/media_selection_controller.dart';
import 'package:my_comic/src/media/selection/selection_gestures.dart';
import 'package:my_comic/src/media/tags/tag_picker_sheet.dart';
import 'package:my_comic/src/utils/components/batch_action_bar.dart';
import 'package:my_comic/src/utils/components/section_visibility.dart';
import 'package:my_comic/src/utils/misc/reveal_in_file_manager.dart'
    show currentRevealHost, revealFirstOf;
import 'package:my_comic/src/media/display_title.dart';
import 'package:my_comic/src/media/media_item.dart';
import 'package:my_comic/src/media/online/online_source_error_text.dart';
import 'package:my_comic/src/media/online/online_work_detail.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_service.dart';
import 'package:my_comic/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:my_comic/src/media/manga/reader/manga_my_comic_page.dart';
import 'package:my_comic_engine/media/manga/reader_position.dart'
    show ReaderPosition, ReaderPositionRepository;
import 'package:my_comic/src/media/sources/manga_my_comic_source.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/models/app_model.dart';
import 'package:my_comic/src/utils/components/my_comic_staggered_entrance.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/src/utils/net/app_http_image.dart';
import 'package:my_comic/src/utils/misc/error_details_dialog.dart';
import 'package:my_comic/src/utils/misc/trimmed_text.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_library.dart';
import 'package:url_launcher/url_launcher.dart';

/// 作品页要显示**哪一部**作品。
///
/// 两个变体的差别只在「条目从哪来、能不能落库」，头部、章节列表、阅读入口全部
/// 是同一套代码——所以这里用 sealed 穷尽，而不是给页面塞一堆可空参数再靠
/// 「恰有一个非空」的隐式约定分流（与 `MihonBrowseTarget` 同款处理）。
sealed class MangaSeriesTarget {
  const MangaSeriesTarget();
}

/// 已在书架的条目。**只带 bookKey**：作品页因此不需要任何来源上下文就能开，
/// 源挂了、扩展被禁用、甚至离线，用户依然能看到自己书架里这部作品有哪些章。
class ShelfMangaSeriesTarget extends MangaSeriesTarget {
  const ShelfMangaSeriesTarget(this.bookKey, {this.item, this.showShelfMenu});

  final String bookKey;

  /// 书架传进来的媒体条目。开阅读器时原样交回 `AppModel.openMedia`，让沉浸
  /// 模式、wakelock、audio handler、历史记账与 v88 前逐字相同。书架以外的入口
  /// （源浏览）没有它，开阅读器时现造一条。
  final MediaItem? item;

  /// 书架卡的长按菜单（删除 / 重命名 / 统计 / 合集 / 标签 / Profile / 转格式…）。
  ///
  /// 作品页打开的是**同一个**对话框，不另抄一份动作：那些动作绑着书架的状态
  /// （读完集合、远端清单、模块快照、刷新纪律），且一律先 pop 掉菜单对话框——
  /// 拆成作品页按钮的话第一下就会把作品页自己弹掉。书架以外的入口为 null，
  /// 作品页就不露这一项。
  final Future<void> Function()? showShelfMenu;
}

/// 还没入库的在线作品，来自一次源浏览。
///
/// [seed] 的 `chapters` 通常是空的（网格上只有标题和封面），进页后由
/// [OnlineMangaLibraryService.refreshFromSource] 拉齐。
class SourceMangaSeriesTarget extends MangaSeriesTarget {
  const SourceMangaSeriesTarget({
    required this.adapter,
    required this.seed,
    this.service,
    this.sourceLabel,
    this.remoteCoverBuilder,
  });

  /// 拉详情/章节/页面用的运行时半边。
  ///
  /// **只给 adapter 就能把这一页显示出来**：源浏览进来的作品还没入库，展示它不该
  /// 需要数据库、更不该需要整个 AppModel（那会让「点开一个作品」依赖应用初始化，
  /// 也让这条路径没法在 widget 测试里单独立起来）。
  final OnlineMangaRuntimeAdapter adapter;

  final OnlineMangaLibraryEntry seed;

  /// 书架半边。缺席时页面照常展示，只是「加入书架」不可用——由页面按需从
  /// AppModel 解析；解析不到就保持缺席，不炸页面。
  final OnlineMangaLibraryService? service;

  final String? sourceLabel;

  /// 未入库时怎么画封面。
  ///
  /// 入库后封面走本地落盘那张（作品页首屏不该依赖网络）；但**还没入库**时本地
  /// 什么都没有，只能由来源自己提供取图控件——Mihon 要经扩展的 imageProxy 带鉴权
  /// 头，各运行时的取图方式没有公共分母。作品页因此不自己开取图路径，只留这个
  /// 口子。
  final Widget Function(BuildContext context)? remoteCoverBuilder;
}

/// 还没入库的本地图源作品，来自「本地图源」的扫描网格（[LocalSourceManga]）。
///
/// 与 [SourceMangaSeriesTarget] 的差别：没有在线运行时，封面与章节描述都在
/// 扫描结果里，页面不联网、也不要求数据库行。显式「加入书架」才调用单部作品
/// 登记入口原地登记（ADR 0013）；已移出书架（tombstone）但文件仍在的作品同样
/// 从这里打开，显式加入会清墓碑重新登记。
class LocalSourceMangaSeriesTarget extends MangaSeriesTarget {
  const LocalSourceMangaSeriesTarget(this.manga);

  final LocalSourceManga manga;
}

/// 漫画作品页。
///
/// 这一层在 v88 前**根本不存在**：书架点开漫画直接钻进 `MangaMyComicPage` 的某一
/// 章，而那一章由 `currentChapterIndex` 决定、第一次开书就被钉死成最旧的一话。
/// 于是「加入书架后只能看第一章」——章节列表明明已经完整存在
/// `sourceMetadata` 里，却没有任何界面展示它，唯一的章节列表藏在
/// 发现→来源→搜索→详情 的深处，而那个页面构造需要源上下文，书架够不着。
///
/// 设计要点：
/// - **已入库作品手动刷新**。首屏只读库里的描述符与章节缓存，一次网络调用都
///   不发；用户通过「⋯ → 刷新章节」在本页手动拉取。未入库的来源作品仍自动
///   拉取一次详情与章节；已入库但缓存章节为空时兜底拉取一次，避免空页。
///   刷新失败只在顶部挂一条可重试的提示条，不遮挡任何已有内容。
/// - **与运行时无关**。只跟 [OnlineMangaLibraryService] 打交道，Mihon 与
///   互联对端走同一条路径。
/// - **本地卷也进这里**（用户明确要求的一致性）：本地 mokuro 卷没有章节，
///   章节区换成页数/进度，不假装有章节列表。
class MangaSeriesPage extends ConsumerStatefulWidget {
  const MangaSeriesPage({required this.target, super.key, this.openExternal});

  final MangaSeriesTarget target;

  /// 测试缝：「在网站打开」默认用系统浏览器（[launchUrl]）。
  final Future<void> Function(Uri url)? openExternal;

  @override
  ConsumerState<MangaSeriesPage> createState() => _MangaSeriesPageState();
}

class _MangaSeriesPageState extends ConsumerState<MangaSeriesPage> {
  EpubBookRow? _row;
  OnlineMangaLibraryEntry? _entry;

  /// Program state 里已有真实来源封面字节时的 `file://` URL（ticket 02 封面
  /// 优先级：本地 cover.* → 真实来源封面 → 第一页生成封面 → 占位）。
  String? _shelfCachedCoverUrl;

  /// 第一页生成封面的缓存 `file://` URL；null = 还没有可用生成封面。
  String? _generatedCoverUrl;

  /// 生成封面服务（Program state 缓存 + 数据库映射）；测试可注入覆盖。
  MangaFirstPageCoverService? _firstPageCoverServiceCache;

  /// Local source（`local`）条目：`sourceMetadata` 标记 + 章节表。
  /// 有它时章节区按共享章节列表渲染，`_entry` 保持 null（不是在线条目）。
  LocalSourceMetadata? _localSource;
  List<LocalSourceChapterRecord> _localChapters =
      const <LocalSourceChapterRecord>[];

  /// 从「本地图源」网格点开的**未入库**作品（扫描结果）。为空表示这次打开
  /// 不是那种状态；显式加入书架后清空并切换成正常书架条目。
  LocalSourceManga? _scannedLocal;

  /// Local source 作品目录已不在当前 `local` 根内（典型：切换 Content root
  /// 后库里仍记着旧根）。这些章显示为 Missing，阅读入口拒绝回读旧路径。
  Set<String> _localMissingChapterKeys = const <String>{};

  OnlineMangaLibraryService? _service;
  OnlineMangaRuntimeAdapter? _adapter;
  Map<String, MangaChapterStateRow> _states =
      const <String, MangaChapterStateRow>{};
  String? _sourceLabel;

  /// 来源名解析是否已经结束（成功拿到名称，或确认解析不到）。
  ///
  /// 只在确认解析不到后才显示「来源未安装」提示块：安装扩展后经数字 sourceId
  /// 回退能解析出真实名称（票 03），那期间不该闪一下缺失提示。来源标签本身
  /// 仍即时降级，不露出 `mihon.unavailable`。
  bool _sourceLabelResolved = false;

  /// 运行时确认解析不到来源（未安装、已停用或 sourceId 歧义）。
  ///
  /// 只对 Mihon 条目有意义：占位来源是「导入时未安装」，而已安装但停用的
  /// Source 没有占位包，也必须按缺失来源展示。
  bool _sourceMissing = false;

  /// 缺失来源的友好名称：优先 Source 表（停用的 Source 行仍有名称），否则
  /// 用描述符里持久化的备份名称。只在 [_sourceMissing] 或占位条目时使用。
  String? _missingSourceName;

  bool _loading = true;
  bool _refreshing = false;

  /// 至少成功从源刷过一次。空章节列表的语言解释只在这之后出现：进页那一刻的
  /// seed 本来就是空的，那时提示「该源只收录 X 语言」是把「还没拉」说成「拉完了
  /// 没有」。
  bool _refreshSucceeded = false;
  bool _busy = false;
  Object? _fatalError;
  OnlineMangaUnavailable? _refreshError;
  Future<void> Function()? _challengeRetry;

  /// 章节排序：初值读全局偏好（阅读器章节抽屉同一份），切换即写回。
  bool _newestFirst = true;
  bool _unreadOnly = false;

  /// 章节下载筛选（ticket 06）：与「只看未读」一样是会话内状态，不持久化。
  MangaChapterDownloadFilter _downloadFilter = MangaChapterDownloadFilter.all;

  /// 章节多选状态机（与书架 / 本地图源页共用 [MediaSelectionController]）。
  /// 选择状态放在作品页级，不放进会随下载状态重建的章节行子树里。选中键 = 章节 key。
  final MediaSelectionController _selection = MediaSelectionController();

  /// 批量已读 / 未读进行中：防止重复点击与并发写库。
  bool _batchRunning = false;

  bool get _selectionMode => _selection.active;

  /// 正文滚动（窄屏整页 / 宽屏右栏）：快速滚动条与「跳到当前章节」都挂在它上。
  final ScrollController _scroll = ScrollController();
  final GlobalKey _currentChapterAnchor = GlobalKey(
    debugLabel: 'manga_series_current_chapter',
  );

  /// 下载状态位（设计稿 2026-09-12 §5）：任务行 + 磁盘判据，两份合成章节行上
  /// 的一个状态。任务表一变就整体重算。
  Map<String, MangaDownloadJobRow> _jobs =
      const <String, MangaDownloadJobRow>{};
  Set<String> _downloaded = const <String>{};

  /// [_downloaded] 中可由「删除下载」删除的章（容器在当前 Download library
  /// 根内）。Local source root 下的用户原件显示已下载但不可删。
  Set<String> _deletableDownloaded = const <String>{};
  StreamSubscription<void>? _jobsWatch;

  /// manifest 扫描缓存（ticket 07）：任务表进度更新不会改变身份/状态签名，
  /// 不必每次都把整个 `downloads` + `local` 重扫一遍。
  Set<String> _manifestDownloaded = const <String>{};
  String? _manifestScanKey;

  /// 并发重算的代号：任务表事件与页面加载/刷新可能同时触发，只让最后一轮
  /// 写回状态，避免旧结果覆盖新一轮章节表。
  int _downloadStateRevision = 0;

  /// 本地卷的阅读位置（`sectionIndex` = 页号，阅读器 `_persistPosition` 写）。
  ReaderPosition? _localPosition;

  /// 本地卷的库写入通知（[_watchLocalVolume]）；读取按代次只认最后一次。
  StreamSubscription<Set<TableUpdate>>? _localVolumeChanges;
  int _localVolumeGeneration = 0;

  AppModel get _appModel => ref.read(appProvider);

  Widget _challengeAction(Object? error) => MihonCloudflareAction(
    runtime: switch (_adapter) {
      MihonLibraryAdapter(:final manager) => manager.runtime,
      _ => null,
    },
    error: error,
    onVerified: () => (_challengeRetry ?? _refreshFromSource)(),
  );

  /// 取 AppModel，取不到返回 null。
  ///
  /// 源浏览进来的作品页可以活在没有 `ProviderScope` 的树里（widget 测试就是这么
  /// 立起来的），而它展示所需的一切都在 target 的 adapter 里。所以「拿不到
  /// AppModel」是一种**正常状态**，不是错误：只是不能碰书架而已。
  AppModel? get _appModelOrNull {
    try {
      return ref.read(appProvider);
    } on Object {
      return null;
    }
  }

  /// 第一页生成封面服务；Program state 缓存根不可用（启动早期 / 测试壳）时
  /// 返回 null，作品页退回本地 / 持久缓存 / 占位。
  MangaFirstPageCoverService? _firstPageCoverService() {
    final MangaFirstPageCoverService? cached = _firstPageCoverServiceCache;
    if (cached != null) return cached;
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return null;
    try {
      return _firstPageCoverServiceCache =
          MangaFirstPageCoverService.forAppCache(
            database: appModel.database,
            cacheRoot: appModel.appPathsOrNull?.cacheRoot,
          );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.firstPageCoverService',
        error,
        stack,
      );
      return null;
    }
  }

  /// 书架半边，按需解析。解析不到就一直是 null，页面照常展示。
  OnlineMangaLibraryService? _shelfServiceFor(OnlineMangaLibraryEntry entry) {
    final OnlineMangaLibraryService? existing = _service;
    if (existing != null) return existing;
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return null;
    try {
      return _service = appModel.onlineMangaLibraryService(entry.runtime);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.resolveService',
        error,
        stack,
      );
      return null;
    }
  }

  /// 在库时的 bookKey；未入库的源条目为 null。
  String? get _bookKey => _row?.bookKey;

  String? get _bookUid {
    final String? uid = _row?.uid;
    return uid == null || uid.isEmpty ? null : uid;
  }

  /// 本地卷（无在线描述符）。
  bool get _isLocal => _entry == null && _row != null;

  /// `local` 里原地读取的本地图源作品（有章节表）：已在书架的条目，或刚从
  /// 「本地图源」网格打开、还没登记的扫描结果。
  bool get _isLocalSource => _localSource != null || _scannedLocal != null;

  /// 未入库的本地图源扫描结果（本地图源网格 → 作品页，尚未登记）。
  bool get _isScannedLocal => _scannedLocal != null;

  /// 本地图源「继续阅读」落到哪一章。
  ///
  /// 先回到上次读到的章（`currentChapterKey`）；按「重新打开位置」偏好已经读完
  /// 这一章时前进到下一个未读章。后面没有未读章就停在当前章（读到最后一话时
  /// 就是最后一章），**不**回落到更早的未读章——与在线源
  /// [continueMangaChapterIndex] 的「读到最新一话就停在原地」一致。只有没有
  /// 当前章（`currentChapterKey` 缺失或失配）时才从第一个未读章开始，全读完
  /// 停在最后一章。本地顺序是第 1 话→第 N 话，前进方向与在线源相反（下标 +1）。
  int get _localResumeIndex {
    if (_localChapters.isEmpty) return -1;
    final MangaResumeTarget target = MangaResumeTargetKey.fromKey(
      _appModelOrNull?.mangaResumeTarget ?? kMangaResumeTargetDefault,
    );
    final String? currentKey = _localSource?.currentChapterKey;
    if (currentKey != null) {
      final int currentIndex = _localChapters.indexWhere(
        (LocalSourceChapterRecord chapter) => chapter.key == currentKey,
      );
      if (currentIndex >= 0) {
        final MangaChapterStateRow? state = _states[currentKey];
        final bool advance =
            state != null &&
            switch (target) {
              MangaResumeTarget.furthestProgress => state.readAt != null,
              MangaResumeTarget.lastPosition => mangaChapterStoppedAtEnd(state),
            };
        if (!advance) return currentIndex;
        for (int i = currentIndex + 1; i < _localChapters.length; i++) {
          if (_states[_localChapters[i].key]?.readAt == null) return i;
        }
        // 后面没有未读章：停在当前章（当前章即最后一章时也就是最后一章）。
        return currentIndex;
      }
    }
    final int unread = _localChapters.indexWhere(
      (LocalSourceChapterRecord chapter) =>
          _states[chapter.key]?.readAt == null,
    );
    return unread >= 0 ? unread : _localChapters.length - 1;
  }

  /// 借给共享 [MangaChapterList] 的展示条目。只在本地图源上使用，不落库、
  /// 不参与在线 service 分派。
  OnlineMangaLibraryEntry? get _localDisplayEntry {
    if (_localChapters.isEmpty) return null;
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) {
      return localSourceMangaLibraryEntry(
        seriesKey: localSourceBookKeyFor(scanned.directoryPath),
        title: scanned.title,
        chapters: _localChapters,
      );
    }
    final EpubBookRow? row = _row;
    if (_localSource == null || row == null) return null;
    final String? currentKey = _localSource!.currentChapterKey;
    final int currentIndex = currentKey == null
        ? -1
        : _localChapters.indexWhere(
            (LocalSourceChapterRecord chapter) => chapter.key == currentKey,
          );
    return localSourceMangaLibraryEntry(
      seriesKey: row.bookKey,
      title: row.title,
      chapters: _localChapters,
      currentChapterIndex: currentIndex >= 0 ? currentIndex : null,
    );
  }

  /// 页头 / 识别横幅上的标题。本地卷走书架同一个显示名门面（改名是覆盖层，
  /// 不写 `epub_books.title`），否则从这里「管理本卷 › 重命名」之后页头不变。
  String get _displayTitle {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry != null) return entry.series.title;
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) return scanned.title;
    final EpubBookRow? row = _row;
    if (row == null) return t.manga_library;
    return displayTitleForBook(bookKey: row.bookKey, rawTitle: row.title);
  }

  /// 作者 chip 的文案：在线作品取 [OnlineMangaSeries.byline]（作者优先、画师
  /// 兜底），本地卷取书架行的作者。本地卷与互联对端与在线漫画同一口径。
  String? get _authorLine {
    final String? byline = _entry?.series.byline?.trim();
    if (byline != null && byline.isNotEmpty) return byline;
    if (!_isLocal) return null;
    final String? author = _row?.author?.trim();
    return author == null || author.isEmpty ? null : author;
  }

  @override
  void initState() {
    super.initState();
    _newestFirst = _appModelOrNull?.mangaChapterListNewestFirst ?? true;
    // 票 12：重建下载索引可能在页面打开期间写映射 / 关联，完成后立刻重算
    // 已下载状态（manifest 扫描缓存同时失效），不需要重新进入页面。
    DownloadLibraryChanges.instance.addListener(_onDownloadLibraryChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    DownloadLibraryChanges.instance.removeListener(_onDownloadLibraryChanged);
    unawaited(_jobsWatch?.cancel());
    _jobsWatch = null;
    unawaited(_localVolumeChanges?.cancel());
    _scroll.dispose();
    super.dispose();
  }

  /// Rebuild download index 完成：作废 manifest 扫描缓存并重算下载状态。
  ///
  /// 只清缓存不够——页面可能正停在同一身份 / 章节表上，任务表没有变化就不会
  /// 自动重算。这里直接触发一轮 [_refreshDownloadState]。
  void _onDownloadLibraryChanged() {
    _manifestScanKey = null;
    if (!mounted) return;
    unawaited(_refreshDownloadState());
  }

  /// 重算下载状态位并（首次）订阅任务表。
  ///
  /// Ticket 07：不再要求 Library 行。有行时走记录的章节映射；没有映射 / 没有
  /// 行的章再按 entry 身份扫描 `downloads` 与 `local` 的 `pages.json`（无
  /// manifest 的目录不按标题猜测）。
  Future<void> _refreshDownloadState() async {
    final int revision = ++_downloadStateRevision;
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return;

    // Local source（ADR 0013）：作品目录必须仍在**当前** `local` 根内。
    // 切换 Content root 后库里的旧路径不重基，这里把整部作品的章标成 Missing，
    // 不再从旧根读取。
    //
    // Ticket 10：源未安装时恢复出来的本地条目指向当前 `downloads` 根里的漫画
    // 目录，同样算「在当前内容根内」，不能整本标 Missing。
    if (_isLocalSource) {
      if (row == null) return;
      final bool withinLocal = isLocalSourcePathWithinRoot(
        row.extractDir,
        appModel.appPaths.localComicRoot,
      );
      final bool withinDownloads = isLocalSourcePathWithinRoot(
        row.extractDir,
        appModel.appPaths.downloadsRoot,
      );
      final bool missing =
          (!withinLocal && !withinDownloads) ||
          !await Directory(row.extractDir).exists();
      final Set<String> next = missing
          ? _localChapters.map((LocalSourceChapterRecord c) => c.key).toSet()
          : const <String>{};
      if (!mounted || revision != _downloadStateRevision) return;
      final bool changed =
          _localMissingChapterKeys.length != next.length ||
          !_localMissingChapterKeys.containsAll(next);
      if (changed) {
        setState(() => _localMissingChapterKeys = next);
      }
      return;
    }

    if (entry == null) return;
    final MangaDownloadService downloads = appModel.mangaDownloadService;
    _jobsWatch ??= downloads.watchJobs().listen(
      (_) => unawaited(_refreshDownloadState()),
      onError: (Object error, StackTrace stack) {
        ErrorLogService.instance.log(
          'MangaSeriesPage.watchDownloads',
          error,
          stack,
        );
      },
    );
    // 非书架 / 无行时任务仍按 entry 身份推导出的 bookKey 落库。
    final String bookKey =
        row?.bookKey ?? OnlineMangaLibraryService.bookKeyOf(entry);
    final Map<String, MangaDownloadJobRow> jobs = await downloads.jobsForBook(
      bookKey,
    );
    final List<String> chapterKeys = <String>[
      for (final OnlineMangaChapter chapter in entry.chapters) chapter.key,
    ];
    final DownloadLibraryIndex index = DownloadLibraryIndex(
      appModel.database,
      downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
      localComicRoot: appModel.appPathsOrNull?.localComicRoot,
    );
    final Set<String> mapped = row == null
        ? <String>{}
        : await index.downloadedChapterKeys(bookKey, chapterKeys);
    // 身份 + 章节表 + 任务状态签名：进度更新（pagesDone）不触发全库重扫；
    // 章节表刷新、完成 / 取消 / 删除等状态变化会。
    final String scanKey =
        '${entry.runtime.wireValue}\u0000${entry.extensionPackage}\u0000'
        '${entry.sourceId}\u0000${entry.series.key}\u0000'
        '${chapterKeys.join('\u0001')}\u0000'
        '${<String>[for (final MangaDownloadJobRow job in jobs.values) '${job.jobId}:${job.status}'].join('|')}';
    if (_manifestScanKey != scanKey) {
      final MangaDownloadIdentity identity = MangaDownloadIdentity.ofEntry(
        entry,
      );
      final Set<String> scanned = chapterKeys.isEmpty
          ? const <String>{}
          : (await index.scanDisks(
              queries: <MangaDownloadDiskQuery>[
                MangaDownloadDiskQuery.ofEntry(entry),
              ],
            )).downloadedChapterKeys(identity, chapterKeys);
      if (!mounted || revision != _downloadStateRevision) return;
      _manifestDownloaded = scanned;
      _manifestScanKey = scanKey;
    }
    final Set<String> downloaded = <String>{...mapped, ..._manifestDownloaded};
    // 可删性独立于「已下载」：Local source 根下的用户原件也算已下载，但删除
    // 下载不得提供会清掉用户文件的操作。
    final Set<String> deletable = await index.deletableChapterKeysForEntry(
      entry,
      row: row,
      downloadedChapterKeys: downloaded,
    );
    if (!mounted || revision != _downloadStateRevision) return;
    setState(() {
      _jobs = jobs;
      _downloaded = downloaded;
      _deletableDownloaded = deletable;
    });
  }

  /// 用户主动删掉下载后：让 manifest 扫描缓存失效，并立即把章节行切回未下载。
  ///
  /// 删除后的重算是异步的（要探磁盘），不能让已删的章在等待期间继续显示
  /// 「已下载」；下一轮 [_refreshDownloadState] 会从映射 + manifest 重建。
  void _forgetDownloadedChapters(Iterable<String> chapterKeys) {
    _manifestScanKey = null;
    final Set<String> keys = chapterKeys.toSet();
    _manifestDownloaded = _manifestDownloaded.difference(keys);
    if (keys.isEmpty) return;
    void apply() {
      _downloaded = _downloaded.difference(keys);
      _deletableDownloaded = _deletableDownloaded.difference(keys);
    }

    if (mounted) {
      setState(apply);
    } else {
      apply();
    }
  }

  Future<void> _enqueueChapter(OnlineMangaChapter chapter) async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null) return;
    try {
      final MangaDownloadJobRow job = await appModel.mangaDownloadService
          .enqueueChapter(entry: entry, chapter: chapter, autoOcr: false);
      // 票 08：源页可能还没有行（书架半边暂时不可用）；入队会按下载身份补一条
      // 非书架行。把这条真实行接回页面，任务列表 / 已下载状态 / 删除下载与
      // 「加入书架？」提示才有稳定的 bookKey。
      await _adoptDownloadRow(job.bookKey);
      if (mounted) MyComicToast.show(msg: t.manga_chapter_download_queued);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.enqueue', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
    await _refreshDownloadState();
  }

  /// 入队后把任务真实使用的 Manga 行接回页面状态。
  Future<void> _adoptDownloadRow(String bookKey) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return;
    final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
    if (!mounted || row == null || _row?.bookKey == row.bookKey) return;
    setState(() => _row = row);
  }

  /// 批量入队后按 entry 的下载身份找回真实行（占位包 / 数字 sourceId 回退）。
  Future<void> _syncDownloadRow() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null) return;
    final OnlineMangaLibraryService? service =
        _service ?? _shelfServiceFor(entry);
    final EpubBookRow? row = service != null
        ? await service.find(entry)
        : await appModel.database.getEpubBook(
            OnlineMangaLibraryService.bookKeyOf(entry),
          );
    if (!mounted || row == null || _row?.bookKey == row.bookKey) return;
    setState(() => _row = row);
  }

  Future<void> _retryChapterDownload(OnlineMangaChapter chapter) async {
    final MangaDownloadJobRow? job = _jobs[chapter.key];
    final AppModel? appModel = _appModelOrNull;
    if (job == null || appModel == null) return;
    await appModel.mangaDownloadService.retry(job.jobId);
    await _refreshDownloadState();
  }

  /// 在系统文件管理器里定位某章的本地下载：优先选中该章 manifest
  /// （`pages.json`），不在了再退回打开章目录；都打不开才提示。
  Future<void> _revealChapterDownload(OnlineMangaChapter chapter) async {
    final EpubBookRow? row = _row;
    final AppModel? appModel = _appModelOrNull;
    if (row == null || appModel == null) return;
    final MangaChapterContainer? container = await DownloadLibraryIndex(
      appModel.database,
    ).resolveChapter(bookKey: row.bookKey, chapterKey: chapter.key);
    if (container == null) {
      if (mounted) {
        MyComicToast.show(
          msg: t.media_file_location_failed,
          severity: ToastSeverity.error,
        );
      }
      return;
    }
    final bool revealed = await revealFirstOf(
      container.isArchive
          ? <String>[container.archiveFile!.path]
          : <String>[container.manifestFile!.path, container.directory!.path],
    );
    if (revealed || !mounted) return;
    MyComicToast.show(
      msg: t.media_file_location_failed,
      severity: ToastSeverity.error,
    );
  }

  /// 删除某章的本地下载。
  ///
  /// 2026-10 体验优化：原先菜单一点即删整章页图（重下要再跑一遍网络 + OCR），
  /// 先确认（写明章名），删完给 Toast。
  Future<void> _deleteChapterDownload(OnlineMangaChapter chapter) async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null || entry == null) return;
    // 菜单已对不可删的章隐藏；这里再挡一次并发状态变化，避免 job 行被清掉后
    // 页面把仍然存在的用户文件显示成「未下载」。
    if (!_deletableDownloaded.contains(chapter.key)) return;
    final bool confirmed = await showMyComicConfirmDialog(
      context: context,
      title: t.manga_chapter_download_delete_action,
      message: chapter.name,
      icon: MyComicIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    try {
      // 票 08：非书架 / 无 Library 行也能删。有映射按映射删；没有时按 entry
      // 的下载身份找唯一匹配的目录，不按标题猜。
      await DownloadLibraryIndex(
        appModel.database,
        downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
        localComicRoot: appModel.appPathsOrNull?.localComicRoot,
      ).deleteChapterForEntry(entry: entry, chapterKey: chapter.key, row: row);
      // Ticket 02：done 任务行是「这章曾经下载过」的持久标记。用户主动删除
      // 下载时必须一起清掉，否则磁盘判据变 false、任务仍 done → 被误显示成
      // Missing。缺失文件本身（便携拷贝没带 content）不走这里，保留 Missing。
      final MangaDownloadJobRow? job = _jobs[chapter.key];
      if (job != null) {
        await appModel.mangaDownloadService.remove(job.jobId);
      }
      _forgetDownloadedChapters(<String>[chapter.key]);
      if (mounted) MyComicToast.show(msg: t.storage_entry_delete_done);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.deleteDownload',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
    await _refreshDownloadState();
  }

  /// 「下载全部」：未下载且没有排队 / 执行中任务的章按章序（旧 → 新）入队。
  /// 已下载、已在队列里的不重复入队；一章都没有可下的就说清楚。
  Future<void> _downloadAll() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null) return;
    // 锁定章（未登录 / 未购买）入队必败，整批跳过并说清楚跳了几个；用户登录并
    // 刷新后它们会脱锁，再点一次即可（BUG-2479）。规划规则与书架批量下载共用
    // [planMangaChapterDownload]（review D2）。
    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        planMangaChapterDownload(
          entry: entry,
          downloadedChapterKeys: _downloaded,
          jobsByChapterKey: _jobs,
        );
    final int lockedSkipped = plan.lockedSkipped;
    final List<OnlineMangaChapter> pending = plan.pending;
    if (lockedSkipped > 0) {
      MyComicToast.show(
        msg: t.manga_series_download_all_locked_skipped(count: lockedSkipped),
      );
    }
    if (pending.isEmpty) {
      if (lockedSkipped == 0) {
        MyComicToast.show(msg: t.manga_series_download_all_none);
      }
      return;
    }
    try {
      await appModel.mangaDownloadService.enqueueChapters(
        entry: entry,
        chapters: pending,
        autoOcr: false,
      );
      await _syncDownloadRow();
      if (mounted) {
        MyComicToast.show(
          msg: t.manga_series_download_all_queued(count: pending.length),
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.downloadAll', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
    await _refreshDownloadState();
  }

  /// 点了锁定章：源站要登录并购买 / 租借才给页。弹窗给三条路——登录该源、
  /// 仍然下载（用户确信自己已解锁、只是列表没刷新）、取消。
  ///
  /// 返回 true = 继续入队下载。选「登录」时登录完自动刷新章节列表（锁位跟着
  /// 变），本次不入队。
  Future<bool> _promptLockedChapter(OnlineMangaChapter chapter) async {
    // 按章问「登录能不能解开」，不是按源：能登录的源也有登录后照样读不了的章
    // （BUG-2514 quirk 章），那时不给「登录」按钮、提示改成说清楚。
    final OnlineMangaLibraryEntry? entry = _entry;
    final OnlineMangaLoginTarget? login = switch (_adapter) {
      OnlineMangaLoginCapable(:final loginTargetForChapter)
          when entry != null =>
        loginTargetForChapter(entry, chapter),
      _ => null,
    };
    final bool loginUnavailable = login == null && _loginTarget != null;
    if (!mounted) return false;
    final _LockedChapterChoice?
    choice = await showAppDialog<_LockedChapterChoice>(
      context: context,
      builder: (BuildContext dialogContext) => MyComicAlertDialog.adaptive(
        key: const ValueKey<String>('manga_chapter_locked_dialog'),
        title: Text(t.manga_chapter_locked_title),
        content: Text(
          '${chapter.name}\n\n'
          '${loginUnavailable ? t.manga_chapter_locked_login_unsupported_hint : t.manga_chapter_locked_hint}',
        ),
        actions: <Widget>[
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.dialog_cancel),
          ),
          adaptiveDialogAction(
            context: dialogContext,
            onPressed: () =>
                Navigator.pop(dialogContext, _LockedChapterChoice.download),
            child: Text(t.manga_chapter_locked_download_anyway),
          ),
          if (login != null)
            KeyedSubtree(
              key: const ValueKey<String>('manga_chapter_locked_login'),
              child: adaptiveDialogAction(
                context: dialogContext,
                isDefaultAction: true,
                onPressed: () =>
                    Navigator.pop(dialogContext, _LockedChapterChoice.login),
                child: Text(t.mihon_source_login),
              ),
            ),
        ],
      ),
    );
    switch (choice) {
      case _LockedChapterChoice.download:
        return true;
      case _LockedChapterChoice.login:
        if (login != null) await _loginToSource(login);
        return false;
      case null:
        return false;
    }
  }

  /// 当前条目所属源的登录目标；适配器没这条流程（Aidoku / 互联对端）或源不接受
  /// 浏览器登录时为 null——AppBar 的登录按钮与锁章弹窗的「登录」项共用这一判据。
  OnlineMangaLoginTarget? get _loginTarget {
    final OnlineMangaLibraryEntry? entry = _entry;
    return switch (_adapter) {
      OnlineMangaLoginCapable(:final loginTarget) when entry != null =>
        loginTarget(entry),
      _ => null,
    };
  }

  /// 空章节列表的语言解释（BUG-2510）：只在「刷新成功结束、0 话」时给。刷新
  /// 途中是加载态、失败有提示条，那两种情况下都不该出现「该源只收录 X 语言」。
  OnlineMangaSourceLanguageScope? get _languageScope {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null ||
        entry.chapters.isNotEmpty ||
        _refreshing ||
        !_refreshSucceeded ||
        _refreshError != null) {
      return null;
    }
    return switch (_adapter) {
      OnlineMangaLanguageScoped(:final languageScope) => languageScope(entry),
      _ => null,
    };
  }

  /// 同一部作品换到同扩展的另一语言源看：开一页新的作品页，不动本页与书架状态
  /// （用户在那页决定要不要把那个源的版本加进书架）。
  Future<void> _openSiblingSource(OnlineMangaSiblingSource sibling) async {
    // 声明成 Object?：OnlineMangaLanguageScoped 不是 OnlineMangaRuntimeAdapter
    // 的子类型，`is!` 对 `OnlineMangaRuntimeAdapter?` 局部变量不提升。
    final Object? adapter = _adapter;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (adapter is! OnlineMangaLanguageScoped || entry == null || _busy) {
      return;
    }
    setState(() => _busy = true);
    final ({OnlineMangaRuntimeAdapter adapter, OnlineMangaLibraryEntry seed})
    handle;
    try {
      handle = await adapter.siblingOf(entry, sibling);
    } on OnlineMangaUnavailable catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.sibling', error, stack);
      if (mounted) {
        MyComicToast.show(msg: error.userMessage, severity: ToastSeverity.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaSeriesPage(
          target: SourceMangaSeriesTarget(
            adapter: handle.adapter,
            seed: handle.seed,
            service: _service,
            sourceLabel: sibling.name,
            // 封面照本页的画法（本地落盘那张 / 源代理取图）：同一部作品、同一个
            // 扩展，取图路径一样，本页还压在导航栈里没销毁。
            remoteCoverBuilder: _buildCover,
          ),
        ),
      ),
    );
  }

  /// 「在网站打开」：作品在源站的网页（扩展的 `getMangaUrl`，兜底 baseUrl + url）
  /// 交给系统浏览器。打不开浏览器不算本页错误，只提示。
  Future<void> _openWebsite(
    OnlineMangaWebUrlCapable adapter,
    OnlineMangaLibraryEntry entry,
  ) async {
    final Uri? url = await adapter.webUrl(entry);
    if (!mounted) return;
    if (url == null) {
      MyComicToast.show(
        msg: t.mihon_source_website_unavailable,
        severity: ToastSeverity.warning,
      );
      return;
    }
    try {
      await (widget.openExternal ?? _launchExternal)(url);
    } on Object catch (error) {
      if (!mounted) return;
      MyComicToast.show(
        msg: describeOnlineSourceError(error),
        severity: ToastSeverity.error,
      );
    }
  }

  static Future<void> _launchExternal(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }

  /// 书名 / 作者 / 源分类点击的去处：以当前显示的文字为关键词打开「搜索全部
  /// 来源」，并自动检索全部已启用的在线 Source（Source 自身启用且提供它的
  /// Extension 也启用）。
  ///
  /// 平台没有扩展运行时（如 iOS）或运行时初始化失败时**仍打开搜索页**，只是
  /// 不传 manager / 来源——页面自己的空态会说明「没有可用来源」（spec：没有
  /// 运行时 / 可用来源时仍打开搜索页，由搜索页显示空态）。不接「去装来源」回调。
  void _openGlobalSearch(String rawQuery) {
    final String query = rawQuery.trim();
    if (query.isEmpty) return;
    MihonManager? manager;
    List<MangaOnlineSourceRow> sources = const <MangaOnlineSourceRow>[];
    final AppModel? appModel = _appModelOrNull;
    if (MihonRuntimeFactory.isSupported && appModel != null) {
      try {
        manager = appModel.mihonManager;
        sources = enabledMangaOnlineSources(manager);
      } on Object catch (error, stack) {
        // 运行时不可用不是用户的错，也不该让页面崩掉：降级成「没有可用来源」，
        // 搜索页照常打开并给出空态。
        ErrorLogService.instance.log(
          'MangaSeriesPage.globalSearch',
          error,
          stack,
        );
        manager = null;
        sources = const <MangaOnlineSourceRow>[];
      }
    }
    if (!mounted) return;
    unawaited(
      Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) => MangaGlobalSearchPage(
            mihonManager: manager,
            mihonSources: sources,
            initialQuery: query,
          ),
        ),
      ),
    );
  }

  Future<void> _loginToSource(OnlineMangaLoginTarget target) async {
    final bool saved = await openMihonWebLogin(
      context,
      runtime: target.runtime,
      sourceName: target.sourceName,
      baseUrl: target.baseUrl,
    );
    if (!mounted || !saved) return;
    MyComicToast.show(msg: t.mihon_source_login_saved);
    // 登录态变了，章节的锁位跟着变：立刻从源重取，用户不用自己想到去点刷新。
    await _refreshFromSource();
  }

  /// 书签 = 订阅开关：开订阅时默认同时开「新章自动下载」；关订阅把两位一起关
  /// （没有订阅的自动下载没有意义，探针只看 autoDownload）。
  Future<void> _toggleSubscription() async {
    final bool subscribed = !(_entry?.subscribed ?? false);
    await _writeSubscription(subscribed: subscribed, autoDownload: subscribed);
  }

  Future<void> _toggleAutoDownload() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return;
    await _writeSubscription(
      subscribed: entry.subscribed,
      autoDownload: !entry.autoDownload,
    );
  }

  Future<void> _writeSubscription({
    required bool subscribed,
    required bool autoDownload,
  }) async {
    final OnlineMangaLibraryService? service = _service;
    final OnlineMangaLibraryEntry? entry = _entry;
    final String? bookKey = _bookKey;
    if (service == null || entry == null || bookKey == null || _busy) return;
    try {
      final OnlineMangaLibraryEntry updated = await service.setSubscription(
        bookKey: bookKey,
        entry: entry,
        subscribed: subscribed,
        autoDownload: autoDownload,
      );
      if (mounted) setState(() => _entry = updated);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.subscribe', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  Future<void> _load() async {
    try {
      switch (widget.target) {
        case ShelfMangaSeriesTarget(:final String bookKey):
          await _loadFromShelf(bookKey);
        case SourceMangaSeriesTarget(
          :final OnlineMangaRuntimeAdapter adapter,
          :final OnlineMangaLibraryService? service,
          :final OnlineMangaLibraryEntry seed,
          :final String? sourceLabel,
        ):
          await _loadFromSource(adapter, service, seed, sourceLabel);
        case LocalSourceMangaSeriesTarget(:final LocalSourceManga manga):
          await _loadFromScannedLocalSource(manga);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.load', error, stack);
      if (mounted) setState(() => _fatalError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFromShelf(String bookKey) async {
    final EpubBookRow? row = await _appModel.database.getEpubBook(bookKey);
    if (row == null) {
      throw StateError('The book is no longer in the library: $bookKey');
    }
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    // Local source 条目的标记不是在线描述符；章节表住在 chaptersJson。
    final LocalSourceMetadata? localSource = LocalSourceMetadata.tryParse(
      row.sourceMetadata,
    );
    final List<LocalSourceChapterRecord> localChapters = localSource == null
        ? const <LocalSourceChapterRecord>[]
        : decodeLocalSourceChapters(row.chaptersJson);
    // 服务解析失败（平台不支持等）不该挡住离线渲染——章节列表已经在描述符里
    // 了，用户至少要能看见自己书架里有什么。
    final OnlineMangaLibraryService? service = entry == null
        ? null
        : _shelfServiceFor(entry);
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    final ReaderPosition? position = await _readLocalPosition(row, entry);
    if (!mounted) return;
    setState(() {
      _row = row;
      _entry = entry;
      _localSource = localSource;
      _localChapters = localChapters;
      _service = service;
      _adapter = service?.adapter;
      _states = states;
      _localPosition = position;
      _sourceLabel = null;
      _sourceLabelResolved = false;
      _sourceMissing = false;
      _missingSourceName = null;
      _shelfCachedCoverUrl = null;
      _generatedCoverUrl = null;
    });
    if (entry != null && service != null) {
      unawaited(_resolveSourceLabel(service.adapter, entry));
      // 已入库作品的刷新交给用户（「⋯ → 刷新章节」）：首屏只读缓存。唯一的
      // 例外是缓存里一章都没有——空页没法用，兜底拉一次。
      if (entry.chapters.isEmpty) {
        unawaited(_refreshFromSource(silent: true));
      }
    }
    // 本地卷没有下载任务表，[_refreshDownloadState] 在它身上第一行就返回——注册表
    // 只能在这里挂，否则「识别本卷」排上了作品页也看不见进度。
    if (entry == null) {
      _watchLocalVolume(row.bookKey);
    }
    unawaited(_refreshDownloadState());
    unawaited(_ensureGeneratedCover());
  }

  /// 从「本地图源」网格打开的扫描结果。
  ///
  /// 扫描结果不保证还没入库（网格里已入库的作品也照常出现）——先查库：有行就
  /// 走正常书架作品页，没有才进入「未入库」展示态。tombstoned 的作品没有行，
  /// 因此照常按未入库态展示；显式「加入书架」时插入路径会清墓碑（
  /// [LocalSourceLibrary.registerScannedManga]）。
  Future<void> _loadFromScannedLocalSource(LocalSourceManga manga) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel != null) {
      final String bookKey = localSourceBookKeyFor(manga.directoryPath);
      final EpubBookRow? existing = await appModel.database.getEpubBook(
        bookKey,
      );
      if (existing != null) {
        await _loadFromShelf(bookKey);
        return;
      }
    }
    final List<LocalSourceChapterRecord> chapters = <LocalSourceChapterRecord>[
      for (final LocalSourceChapter chapter in manga.chapters)
        LocalSourceChapterRecord(
          key: chapter.key,
          name: chapter.name,
          relativePath: chapter.relativePath,
        ),
    ];
    if (!mounted) return;
    setState(() {
      _row = null;
      _entry = null;
      _localSource = null;
      _scannedLocal = manga;
      _localChapters = chapters;
      _states = const <String, MangaChapterStateRow>{};
      _service = null;
      _adapter = null;
      _sourceLabel = null;
      _sourceLabelResolved = false;
      _sourceMissing = false;
      _missingSourceName = null;
      _shelfCachedCoverUrl = null;
      _generatedCoverUrl = null;
    });
    unawaited(_ensureGeneratedCover());
  }

  /// 本地卷才读：在线作品的进度按章记在 `manga_chapter_states`。
  Future<ReaderPosition?> _readLocalPosition(
    EpubBookRow row,
    OnlineMangaLibraryEntry? entry,
  ) async {
    if (entry != null || row.uid.isEmpty) return null;
    return ReaderPositionRepository(_appModel.database).findByBookUid(row.uid);
  }

  Future<void> _loadFromSource(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaLibraryService? service,
    OnlineMangaLibraryEntry seed,
    String? sourceLabel,
  ) async {
    // 已经入过库就直接切成书架条目：同一部作品不该因为「从哪进来的」而显示成
    // 两种状态（在库的那份有已读标记，seed 那份没有）。
    //
    // 书架半边可能整个缺席（没有 AppModel 的树里），那时就当「不在库」处理——
    // 展示照旧，只是入库按钮不可用。
    final OnlineMangaLibraryService? shelf = service ?? _shelfServiceFor(seed);
    EpubBookRow? existing;
    bool hadRow = false;
    if (shelf != null) {
      try {
        existing = await shelf.find(seed);
        hadRow = existing != null;
        // 票 02：打开在线源作品页就确保一条 membership=false 的 Manga 行
        // （已有则复用）。阅读进度、已读、History 与下载从此有稳定归属，
        // 但作品不进书架；首屏仍按下面的刷新策略决定是否联网。
        existing ??= await shelf.ensureNonLibrary(seed);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log('MangaSeriesPage.find', error, stack);
      }
    }
    final OnlineMangaLibraryEntry? stored = existing == null
        ? null
        : OnlineMangaLibraryEntry.tryParse(existing.sourceMetadata);
    OnlineMangaLibraryEntry entry = stored ?? seed;
    // 票 06：源搜索/详情页手里就是源**当前**的系列描述（封面 URL 每次带新签名）。
    // 已有记录时直接合并回去——不联网、不碰章节，旧封面即可自愈。
    if (hadRow && existing != null && stored != null && shelf != null) {
      final String? before = trimmedOrNull(stored.series.coverUrl);
      try {
        entry = await shelf.mergeSeries(
          bookKey: existing.bookKey,
          existing: stored,
          series: seed.series,
        );
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaSeriesPage.mergeSeries',
          error,
          stack,
        );
      }
      if (mounted && trimmedOrNull(entry.series.coverUrl) != before) {
        ref.invalidate(myComicBooksProvider);
      }
    }
    final Map<String, MangaChapterStateRow> states = existing == null
        ? const <String, MangaChapterStateRow>{}
        : await _readChapterStates(existing);
    if (!mounted) return;
    setState(() {
      _row = existing;
      _entry = entry;
      _adapter = adapter;
      _service = shelf;
      _sourceLabel = sourceLabel;
      _sourceLabelResolved = sourceLabel != null && sourceLabel.isNotEmpty;
      _sourceMissing = false;
      _missingSourceName = null;
      _shelfCachedCoverUrl = null;
      _generatedCoverUrl = null;
      _states = states;
    });
    unawaited(_ensureGeneratedCover());
    // 来源页未提供名称时（如从 History 打开）自己解析一次：来源可用就显示真实
    // 名称，缺失 / 停用则与书架路径一样按缺失来源降级，而不是露出扩展包名。
    if (sourceLabel == null || sourceLabel.isEmpty) {
      unawaited(_resolveSourceLabel(adapter, entry));
    }
    // 首次打开（行刚建出来）首屏是空的，自动拉一次；已有行则与书架路径同一
    // 规则：有缓存就不联网，缓存章节为空才兜底。
    if (!hadRow || entry.chapters.isEmpty) {
      unawaited(_refreshFromSource(silent: true));
    }
    unawaited(_refreshDownloadState());
  }

  Future<Map<String, MangaChapterStateRow>> _readChapterStates(
    EpubBookRow row,
  ) async {
    if (row.uid.isEmpty) return const <String, MangaChapterStateRow>{};
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return const <String, MangaChapterStateRow>{};
    return appModel.database.getMangaChapterStates(row.uid);
  }

  Future<void> _resolveSourceLabel(
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaLibraryEntry entry,
  ) async {
    final String? label = trimmedOrNull(await adapter.sourceLabel(entry));
    // 运行时解析不到来源：再问 Source 表要名字（停用的 Source 行仍有名称），
    // 都没有时才退化为「来源未安装」。非 Mihon 运行时不套用缺失语义。
    final bool missing =
        label == null && entry.runtime == OnlineMangaRuntimeKind.mihon;
    final String? knownName = missing
        ? trimmedOrNull(await _service?.knownSourceName(entry))
        : null;
    if (!mounted) return;
    setState(() {
      _sourceLabel = label;
      _sourceMissing = missing;
      _missingSourceName = knownName;
      _sourceLabelResolved = true;
    });
    unawaited(_ensureGeneratedCover());
  }

  /// 联网刷新作品详情 + 章节列表。
  ///
  /// [silent] = 进页时的自动刷新：失败只挂提示条，不弹 toast。用户手点刷新时
  /// 反过来——他在等一个明确回应。
  Future<void> _refreshFromSource({bool silent = false}) async {
    _challengeRetry = null;
    final OnlineMangaRuntimeAdapter? adapter = _adapter;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (adapter == null || entry == null || _refreshing) return;
    if (!adapter.isSupportedOnThisPlatform) {
      if (mounted) {
        setState(
          () => _refreshError = const OnlineMangaUnavailable(
            OnlineMangaUnavailableReason.platformUnsupported,
            'This manga runtime is not available on this platform',
          ),
        );
      }
      return;
    }
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    try {
      final String? bookKey = _bookKey;
      final OnlineMangaLibraryService? service = _service;
      OnlineMangaLibraryEntry updated = entry;
      OnlineMangaUnavailable? chaptersError;
      StackTrace? chaptersStack;
      if (bookKey == null || service == null) {
        // 未入库（或够不着书架）：只拉，不落库。
        try {
          final OnlineMangaRefreshResult result = await adapter.refresh(entry);
          updated = entry.copyWith(
            series: result.series,
            chapters: result.chapters.isEmpty && entry.chapters.isNotEmpty
                ? entry.chapters
                : result.chapters,
          );
        } on OnlineMangaUnavailable catch (error, stack) {
          // 详情成功、章节失败：错误里带着刚拿到的封面 URL，页面照样先换新封面。
          final OnlineMangaSeries? details = error.series;
          if (details == null) rethrow;
          updated = entry.copyWith(series: details);
          chaptersError = error;
          chaptersStack = stack;
        }
      } else {
        final OnlineMangaRefreshOutcome outcome = await service
            .refreshFromSource(bookKey: bookKey, entry: entry);
        updated = outcome.entry;
        chaptersError = outcome.chaptersError;
      }
      final EpubBookRow? row = bookKey == null || service == null
          ? null
          : await service.database.getEpubBook(bookKey);
      if (!mounted) return;
      final bool coverChanged =
          trimmedOrNull(entry.series.coverUrl) !=
          trimmedOrNull(updated.series.coverUrl);
      setState(() {
        _entry = updated;
        if (row != null) _row = row;
        // 章节没拉到 = 刷新只完成了一半，空章节的语言解释与「刷新成功」都不成立。
        _refreshSucceeded = chaptersError == null;
        _refreshError = chaptersError;
      });
      // 书架封面来自 myComicBooksProvider 里的 MediaItem：描述符换了新签名 URL
      // 要让它重算，否则返回书架时仍显示过期 URL 的失败封面。
      if (coverChanged) ref.invalidate(myComicBooksProvider);
      if (chaptersError != null) {
        ErrorLogService.instance.log(
          'MangaSeriesPage.refresh[${chaptersError.reason.name}]',
          chaptersError,
          chaptersStack ?? StackTrace.current,
        );
        if (!silent) {
          MyComicToast.show(
            msg: _loadErrorText(chaptersError),
            severity: ToastSeverity.error,
          );
        }
      }
      // 章节列表变了：已下载状态的章集合也要按新章节身份重算（首次打开
      // 源页时 seed 往往只有标题，下载判据要等这次刷新后的章节表）。
      unawaited(_refreshDownloadState());
    } on OnlineMangaUnavailable catch (error, stack) {
      // 这条**才是**在线漫画的主流失败路径：adapter 已经把 Mihon/Aidoku 的运行时
      // 与网络异常全包成了 OnlineMangaUnavailable，兜底的 `on Object` 基本收不到
      // 东西。不在这里记，用户报「漫画刷不出来」时事后捞日志就是空的。
      ErrorLogService.instance.log(
        'MangaSeriesPage.refresh[${error.reason.name}]',
        error,
        stack,
      );
      if (!mounted) return;
      setState(() => _refreshError = error);
      // 手点刷新才补 toast：提示条可能早已挂着，没有 toast 等于点了没反应。
      if (!silent) {
        MyComicToast.show(
          msg: _loadErrorText(error),
          severity: ToastSeverity.error,
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.refresh', error, stack);
      if (!mounted) return;
      final OnlineMangaUnavailable wrapped = OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        describeOnlineSourceError(error),
        cause: error,
      );
      setState(() => _refreshError = wrapped);
      if (!silent) {
        MyComicToast.show(
          msg: wrapped.userMessage,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _addToLibrary() async {
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) {
      await _addScannedLocalToLibrary(scanned);
      return;
    }
    final OnlineMangaLibraryService? service = _service;
    final OnlineMangaLibraryEntry? entry = _entry;
    // 票 02 起源作品页一打开就有非书架行；票 03 把「加入书架」改为翻转这条
    // 行的 membership（行不存在时才创建 Library 行）。已在书架则不再重复加入。
    if (service == null || entry == null || _busy) return;
    if (_row?.isInLibrary ?? false) return;
    // 票 04：已有 Tag 时先选标签；取消（null）则不创建 / 不翻转。
    // 目标键用现有行的真实身份（同源回退时它可能与 seed 推导出的键不同）。
    final Set<int>? selectedTagIds = await _pickTagsBeforeLibraryAdd(
      _row?.bookKey ?? OnlineMangaLibraryService.bookKeyOf(entry),
    );
    if (selectedTagIds == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final EpubBookRow row = await service.add(entry);
      if (!mounted) return;
      // 条目已入架；标签分配在创建成功后统一写入，加入失败时不会留下分配。
      await _applySelectedTags(row.bookKey, selectedTagIds);
      if (!mounted) return;
      setState(() {
        _row = row;
        _entry = OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? entry;
      });
      unawaited(_refreshDownloadState());
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.add', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 加入书架前的标签选择（票 04/05）。返回 null = 用户取消本次加入；空集合 =
  /// 用户确认按未打标签加入（或全局还没有任何 Tag，直接加入）。
  ///
  /// 只选不写：选中的 Tag 由调用方在 Library 条目创建成功后统一写入，取消或
  /// 加入失败都不会留下 Tag 分配。
  Future<Set<int>?> _pickTagsBeforeLibraryAdd(String bookKey) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return const <int>{};
    final List<BookTagRow> tags;
    try {
      tags = await appModel.database.getAllTags();
    } on Object catch (error, stack) {
      // 标签读不出来不该挡住「加入书架」本身：按未打标签直接加入。
      ErrorLogService.instance.log(
        'MangaSeriesPage.addTagLookup',
        error,
        stack,
      );
      return const <int>{};
    }
    if (tags.isEmpty) return const <int>{};
    if (!mounted) return null;
    return showTagPickerSelection(
      context,
      targets: TagTargets(
        media: <MediaRef>[MediaRef(kind: MediaKind.epub, entryKey: bookKey)],
      ),
    );
  }

  /// 写入加入书架时选中的 Tag。条目已入架，失败只提示，不撤销条目。
  Future<void> _applySelectedTags(String bookKey, Set<int> tagIds) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null || tagIds.isEmpty) return;
    try {
      await appModel.database.setTagsForBook(bookKey, tagIds);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.addTags', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    }
  }

  /// 未入库本地作品显式「加入书架」。
  ///
  /// 票 05：已有 Tag 时先选标签；取消（null）则不登记。标签在登记成功后统一
  /// 写入；点章节的静默登记走 [_openChapterAt] → [_registerScannedLocal]，没有
  /// 这一步，保持未打标签。
  Future<void> _addScannedLocalToLibrary(LocalSourceManga manga) async {
    if (_busy) return;
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final Set<int>? selectedTagIds = await _pickTagsBeforeLibraryAdd(bookKey);
    if (selectedTagIds == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final String? registeredKey = await _registerScannedLocal(manga);
      if (registeredKey == null) return;
      await _applySelectedTags(registeredKey, selectedTagIds);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 单部作品的原地登记（显式「加入书架」与点章自动加入共用）：扫描结果原样
  /// 交给 `registerScannedManga`（与 Rebuild download index 同一条写入路径），
  /// 原地登记、不复制文件；插入行本身会清 tombstone（`insertEpubBook`）。
  ///
  /// 成功后切到正常书架条目并返回 bookKey；失败已 toast 并返回 null（页面保持
  /// 未入库态，章节列表照常可用）。
  Future<String?> _registerScannedLocal(LocalSourceManga manga) async {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return null;
    try {
      await LocalSourceLibrary(
        db: appModel.database,
        root: appModel.appPaths.localComicRoot,
      ).registerScannedManga(manga);
      final String bookKey = localSourceBookKeyFor(manga.directoryPath);
      final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
      if (!mounted || row == null) return null;
      setState(() {
        _row = row;
        _entry = null;
        _scannedLocal = null;
        _localSource = LocalSourceMetadata.tryParse(row.sourceMetadata);
        _localChapters = decodeLocalSourceChapters(row.chaptersJson);
        _states = const <String, MangaChapterStateRow>{};
        _localMissingChapterKeys = const <String>{};
      });
      _watchLocalVolume(row.bookKey);
      unawaited(_refreshDownloadState());
      return bookKey;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.addScannedLocal',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
      return null;
    }
  }

  /// 移出书架 = 只清 Library membership（票 04）：Manga/Chapter、阅读进度、
  /// 已读标记、下载任务、章目录映射、下载文件夹与 History 全部保留；Tag 分配与
  /// 订阅 / 自动追更移除。Download library 里的已下载文件默认保留，勾选「同时
  /// 删除本地文件」才删文件与下载索引（行与阅读状态仍保留，之后可重新下载）。
  ///
  /// 移出后页面**不关**、切回非书架态：条目本身（作品 + 章节列表 + 已下载状态）
  /// 还在手上，用户可以立刻重新加入；关页面反而把他丢回不知道哪一层的列表。
  Future<void> _removeFromLibrary() async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (row == null || appModel == null || _busy) return;
    if (_isLocalSource) {
      await _removeLocalSourceFromLibrary(row, appModel);
      return;
    }
    if (entry == null) return;
    final MangaLibraryRemovalDecision? decision =
        await _confirmRemoveFromLibrary();
    if (decision == null || !mounted) return;
    setState(() => _busy = true);
    try {
      // 下载任务的停止由 removeMangaFromLibrary 统一负责（单一 owner）：它先
      // remove 排队中 / 下载中的任务（等正在飞的那个真停），再删文件与行。页面
      // 不再维护第二份停止循环。
      final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
        db: appModel.database,
        bookKey: row.bookKey,
        downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
        deleteLocalFiles: decision.deleteLocalFiles,
        downloadService: appModel.mangaDownloadService,
      );
      if (!mounted) return;
      if (!result.removed) {
        final String reason = result.failureMessage;
        MyComicToast.show(
          msg: reason.isEmpty
              ? t.epub_delete_error
              : '${t.epub_delete_error}: $reason',
          severity: ToastSeverity.error,
        );
        return;
      }
      final EpubBookRow? remaining = result.row;
      if (remaining != null) {
        // 非破坏移出：行还在，阅读状态 / 已读 / 下载状态原样保留，只切回非书架态。
        setState(() {
          _row = remaining;
          _entry =
              OnlineMangaLibraryEntry.tryParse(remaining.sourceMetadata) ??
              entry.copyWith(subscribed: false, autoDownload: false);
        });
        await _refreshDownloadState();
      } else {
        // 兜底：行已不存在时退回未入库态。
        setState(() {
          _row = null;
          _states = const <String, MangaChapterStateRow>{};
          _downloaded = const <String>{};
          _deletableDownloaded = const <String>{};
          _jobs = const <String, MangaDownloadJobRow>{};
          _entry = entry.copyWith(
            clearCurrentChapter: true,
            subscribed: false,
            autoDownload: false,
          );
        });
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.remove', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Local source 的「移出书架」：与在线作品页同一个统一弹窗。默认只清 Library
  /// membership（票 04）：行、阅读状态与 `local` 原作都保留。勾选「同时删除本地
  /// 文件」时先删 Local source root 里的原作文件夹/文件，成功后才连行与状态一起
  /// 删除并立墓碑（ADR 0013）；文件删除失败时作品留在架上并提示。
  Future<void> _removeLocalSourceFromLibrary(
    EpubBookRow row,
    AppModel appModel,
  ) async {
    final MangaLibraryRemovalDecision? decision =
        await _confirmRemoveFromLibrary();
    if (decision == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final MangaLibraryRemovalResult result = await removeMangaFromLibrary(
        db: appModel.database,
        bookKey: row.bookKey,
        localSourceRoot: appModel.appPaths.localComicRoot,
        deleteLocalFiles: decision.deleteLocalFiles,
        downloadService: appModel.mangaDownloadService,
      );
      if (!mounted) return;
      if (!result.removed) {
        final String reason = result.failureMessage;
        MyComicToast.show(
          msg: reason.isEmpty
              ? t.epub_delete_error
              : '${t.epub_delete_error}: $reason',
          severity: ToastSeverity.error,
        );
        return;
      }
      // 非破坏移出时行仍在（章节表也还在）；删文件移出时行已删——两种情况都回
      // Local source 页，由该页重新判定「已入架 / 未入架」。
      final EpubBookRow? remaining = result.row;
      if (remaining != null) {
        setState(() => _row = remaining);
      }
      final NavigatorState navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.removeLocalSource',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: t.epub_delete_error,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 只有当前 `local` 根内的条目才提供「删除本地文件」。
  ///
  /// 源未安装时 Rebuild 会把 `downloads/{source}/{manga}` 降级成指向该目录的
  /// Local source 条目（票 10）；这些文件不归 Local source 管，
  /// [LocalSourceLibrary.deleteLocalFiles] 会拒绝越界路径。与其显示一个必然
  /// 失败的动作，不如隐藏它。读不到 AppPaths 的测试壳按不可删处理。
  bool _canDeleteLocalSourceFiles(EpubBookRow row) {
    final AppModel? appModel = _appModelOrNull;
    if (appModel == null) return false;
    return isLocalSourcePathWithinRoot(
      row.extractDir,
      appModel.appPaths.localComicRoot,
    );
  }

  /// 「删除本地文件」：与「移出书架」分开的破坏性动作，二次确认后删除
  /// `local` 里的作品目录。路径越界 / 非 Local source 条目由 service 拒绝。
  Future<void> _deleteLocalSourceFiles(
    EpubBookRow row,
    AppModel appModel,
  ) async {
    final bool confirmed = await showMyComicConfirmDialog(
      context: context,
      title: t.manga_series_delete_local_files,
      message: t.manga_series_delete_local_files_confirm,
      cancelLabel: t.dialog_cancel,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      final LocalSourceDeleteResult result = await LocalSourceLibrary(
        db: appModel.database,
        root: appModel.appPaths.localComicRoot,
      ).deleteLocalFiles(row.bookKey, confirmed: true);
      if (!mounted) return;
      if (!result.deleted) {
        MyComicToast.show(
          msg: t.epub_delete_error,
          severity: ToastSeverity.error,
        );
        return;
      }
      // 票 10：Local source 的「删除本地文件」= 删除整部作品（含文件）。作品行
      // 已删、磁盘文件也没了，历史页再没有可回退的目标，级联清掉它的历史行。
      // 与 deleteBook 同一纪律：历史清理失败只记日志，不翻转文件已删的结果。
      try {
        await deleteMangaHistoryForBook(appModel.database, row);
      } catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaSeriesPage.deleteLocalSourceHistory',
          error,
          stack,
        );
      }
      if (!mounted) return;
      final NavigatorState navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.pop();
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.deleteLocalSourceFiles',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: t.epub_delete_error,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 在线与本地 Manga 共用的统一移出弹窗（票 01）。
  Future<MangaLibraryRemovalDecision?> _confirmRemoveFromLibrary() =>
      showMangaShelfRemovalDialog(
        context,
        message: t.manga_series_remove_confirm,
        localFilesSubtitle: t.delete_local_files_download_desc,
      );

  /// 「继续阅读」落到哪一章。
  int get _resumeIndex {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return -1;
    return OnlineMangaLibraryService.resumeChapterIndex(
      entry,
      _states,
      target: MangaResumeTargetKey.fromKey(
        _appModelOrNull?.mangaResumeTarget ?? kMangaResumeTargetDefault,
      ),
    );
  }

  /// 点章节：开读——已下载从磁盘读，未下载在线直读（2026-09-26 用户撤回设计稿
  /// 2026-09-12 §1.1「先下载再读」；下载入口不变，走章节行溢出菜单 / 下载全部）。
  /// 未入库的先入库——进度、已读标记、下载任务都按 bookKey 记，没有行就无处可落。
  Future<void> _openChapterAt(int index) async {
    // 未入库的本地扫描结果：点章节 = 用户显式选择该作品。先静默登记（进度 /
    // 历史 / 已读标记都按 bookKey 记，没有行就无处可落），再按正常书架条目开读。
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) {
      if (_busy || index < 0 || index >= _localChapters.length) return;
      setState(() => _busy = true);
      try {
        final String? bookKey = await _registerScannedLocal(scanned);
        if (bookKey == null || !mounted) return;
        await _openReader(bookKey, chapterIndex: index);
        await _reloadAfterReading();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    // Local source：章节原地读取，不经过在线 service / 下载状态机。
    if (_isLocalSource) {
      final String? localBookKey = _bookKey;
      if (_busy ||
          localBookKey == null ||
          index < 0 ||
          index >= _localChapters.length) {
        return;
      }
      setState(() => _busy = true);
      try {
        await _openReader(localBookKey, chapterIndex: index);
        await _reloadAfterReading();
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final OnlineMangaLibraryService? service = _service;
    OnlineMangaLibraryEntry? entry = _entry;
    if (service == null || entry == null || _busy) return;
    if (index < 0 || index >= entry.chapters.length) return;
    setState(() => _busy = true);
    try {
      String? bookKey = _bookKey;
      if (bookKey == null) {
        // 从源里直接点章：确保一条**非书架**行再读（票 02：阅读不等于收藏）。
        // 进度、已读标记、断点续读按 bookKey/uid 落在这条行上。
        final EpubBookRow row = await service.ensureNonLibrary(entry);
        entry = OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? entry;
        bookKey = row.bookKey;
        if (!mounted) return;
        setState(() {
          _row = row;
          _entry = entry;
        });
      }
      final OnlineMangaChapter chapter = entry.chapters[index];
      // 未下载的章也直接开读：阅读器按同一判据分流，已下载从磁盘读、未下载在线
      // 直读（2026-09-26 用户撤回设计稿 §1.1）。锁章（源标了要登录 / 购买）照旧
      // 先问：弹窗的出口是「仍然下载」/「登录」，选下载就入队、不开读。
      final AppModel? appModel = _appModelOrNull;
      final bool downloaded =
          appModel != null &&
          await DownloadLibraryIndex(
            appModel.database,
          ).isChapterDownloaded(bookKey: bookKey, chapterKey: chapter.key);
      if (chapter.locked && !downloaded) {
        if (await _promptLockedChapter(chapter)) {
          await _enqueueChapter(chapter);
        }
        return;
      }
      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: bookKey,
        entry: entry,
        chapterIndex: index,
      );
      if (!mounted) return;
      setState(() => _entry = selected);
      await _openReader(bookKey, chapterIndex: index);
      // 从阅读器回来必须重读：读了哪些页、哪章读完了全在阅读器里写的库。
      await _reloadAfterReading();
    } on OnlineMangaUnavailable catch (error, stack) {
      // 同 refresh：开章失败绝大多数落在这一支，不记就等于「漫画打不开」这类
      // 报障永远没有可捞的记录。
      ErrorLogService.instance.log(
        'MangaSeriesPage.openChapter[${error.reason.name}]',
        error,
        stack,
      );
      if (mounted) {
        _challengeRetry = () => _openChapterAt(index);
        setState(() => _refreshError = error);
        MyComicToast.show(msg: error.userMessage, severity: ToastSeverity.error);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaSeriesPage.openChapter', error, stack);
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLocalBook() async {
    final String? bookKey = _bookKey;
    if (bookKey == null) return;
    await _openReader(bookKey);
    await _reloadAfterReading();
  }

  /// 开阅读器。
  ///
  /// **必须走 `openMedia`**，不能自己 `Navigator.push` 一个 `MangaMyComicPage`：
  /// 沉浸模式、wakelock、audio handler 预热、`_currentMediaSource`、历史记账
  /// 全在 `openMedia` 里。v88 前书架是直接 `openMedia` 开阅读器的，作品页插在
  /// 中间后，这些副作用必须原样跟着阅读器走，否则漫画会静默丢掉一整套会话行为。
  ///
  /// `MangaMyComicSource.buildLaunchPage` 仍然返回阅读器（不是作品页），所以这里
  /// 不会自我递归。
  /// [chapterIndex]：在线漫画点名要开的章，显式交给阅读器（不点名时阅读器按「重新
  /// 打开位置」偏好自己选章，那是首页「继续」等直接开书的语义）。
  Future<void> _openReader(String bookKey, {int? chapterIndex}) async {
    MediaItem? item = switch (widget.target) {
      ShelfMangaSeriesTarget(:final MediaItem? item) => item,
      SourceMangaSeriesTarget() => null,
      LocalSourceMangaSeriesTarget() => null,
    };
    item ??= await ReaderMyComicSource.instance.mediaItemForBookKey(bookKey);
    if (!mounted) return;
    if (item == null) {
      // 条目刚入库、MediaItem 还建不出来（不该发生）：退回直接开阅读器，
      // 宁可少一层会话副作用，也不能让「点了没反应」。
      await Navigator.of(context).push(
        adaptivePageRoute<void>(
          context: context,
          builder: (BuildContext context) => MyComicAppUiScaleNeutralizer(
            child: MangaMyComicPage(
              item: null,
              bookKey: bookKey,
              initialChapterIndex: chapterIndex,
            ),
          ),
        ),
      );
      return;
    }
    final MediaItem launchItem = item;
    await _appModel.openMedia(
      ref: ref,
      mediaSource: MangaMyComicSource.instance,
      item: launchItem,
      launchPageBuilder: () => MangaMyComicSource.instance.buildChapterLaunchPage(
        item: launchItem,
        chapterIndex: chapterIndex,
      ),
    );
  }

  Future<void> _reloadAfterReading() async {
    final String? bookKey = _bookKey;
    if (bookKey == null || !mounted) return;
    final EpubBookRow? row = await _appModel.database.getEpubBook(bookKey);
    if (row == null || !mounted) return;
    final OnlineMangaLibraryEntry? entry =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata) ?? _entry;
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    final ReaderPosition? position = await _readLocalPosition(row, entry);
    if (!mounted) return;
    setState(() {
      _row = row;
      _entry = entry;
      _localSource = LocalSourceMetadata.tryParse(row.sourceMetadata);
      _localChapters = decodeLocalSourceChapters(row.chaptersJson);
      _states = states;
      _localPosition = position;
    });
    unawaited(_refreshDownloadState());
  }

  /// 当前展示的章节条目：在线描述符优先，本地图源借展示条目。
  OnlineMangaLibraryEntry? get _displayEntry => _entry ?? _localDisplayEntry;

  /// 与共享章节列表内部完全相同的下载状态口径（ticket 06）：多选的可见域必须
  /// 跟着下载筛选走。
  MangaChapterDownloadState _downloadStateOf(OnlineMangaChapter chapter) =>
      MangaChapterList.downloadStateOf(
        chapter: chapter,
        downloadedChapterKeys: _isLocalSource
            ? _localChapters
                  .map((LocalSourceChapterRecord chapter) => chapter.key)
                  .toSet()
            : _downloaded,
        missingChapterKeys: _isLocalSource
            ? _localMissingChapterKeys
            : const <String>{},
        jobsByChapterKey: _jobs,
      );

  /// 当前筛选（只看未读 + 下载状态）+ 排序后真正渲染出来的章节
  /// （顺序 = 屏幕顺序）。
  List<OnlineMangaChapter> get _visibleChapters =>
      MangaChapterList.visibleChapters(
        chapters: _displayEntry?.chapters ?? const <OnlineMangaChapter>[],
        states: _states,
        newestFirst: _newestFirst,
        unreadOnly: _unreadOnly,
        downloadFilter: _downloadFilter,
        downloadStateOf: _downloadStateOf,
      );

  /// 每帧把可见章节序登记给选择状态机：全选 / 反选与批量动作只认这份可见序。
  ///
  /// 可见序是 build 期算出来的，批量栏在同一帧更早的位置已读过选中集，会慢一
  /// 拍；可见序变了且正在多选时补一帧（与书架 / 本地图源页同一约定）。
  void _syncVisibleSelectionOrder() {
    final bool changed = _selection.setVisibleOrder(
      loose: <String>[
        for (final OnlineMangaChapter chapter in _visibleChapters) chapter.key,
      ],
      collections: const <int>[],
    );
    if (!changed || !_selectionMode) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted) setState(() {});
    });
  }

  void _exitSelectionMode() {
    if (!_selectionMode) return;
    setState(_selection.exit);
  }

  /// 多选态内单击章节：切换选中；取消最后一项 = 清空选择，退出多选。
  /// 非多选态保持原语义：打开该章。
  void _handleChapterTap(OnlineMangaChapter chapter) {
    if (_selectionMode) {
      setState(() {
        _selection.toggle(SelectionSlot.loose(chapter.key));
        if (_selection.isEmpty) _selection.exit();
      });
      return;
    }
    final int index = _displayEntry?.indexOfChapterKey(chapter.key) ?? -1;
    if (index >= 0) unawaited(_openChapterAt(index));
  }

  /// 长按章节进入多选并选中它。多选态内的长按交给 [SelectionDragArea] 扫选，
  /// 所以章节行在多选态不挂这个回调。
  void _handleChapterLongPress(OnlineMangaChapter chapter) {
    if (_batchRunning) return;
    setState(() => _selection.enterWith(SelectionSlot.loose(chapter.key)));
  }

  void _selectAllChapters() {
    setState(
      () => _selection.selectAll(
        loose: _selection.visibleLooseKeys,
        collections: const <int>[],
      ),
    );
  }

  void _invertChapterSelection() {
    setState(() {
      _selection.invert(
        loose: _selection.visibleLooseKeys,
        collections: const <int>[],
      );
      if (_selection.isEmpty) _selection.exit();
    });
  }

  /// 当前可见且选中的章节（批量动作的作用域；被筛选隐藏的选中项不参与）。
  List<OnlineMangaChapter> get _selectedVisibleChapters {
    final Set<String> keys = _selection.looseKeys;
    if (keys.isEmpty) return const <OnlineMangaChapter>[];
    return <OnlineMangaChapter>[
      for (final OnlineMangaChapter chapter in _visibleChapters)
        if (keys.contains(chapter.key)) chapter,
    ];
  }

  /// 批量下载只适用于在线、来源可解析的条目：本地图源 / 本地卷（[_entry] 为
  /// null）没有在线下载；来源未安装（运行时解析失败）或解析尚未结束时不能发起。
  bool get _batchDownloadSourceAvailable =>
      _entry != null && _sourceLabelResolved && !_sourceMissing;

  /// 批量下载的规划：当前可见且选中的在线章节交给与「下载全部」共享的
  /// [planMangaChapterDownload]，由它跳过已下载、已排队 / 下载中 / 暂停与锁定
  /// 章。混合选择因此只处理可下载子集；遍历顺序不变，入队顺序仍是旧→新。
  ({List<OnlineMangaChapter> pending, int lockedSkipped})
  get _batchDownloadPlan {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null || !_batchDownloadSourceAvailable) {
      return (pending: const <OnlineMangaChapter>[], lockedSkipped: 0);
    }
    final Set<String> selectedKeys = <String>{
      for (final OnlineMangaChapter chapter in _selectedVisibleChapters)
        chapter.key,
    };
    if (selectedKeys.isEmpty) {
      return (pending: const <OnlineMangaChapter>[], lockedSkipped: 0);
    }
    return planMangaChapterDownload(
      entry: entry,
      downloadedChapterKeys: _downloaded,
      jobsByChapterKey: _jobs,
      chapterKeys: selectedKeys,
    );
  }

  /// 批量下载选中的适用章节：不弹确认，直接复用「下载全部」的 planner 与
  /// [MangaDownloadService.enqueueChapters] 路径（CBZ 设置与下载顺序由下载
  /// 服务沿用）。入队后立刻重算任务表，章节行与下载页随即显示排队状态。
  Future<void> _batchDownloadSelected() async {
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null || _batchRunning) return;
    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        _batchDownloadPlan;
    final List<OnlineMangaChapter> pending = plan.pending;
    if (pending.isEmpty) return;
    if (plan.lockedSkipped > 0) {
      MyComicToast.show(
        msg: t.manga_series_download_all_locked_skipped(
          count: plan.lockedSkipped,
        ),
      );
    }
    setState(() => _batchRunning = true);
    try {
      await appModel.mangaDownloadService.enqueueChapters(
        entry: entry,
        chapters: pending,
        autoOcr: false,
      );
      await _syncDownloadRow();
      if (mounted) {
        MyComicToast.show(
          msg: t.manga_series_download_all_queued(count: pending.length),
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.batchDownloadSelected',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      await _refreshDownloadState();
      if (mounted) {
        _syncVisibleSelectionOrder();
        setState(() => _batchRunning = false);
      }
    }
  }

  /// 批量标记已读 / 未读：只写章级 `readAt`，与单章菜单同一套数据库动作，不
  /// 改书级 `completedAt`，也不弹确认。混合选择只处理适用子集。
  Future<void> _batchMarkRead({required bool read}) async {
    final String? bookUid = _bookUid;
    if (bookUid == null || _batchRunning) return;
    final List<OnlineMangaChapter> targets = _selectedVisibleChapters
        .where(
          (OnlineMangaChapter chapter) => read
              ? _states[chapter.key]?.readAt == null
              : _states[chapter.key]?.readAt != null,
        )
        .toList(growable: false);
    if (targets.isEmpty) return;
    setState(() => _batchRunning = true);
    try {
      if (read) {
        await _appModel.database.markMangaChaptersRead(
          bookUid: bookUid,
          chapterKeys: <String>[
            for (final OnlineMangaChapter chapter in targets) chapter.key,
          ],
        );
      } else {
        // 逐章清除与单章「标为未读」是同一个动作（保留 lastPage / 页数）。
        for (final OnlineMangaChapter chapter in targets) {
          await _appModel.database.clearMangaChapterRead(
            bookUid: bookUid,
            chapterKey: chapter.key,
          );
        }
      }
      await _reloadChapterStates();
      _syncVisibleSelectionOrder();
    } finally {
      if (mounted) {
        setState(() {
          _batchRunning = false;
          // 「只看未读」下标记已读会让选中项从可见集消失；清空后退出多选，
          // 不让用户停在一个没有批量栏、点一下却只是勾选的状态里。
          if (_selectionMode && _selection.isEmpty) _selection.exit();
        });
      }
    }
  }

  /// 批量删除的适用子集：当前可见且选中的「已完成」在线下载。
  ///
  /// 只要求是在线条目，不要求 Manga 行 / Library membership / 数据库映射：
  /// 「已下载」由 [_refreshDownloadState] 合并映射与磁盘 `pages.json` 身份扫描
  /// 得出（票 05：清库后仍可直接批量删除）。本地图源章节的磁盘文件属于用户
  /// 文件，永远不参与；Local source root 下的用户原件虽显示已下载，但不在
  /// [_deletableDownloaded] 里，同样置灰；排队中 / 下载中 / 暂停 / 文件缺失
  /// 也都不算「已完成」。
  List<OnlineMangaChapter> get _deletableSelectedChapters {
    if (_entry == null) return const <OnlineMangaChapter>[];
    return <OnlineMangaChapter>[
      for (final OnlineMangaChapter chapter in _selectedVisibleChapters)
        if (_downloadStateOf(chapter) == MangaChapterDownloadState.downloaded &&
            _deletableDownloaded.contains(chapter.key))
          chapter,
    ];
  }

  /// 批量删除选中的已完成在线下载：只动 Download library 里由应用管理的
  /// 文件，不碰本地图源用户文件。删除前二次确认；删完章节回到「未下载」，
  /// 章级已读标记与阅读进度原样保留。
  ///
  /// 与单章删除复用同一条身份回退（[DownloadLibraryIndex.deleteChapterForEntry]）：
  /// 有映射按映射删，没有映射 / 没有 Manga 行时按 entry 的下载身份在
  /// `downloads` 里找唯一匹配的容器；`local` 根永远不参与删除。
  Future<void> _batchDeleteDownloads() async {
    final EpubBookRow? row = _row;
    final OnlineMangaLibraryEntry? entry = _entry;
    final AppModel? appModel = _appModelOrNull;
    if (entry == null || appModel == null || _batchRunning) return;
    final List<OnlineMangaChapter> targets = _deletableSelectedChapters;
    if (targets.isEmpty) return;
    final bool confirmed = await showMyComicConfirmDialog(
      context: context,
      title: t.manga_series_delete_downloads,
      message: t.manga_series_delete_downloads_confirm(count: targets.length),
      icon: MyComicIcons.delete,
      confirmLabel: t.dialog_delete,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _batchRunning = true);
    final Set<String> deletedChapterKeys = <String>{};
    try {
      final DownloadLibraryIndex index = DownloadLibraryIndex(
        appModel.database,
        downloadsRoot: appModel.appPathsOrNull?.downloadsRoot,
        localComicRoot: appModel.appPathsOrNull?.localComicRoot,
      );
      for (final OnlineMangaChapter chapter in targets) {
        await index.deleteChapterForEntry(
          entry: entry,
          chapterKey: chapter.key,
          row: row,
        );
        deletedChapterKeys.add(chapter.key);
        // done 任务行是「这章曾经下载过」的持久标记。用户主动删除下载时必须
        // 一起清掉，否则磁盘判据变 false、任务仍 done → 被误显示成 Missing。
        final MangaDownloadJobRow? job = _jobs[chapter.key];
        if (job != null) {
          await appModel.mangaDownloadService.remove(job.jobId);
        }
      }
      if (mounted) MyComicToast.show(msg: t.storage_entry_delete_done);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaSeriesPage.batchDeleteDownloads',
        error,
        stack,
      );
      if (mounted) {
        MyComicToast.show(
          msg: describeOnlineSourceError(error),
          severity: ToastSeverity.error,
        );
      }
    } finally {
      _forgetDownloadedChapters(deletedChapterKeys);
      await _refreshDownloadState();
      if (mounted) {
        _syncVisibleSelectionOrder();
        setState(() {
          _batchRunning = false;
          // 下载筛选为「已下载」时，删掉的章会从可见集消失；清空后退出多选，
          // 不让用户停在一个没有批量栏、点一下却只是勾选的状态里。
          if (_selectionMode && _selection.isEmpty) _selection.exit();
        });
      }
    }
  }

  /// 底部批量栏：已选 N / 全选 / 反选 + 标记已读（圆形空心对勾）/ 标记未读
  /// （圆形实心对勾）/ 下载选中（下载图标）/ 删除已下载（垃圾桶）。全部已选
  /// 已读时已读置灰，全部未读时未读置灰；没有可下载的选中在线章节时下载置灰
  /// （本地源、来源未安装同样如此）；没有可删的已完成在线下载时垃圾桶置灰。
  Widget _buildBatchActionBar(BuildContext context) {
    final List<OnlineMangaChapter> selected = _selectedVisibleChapters;
    final bool canMarkRead =
        _bookUid != null &&
        selected.any(
          (OnlineMangaChapter chapter) => _states[chapter.key]?.readAt == null,
        );
    final bool canMarkUnread =
        _bookUid != null &&
        selected.any(
          (OnlineMangaChapter chapter) => _states[chapter.key]?.readAt != null,
        );
    // 与点击时的规划同源：已下载 / 已排队 / 下载中 / 暂停 / 锁定章都不会入队，
    // 所以没有 pending 时动作置灰；混合选择仍只处理适用子集。
    final bool canDownloadSelected = _batchDownloadPlan.pending.isNotEmpty;
    final bool canDeleteDownloads = _deletableSelectedChapters.isNotEmpty;
    return BatchActionBar(
      selectedCount: _selection.length,
      onSelectAll: _selectAllChapters,
      onInvertSelection: _invertChapterSelection,
      actions: <Widget>[
        MyComicIconButton(
          key: const ValueKey<String>('manga_series_batch_mark_read'),
          enabled: canMarkRead && !_batchRunning,
          onTap: () => unawaited(_batchMarkRead(read: true)),
          icon: MyComicIcons.success,
          tooltip: t.manga_series_mark_read,
        ),
        MyComicIconButton(
          key: const ValueKey<String>('manga_series_batch_mark_unread'),
          enabled: canMarkUnread && !_batchRunning,
          onTap: () => unawaited(_batchMarkRead(read: false)),
          icon: MyComicIcons.filled(MyComicIcons.success),
          tooltip: t.manga_series_mark_unread,
        ),
        MyComicIconButton(
          key: const ValueKey<String>('manga_series_batch_download_selected'),
          enabled: canDownloadSelected && !_batchRunning,
          onTap: () => unawaited(_batchDownloadSelected()),
          icon: MyComicIcons.download,
          tooltip: t.manga_online_download_selected,
        ),
        MyComicIconButton(
          key: const ValueKey<String>('manga_series_batch_delete_downloads'),
          enabled: canDeleteDownloads && !_batchRunning,
          onTap: () => unawaited(_batchDeleteDownloads()),
          icon: MyComicIcons.delete,
          tooltip: t.manga_series_delete_downloads,
        ),
      ],
    );
  }

  Future<void> _toggleChapterRead(OnlineMangaChapter chapter) async {
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    final MangaChapterStateRow? state = _states[chapter.key];
    if (state?.readAt != null) {
      await _appModel.database.clearMangaChapterRead(
        bookUid: bookUid,
        chapterKey: chapter.key,
      );
    } else {
      await _appModel.database.markMangaChaptersRead(
        bookUid: bookUid,
        chapterKeys: <String>[chapter.key],
      );
    }
    await _reloadChapterStates();
  }

  /// 标记「这一章及更早的全部」为已读。
  ///
  /// 「更早」按**阅读顺序**算，与列表当前排序无关：
  /// * 在线源按新→旧返回，所以列表里**它之后**（下标更大）的章更旧；
  /// * 本地源按自然顺序（第 1 话→第 N 话）返回，所以**它之前**（下标更小）的
  ///   章更早。
  ///
  /// 本地源没有在线描述符，借用作品页的展示条目取章节 key。
  Future<void> _markUpToRead(OnlineMangaChapter chapter) async {
    final String? bookUid = _bookUid;
    final OnlineMangaLibraryEntry? entry = _entry ?? _localDisplayEntry;
    if (bookUid == null || entry == null) return;
    final int index = entry.indexOfChapterKey(chapter.key);
    if (index < 0) return;
    final bool localOrder = entry.runtime == OnlineMangaRuntimeKind.local;
    await _appModel.database.markMangaChaptersRead(
      bookUid: bookUid,
      chapterKeys: <String>[
        if (localOrder)
          for (int i = 0; i <= index; i++) entry.chapters[i].key
        else
          for (int i = index; i < entry.chapters.length; i++)
            entry.chapters[i].key,
      ],
    );
    await _reloadChapterStates();
  }

  Future<void> _reloadChapterStates() async {
    final EpubBookRow? row = _row;
    if (row == null || !mounted) return;
    final Map<String, MangaChapterStateRow> states = await _readChapterStates(
      row,
    );
    if (mounted) setState(() => _states = states);
  }

  // ── 渲染 ────────────────────────────────────────────────────────────

  /// M3E 作品详情骨架（2026-10，与视频系列 / 在线作品页同一套
  /// `media_detail_kit.dart`）：AppBar 只留标题；原 AppBar 上的动作挪进 hero 的
  /// 主操作按钮组——登录 / 订阅是常驻的图标次按钮（BUG-2497：登录入口要直接
  /// 可见），在网站打开 / 刷新 / 自动下载 / OCR 进「⋯」。各动作的 ValueKey 原样
  /// 带到新组件上。
  @override
  Widget build(BuildContext context) {
    final String title = _displayTitle;
    // 正文铺到悬浮页头底下（脚手架默认 extendBodyBehindHeader）：封面模糊背景
    // 一直画到窗口顶端，页头只是胶囊。
    return SectionPopScope(
      // 多选态吃返回键 / ESC：先退出多选，再允许离开作品页。
      intercepting: _selectionMode,
      onIntercept: _exitSelectionMode,
      child: SelectionDragArea(
        // 多选态才接管长按扫选；非多选态章行长按归自己（进入多选）。
        enabled: _selectionMode,
        onDragBegin: (SelectionSlot slot) =>
            setState(() => _selection.beginRangeDrag(slot)),
        onDragUpdate: (SelectionSlot slot) =>
            setState(() => _selection.updateRangeDrag(slot)),
        onDragEnd: () => setState(_selection.endRangeDrag),
        child: MyComicPageScaffold(
          // hero 里已有大标题：顶栏标题等它滚出视口再淡入（不同屏重复）。
          revealTitleAfterScroll: kMediaDetailTitleRevealOffset,
          title: title,
          body: _buildBody(context),
          // 批量栏作为底部栏参与布局（不遮住最后一章）。没有可见选中项时隐藏；
          // 退出多选的收起动画继续画上一帧（计数不会先闪成 0）。
          bottomNavigationBar: BatchActionBarHost(
            visible: _selectionMode && _selection.isNotEmpty,
            builder: _buildBatchActionBar,
          ),
        ),
      ),
    );
  }

  /// hero 标题上方的来源名（本地卷 / 源名 / 扩展包名）。
  ///
  /// 缺失来源不显示内部占位值 `mihon.unavailable`，也不回退到原始扩展包名：
  /// 有 Source 表名称或备份名称时显示「来源未安装：<名称>」，否则只显示
  /// 「来源未安装」。来源安装后若运行时能经数字 sourceId 回退解析出真实名称
  /// （票 03），真实名称优先。
  String? _subtitle() {
    if (_isScannedLocal) return t.local_source_title;
    if (_isLocal) return t.manga_series_local_volume;
    final String? label = trimmedOrNull(_sourceLabel);
    if (label != null) return label;
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry == null) return null;
    if (entry.runtime == OnlineMangaRuntimeKind.mihon) {
      // 占位身份即时降级；已安装但停用的 Source 在解析确认失败后同样按缺失
      // 展示。解析结束前的短暂空档不露出原始扩展包名。
      if (entry.hasUnavailableSourcePlaceholder || _sourceMissing) {
        return _missingSourceLabel(entry);
      }
      return null;
    }
    return entry.extensionPackage;
  }

  /// 缺失来源的文案：优先 Source 表名称（停用也保留），其次备份名称；都没有时
  /// 只给「来源未安装」。
  String _missingSourceLabel(OnlineMangaLibraryEntry entry) {
    final String? name =
        trimmedOrNull(_missingSourceName) ?? trimmedOrNull(entry.sourceName);
    return name == null
        ? t.manga_series_source_missing
        : t.manga_series_source_missing_named(name: name);
  }

  /// 来源解析已经确认失败（未安装、停用或 sourceId 歧义）：作品页要主动解释
  /// 离线边界。
  ///
  /// 解析结束前不显示（安装扩展后经 sourceId 回退能拿到真实来源，避免闪一下）；
  /// 来源标签本身即时降级，不露出内部占位值或原始扩展包名。
  bool get _showsMissingSourceNotice {
    final OnlineMangaLibraryEntry? entry = _entry;
    return entry != null &&
        entry.runtime == OnlineMangaRuntimeKind.mihon &&
        _sourceLabelResolved &&
        _sourceMissing &&
        trimmedOrNull(_sourceLabel) == null;
  }

  /// 页面上是不是一点内容都没有。
  ///
  /// 未入库 + 一章都没拉到 = 这次是**加载**失败，不是刷新失败。两者要给完全不同
  /// 的界面：有内容时失败只挂一条不遮挡的横幅；什么都没有时必须把真实原因、
  /// 诊断入口和重试摆出来，否则用户只看到一页空白（BUG-1767 的原始症状就是
  /// 「只渲染一行光秃的异常文本，既没重试也拿不到堆栈」）。
  bool get _hasNothingToShow =>
      _row == null && (_entry?.chapters.isEmpty ?? true);

  Widget _buildBody(BuildContext context) {
    if (_loading) return const MediaDetailSkeleton();
    final Object? fatal = _fatalError;
    // 页头浮在正文上（extendBodyBehindHeader）：错误态自己让开页头。
    if (fatal != null) {
      return SafeArea(bottom: false, child: _buildFatalError(context, fatal));
    }
    final OnlineMangaUnavailable? loadError = _refreshError;
    if (loadError != null && _hasNothingToShow) {
      return SafeArea(
        bottom: false,
        child: _buildLoadError(context, loadError),
      );
    }
    final double page = MyComicDesignTokens.of(context).spacing.page;
    // 宽屏两栏：左 hero（封面 / 标题 / 操作 / 简介）独立滚动，右章节列表；窄屏
    // 单列。BUG-2440 的底部安全区由 MediaDetailLayout 的尾部 SliverSafeArea 补。
    final Widget content = MyComicEntranceScope(
      child: MangaChapterFastScrollbar(
        controller: _scroll,
        notificationPredicate: _isBodyScroll,
        child: MediaDetailLayout(
          controller: _scroll,
          backdrop: _coverImageProvider(),
          header: _buildHeader(context),
          slivers: <Widget>[
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: page),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (_isLocal && !_isLocalSource)
                      MyComicStaggeredEntrance(
                        index: 1,
                        child: _buildLocalDetails(context),
                      )
                    else
                      _buildChapterList(context),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
    // 多选态点空白处退出（章节行 / 筛选 chip / 按钮自己的点击会赢下手势竞技场，
    // 不会误触退出）。非多选态不注册识别器，行为与之前完全一致。
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _selectionMode ? _exitSelectionMode : null,
      child: content,
    );
  }

  /// 章节区：刷新中顶一条波浪进度（原 AppBar 刷新钮的转圈挪进了「⋯」菜单，
  /// 进行中的反馈落在被刷新的列表上）+ 共享的 [MangaChapterList]。
  Widget _buildChapterList(BuildContext context) {
    // 每帧把当前筛选 / 排序后的可见章节序登记给多选状态机（全选 / 反选 /
    // 批量动作的唯一定义域）。
    _syncVisibleSelectionOrder();
    // Local source 条目没有在线描述符，但共享章节列表只消费 `entry.chapters`；
    // 借一个展示用条目，回调仍走本地分支（[_openChapterAt] 不碰在线 service）。
    final OnlineMangaLibraryEntry? displayEntry = _displayEntry;
    final bool online = _entry != null;
    // 在线源用描述符里的选中章；本地图源读 LocalSourceMetadata.currentChapterKey
    //（打开 / 换章时由阅读器写回）。
    final String? currentChapterKey =
        _entry?.currentChapter?.key ?? _localSource?.currentChapterKey;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_refreshing)
          const Padding(
            key: ValueKey<String>('manga_series_refreshing'),
            padding: EdgeInsets.only(bottom: 8),
            child: MyComicLinearProgressIndicator(),
          ),
        MangaChapterList(
          entry: displayEntry,
          states: _states,
          newestFirst: _newestFirst,
          unreadOnly: _unreadOnly,
          currentChapterKey: currentChapterKey,
          currentChapterAnchorKey: _currentChapterAnchor,
          onSortToggled: _toggleSort,
          onJumpToCurrent: currentChapterKey == null
              ? null
              : () => scrollToMangaChapterAnchor(
                  _currentChapterAnchor,
                  duration: myComicMotionDuration(context, MyComicMotion.medium),
                ),
          onUnreadOnlyToggled: () => setState(() => _unreadOnly = !_unreadOnly),
          downloadFilter: _downloadFilter,
          onDownloadFilterToggled: () =>
              setState(() => _downloadFilter = _downloadFilter.next),
          onChapterTap: _handleChapterTap,
          // 多选态里长按归 SelectionDragArea（扫选），行自身不再接长按。
          onChapterLongPress: _selectionMode ? null : _handleChapterLongPress,
          selectedChapterKeys: _selectionMode ? _selection.looseKeys : null,
          onToggleRead: _bookUid == null
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_toggleChapterRead(chapter)),
          onMarkUpToRead: _bookUid == null
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_markUpToRead(chapter)),
          // Local source 的章节就在磁盘上原地可读：不显示「未下载」，也不给
          // 下载/删除下载/定位文件等在线动作。
          downloadedChapterKeys: _isLocalSource
              ? _localChapters
                    .map((LocalSourceChapterRecord chapter) => chapter.key)
                    .toSet()
              : _downloaded,
          undeletableDownloadedChapterKeys: _isLocalSource
              ? const <String>{}
              : _downloaded.difference(_deletableDownloaded),
          missingChapterKeys: _isLocalSource
              ? _localMissingChapterKeys
              : const <String>{},
          jobsByChapterKey: _jobs,
          languageScope: _languageScope,
          onSiblingSourceTap: (OnlineMangaSiblingSource sibling) =>
              unawaited(_openSiblingSource(sibling)),
          // 票 08：下载 / 重试 / 删除下载只要求在线条目，不要求页面上已有
          // Library 行——入队会按下载身份补非书架行，删除按记录映射或 entry
          // 身份找容器。定位文件仍需要有行/映射，保持原有门控。
          onDownload: !online
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_enqueueChapter(chapter)),
          onRetryDownload: !online
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_retryChapterDownload(chapter)),
          onDeleteDownload: !online
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_deleteChapterDownload(chapter)),
          onRevealDownload:
              !online || _bookKey == null || currentRevealHost() == null
              ? null
              : (OnlineMangaChapter chapter) =>
                    unawaited(_revealChapterDownload(chapter)),
        ),
      ],
    );
  }

  /// 切换章节排序并写回全局偏好（阅读器章节抽屉同一份）。没有 AppModel（源浏览
  /// 立起的无 ProviderScope 树）时只在本页生效。
  void _toggleSort() {
    setState(() => _newestFirst = !_newestFirst);
    final AppModel? appModel = _appModelOrNull;
    if (appModel != null) {
      unawaited(appModel.setMangaChapterListNewestFirst(_newestFirst));
    }
  }

  /// 快速滚动条只跟正文那个滚动视图：宽屏两栏时左栏（hero）也会冒滚动通知。
  bool _isBodyScroll(ScrollNotification notification) {
    if (notification.depth != 0 || !_scroll.hasClients) return false;
    final ScrollableState? scrollable = notification.context
        ?.findAncestorStateOfType<ScrollableState>();
    return scrollable != null &&
        _scroll.positions.contains(scrollable.position);
  }

  /// 可读文案：桥接层 message 往往是 `Exception: ...` 原串，经
  /// [OnlineMangaUnavailable.userMessage] 归一（2026-10 体验优化）；原串只进
  /// 「查看详情」。
  static String _loadErrorText(OnlineMangaUnavailable error) =>
      error.userMessage;

  /// 一点内容都拉不到时的完整错误视图。
  ///
  /// 三件事缺一不可（BUG-1767 用例逐条盯着）：**原因可见**（把桥接层给的
  /// message 原样摆出来，不是一句「加载失败」）、**诊断入口**（原生堆栈和失败
  /// 阶段太长不能铺在页面上，只能进可复制对话框）、**重试真的重发请求**。
  Widget _buildLoadError(BuildContext context, OnlineMangaUnavailable error) {
    // 源被禁用 / 平台不支持时重试永远不会成功，别给一个骗人的按钮。
    final bool retryable =
        error.reason == OnlineMangaUnavailableReason.runtimeFailure;
    return SingleChildScrollView(
      child: MyComicPlaceholderMessage(
        icon: MyComicIcons.cloudOff,
        tone: MyComicPlaceholderTone.error,
        message: t.manga_online_detail_load_failed,
        // 原始异常（含堆栈）在「查看详情」对话框里，这里给可读短句。
        detail: _loadErrorText(error),
        detailMaxLines: 6,
        action: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            if (retryable)
              MyComicFilledButton.icon(
                key: const ValueKey<String>('manga_series_error_retry'),
                onPressed: _refreshing
                    ? null
                    : () => unawaited(_refreshFromSource()),
                icon: const MyComicIcon(MyComicIcons.refresh),
                label: Text(t.retry),
              ),
            _challengeAction(error),
            MyComicTextButton(
              key: const ValueKey<String>('manga_series_error_details'),
              onPressed: () => unawaited(
                showErrorDetails(
                  context,
                  title: t.mihon_extension_error,
                  error: error.diagnostics,
                ),
              ),
              child: Text(t.manga_online_error_view_detail),
            ),
          ],
        ),
      ),
    );
  }

  /// 读库本身失败（条目被删 / 数据库异常）：错误占位 + 重试（重新走一遍
  /// [_load]，不是只刷新源）。
  Widget _buildFatalError(BuildContext context, Object error) =>
      SingleChildScrollView(
        child: MyComicPlaceholderMessage(
          icon: MyComicIcons.error,
          tone: MyComicPlaceholderTone.error,
          message: t.manga_online_detail_load_failed,
          detail: describeOnlineSourceError(error),
          detailMaxLines: 6,
          action: MyComicFilledButton.icon(
            key: const ValueKey<String>('manga_series_fatal_retry'),
            onPressed: _retryLoad,
            icon: const MyComicIcon(MyComicIcons.refresh),
            label: Text(t.retry),
          ),
        ),
      );

  void _retryLoad() {
    setState(() {
      _fatalError = null;
      _loading = true;
    });
    unawaited(_load());
  }

  /// 刷新失败提示条（hero 简介下方，不遮挡章节）。
  ///
  /// 按 [OnlineMangaUnavailableReason] 分流是有意义的：源被禁用和网络抽风给的
  /// 出路完全不同，把两者都渲染成「加载失败 + 重试」会让用户对着一个永远不会
  /// 成功的按钮反复点。按钮另起一行 Wrap：两栏左栏只有 400 宽，与文案并排必溢出。
  Widget _buildRefreshBanner(
    BuildContext context,
    OnlineMangaUnavailable error,
  ) {
    final ThemeData theme = Theme.of(context);
    final (String text, bool retryable) = switch (error.reason) {
      OnlineMangaUnavailableReason.sourceDisabled => (
        t.manga_series_source_disabled,
        false,
      ),
      OnlineMangaUnavailableReason.platformUnsupported => (
        t.manga_series_platform_unsupported,
        false,
      ),
      OnlineMangaUnavailableReason.runtimeFailure => (
        t.manga_series_refresh_failed,
        true,
      ),
    };
    return MyComicCard(
      key: const ValueKey<String>('manga_series_refresh_banner'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              MyComicIcon(MyComicIcons.cloudOff, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(text, style: theme.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            runSpacing: 4,
            children: <Widget>[
              if (retryable)
                MyComicTextButton(
                  onPressed: _refreshing
                      ? null
                      : () => unawaited(_refreshFromSource()),
                  child: Text(t.retry),
                ),
              _challengeAction(error),
              MyComicTextButton(
                key: const ValueKey<String>('manga_series_error_details'),
                onPressed: () => unawaited(
                  showErrorDetails(
                    context,
                    title: t.manga_online_detail_load_failed,
                    error: '${error.reason}\n\n${error.message}',
                  ),
                ),
                child: Text(t.manga_online_error_view_detail),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 作品页头部：三域共用的 [OnlineWorkHeader]（M3E 详情 hero）——封面模糊大
  /// 背景 + 封面卡 + 来源 overline + 标题 + 作者 / 在书架 chip + 主操作按钮组 +
  /// 类型标签 + 可展开简介（+ 刷新失败提示条）。
  Widget _buildHeader(BuildContext context) {
    final OnlineMangaSeries? series = _entry?.series;
    final String title = _displayTitle;
    final String? authorLine = _authorLine;
    return OnlineWorkHeader(
      cover: _buildCover(context),
      backdrop: _coverImageProvider(),
      overline: _subtitle(),
      title: title,
      titleKey: const ValueKey<String>('manga_series_title'),
      // 书名 / 作者点击 = 以当前显示的文字去全部已启用在线 Source 搜索。
      onTitleTap: () => _openGlobalSearch(title),
      chips: <MediaDetailChip>[
        if (authorLine != null)
          MediaDetailChip(
            authorLine,
            icon: MyComicIcons.person,
            key: const ValueKey<String>('manga_series_author_chip'),
            onTap: () => _openGlobalSearch(authorLine),
          ),
        // 扩展源的作品来自第三方站点（10-09 所有者「外部来源」提示）；互联对端
        // 是用户自己的设备，本地卷没有在线来源，都不标。漫画作品页只保留「扩展源」
        // 一枚：用户明确要求移除「外部来源」（「已入库」同样移除，状态已由书架按钮
        // 表达）；小说作品页共用同一 helper，仍保留两枚。
        if (_entry case final OnlineMangaLibraryEntry entry
            when entry.runtime != OnlineMangaRuntimeKind.interconnect)
          ...extensionSourceDetailChips(includeExternal: false),
      ],
      genres: series?.genreLabels ?? const <String>[],
      // 漫画作品页不截断来源给的分类（ticket 01）；其他作品页沿用原版最多 8 个。
      maxGenres: null,
      // 源分类与书名 / 作者同一条导航：以分类文字去全部已启用在线源搜索。
      onGenreTap: _openGlobalSearch,
      description: series?.description,
      primaryAction: _buildPrimaryAction(),
      secondaryActions: _buildSecondaryActions(),
      moreItems: _buildMoreItems(),
      extra: _buildHeaderExtra(context),
    );
  }

  /// hero 简介后的附加提示。
  ///
  /// 来源确认缺失时给「只有本机已保存章节」的说明（不新增安装/跳转按钮，用户
  /// 自行去扩展页安装）；否则沿用原有的刷新失败横幅。
  Widget? _buildHeaderExtra(BuildContext context) {
    final OnlineMangaLibraryEntry? entry = _entry;
    if (entry != null && _showsMissingSourceNotice) {
      return MyComicInlineNotice(
        key: const ValueKey<String>('manga_series_missing_source_notice'),
        severity: MyComicNoticeSeverity.warning,
        title: _missingSourceLabel(entry),
        message: t.manga_series_source_missing_hint,
      );
    }
    final OnlineMangaUnavailable? refreshError = _refreshError;
    return refreshError == null
        ? null
        : _buildRefreshBanner(context, refreshError);
  }

  /// ticket 02：没有更优先封面时，懒生成 / 载入第一页生成封面。
  ///
  /// 优先级：本地 `cover.*` → 真实来源封面（持久字节缓存或当前 URL）→ 第一页
  /// 生成封面 → 占位。来源未安装 / 停用时先检查本地与持久缓存，再生成；不会
  /// 发起远程请求。生成只写 Program state 缓存。
  Future<void> _ensureGeneratedCover() async {
    final MangaFirstPageCoverService? service = _firstPageCoverService();
    if (service == null) return;
    if (_localCoverPath() != null) {
      _clearGeneratedCoverState();
      return;
    }
    final EpubBookRow? row = _row;
    // 与书架 / 重建预热共用「已有更优先封面」判据：本地记录封面（含页路径）
    // 与持久真实来源字节都不生成第一页封面。
    final MangaCoverResolution? existing = row == null
        ? null
        : await service.resolveExistingCover(row);
    if (existing?.hasExistingCover ?? false) {
      if (mounted) {
        setState(() {
          _shelfCachedCoverUrl = existing!.realCachedUrl;
          _generatedCoverUrl = null;
        });
      }
      return;
    }
    final String? bookKey = _bookKey;
    if (row == null && bookKey != null) {
      final String? realCached = await service.cachedRealCoverUrl(bookKey);
      if (realCached != null) {
        if (mounted) {
          setState(() {
            _shelfCachedCoverUrl = realCached;
            _generatedCoverUrl = null;
          });
        }
        return;
      }
    }
    final MangaSeriesTarget target = widget.target;
    if (target is SourceMangaSeriesTarget &&
        target.remoteCoverBuilder != null) {
      _clearGeneratedCoverState();
      return;
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    final bool sourceUsable =
        entry == null || (_adapter != null && _service != null);
    final bool remoteUsable =
        sourceUsable && !_sourceMissing && _remoteCoverUrl() != null;
    if (remoteUsable) {
      _clearGeneratedCoverState();
      return;
    }
    String? generated;
    if (row != null) {
      generated = await service.ensureGeneratedCover(row);
    } else {
      final LocalSourceManga? scanned = _scannedLocal;
      if (scanned != null) {
        generated = await service.ensureGeneratedCoverForScanned(
          manga: scanned,
          bookKey: localSourceBookKeyFor(scanned.directoryPath),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _shelfCachedCoverUrl = null;
      _generatedCoverUrl = generated;
    });
  }

  void _clearGeneratedCoverState() {
    if (!mounted) return;
    if (_generatedCoverUrl == null && _shelfCachedCoverUrl == null) return;
    setState(() {
      _generatedCoverUrl = null;
      _shelfCachedCoverUrl = null;
    });
  }

  /// 本地已落盘封面的路径；未入库 / 无封面为 null。
  String? _localCoverPath() {
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) {
      // 未入库作品仍按 Local source 的封面约定解析（cover.jpg/jpeg/png，
      // 大小写不敏感），缺失时作品页用占位块。
      return ReaderMyComicSource.resolveCoverFilePath(
        extractDir: scanned.directoryPath,
        coverPath: scanned.coverRelativePath,
      );
    }
    final EpubBookRow? row = _row;
    if (row == null) return null;
    // 复用书架/制卡那份解析（TODO-1388 / BUG-703），别自己拼路径：coverPath 可能
    // 是相对页图路径、可能大小写与磁盘不符（跨平台备份还原），那些坑都已经在
    // resolveCoverFilePath 里踩过了。
    return ReaderMyComicSource.resolveCoverFilePath(
      extractDir: row.extractDir,
      coverPath: row.coverPath,
    );
  }

  /// hero 大背景：本地封面 / 持久缓存 / 生成封面模糊铺底。未入库的源条目只有
  /// 来源自己的取图控件、拿不到 ImageProvider，就只画色晕。
  ImageProvider? _coverImageProvider() {
    final String? path = _localCoverPath();
    if (path != null) return FileImage(File(path));
    final String? cachedPath =
        _coverCacheFilePath(_shelfCachedCoverUrl) ??
        _coverCacheFilePath(_generatedCoverUrl);
    return cachedPath == null ? null : FileImage(File(cachedPath));
  }

  /// `file://` 缓存 URL → 本地路径；其它协议 / 坏 URL 返回 null。
  String? _coverCacheFilePath(String? url) {
    if (url == null) return null;
    try {
      return Uri.parse(url).toFilePath();
    } on Object {
      return null;
    }
  }

  /// 渲染 Program state 缓存里的封面；解码失败退回占位块。
  Widget _buildCachedCoverImage(String url) {
    final String? path = _coverCacheFilePath(url);
    if (path == null) return const MangaCoverPlaceholder();
    return Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, Object error, __) {
        ErrorLogService.instance.logDiagnostic(
          'MangaSeriesPage.coverDecode',
          '$path: $error',
        );
        return const MangaCoverPlaceholder();
      },
    );
  }

  /// 备份里保存的远程封面 URL（导入条目）。来源未安装也能用——它不经过 Source，
  /// 只是描述符里的一个地址。
  String? _remoteCoverUrl() {
    final String? url = _entry?.series.coverUrl?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  /// 封面。
  ///
  /// 顺序固定（ticket 02）：**本地已落盘** `cover.*` → 真实来源封面（按 bookKey
  /// 的持久字节缓存 / 来源当前 URL）→ 第一页生成封面 → 占位块。在线条目在来源
  /// 解析完成前 / 来源未安装时不会发起远程请求：先检查本地与持久缓存，再显示
  /// 生成封面或灰占位。
  Widget _buildCover(BuildContext context) {
    final String? resolved = _localCoverPath();
    if (resolved != null) {
      return Image.file(
        File(resolved),
        fit: BoxFit.cover,
        // BUG-2496：坏封面文件解码失败退回占位块，不当致命 FlutterError。
        errorBuilder: (_, Object error, __) {
          ErrorLogService.instance.logDiagnostic(
            'MangaSeriesPage.coverDecode',
            '$resolved: $error',
          );
          return const MangaCoverPlaceholder();
        },
      );
    }
    final String? realCached = _shelfCachedCoverUrl;
    if (realCached != null) return _buildCachedCoverImage(realCached);
    // 来源未安装（或尚未解析完来源）：不请求远程封面；已有生成封面时先显示它。
    if (_entry != null && (!_sourceLabelResolved || _sourceMissing)) {
      final String? generated = _generatedCoverUrl;
      return generated == null
          ? const MangaCoverPlaceholder()
          : _buildCachedCoverImage(generated);
    }
    final MangaSeriesTarget target = widget.target;
    if (target is SourceMangaSeriesTarget) {
      final Widget Function(BuildContext)? builder = target.remoteCoverBuilder;
      if (builder != null) return builder(context);
    }
    final String? remoteUrl = _remoteCoverUrl();
    if (remoteUrl != null) {
      return Image(
        image: AppCachedHttpImage(remoteUrl),
        fit: BoxFit.cover,
        // 远程封面过期 / 防盗链 / 网络失败只影响这一部作品：回到同一占位块。
        errorBuilder: (_, Object error, __) {
          ErrorLogService.instance.logDiagnostic(
            'MangaSeriesPage.coverDecode',
            '$remoteUrl: $error',
          );
          return const MangaCoverPlaceholder();
        },
      );
    }
    final String? generated = _generatedCoverUrl;
    if (generated != null) return _buildCachedCoverImage(generated);
    return const MangaCoverPlaceholder();
  }

  /// 在飞下载（排队 / 执行中）的整体页进度：主按钮下挂波浪条。没有在飞任务 =
  /// null；页数还不知道 = -1（不确定进度）。
  double? get _downloadProgress {
    bool active = false;
    int done = 0;
    int total = 0;
    for (final MangaDownloadJobRow job in _jobs.values) {
      if (job.status != MangaDownloadJobStatus.queued &&
          job.status != MangaDownloadJobStatus.running) {
        continue;
      }
      active = true;
      done += job.pagesDone;
      total += job.pagesTotal;
    }
    if (!active) return null;
    if (total <= 0) return -1;
    return (done / total).clamp(0.0, 1.0);
  }

  /// 主按钮：本地卷「继续阅读」；在线作品「继续阅读 · 第 N 话」（未入库点了会
  /// 先入库再读，见 [_openChapterAt]）。
  ///
  /// 未入库的本地扫描结果还不是可续读的书架条目：动作区只放「加入书架」，
  /// 不渲染一个永远禁用的「继续阅读」死控件（见 [_buildSecondaryActions] 的
  /// 同款短路）。按钮沿用原有 tonal 次按钮视觉（ADR 0008：不新增样式）。
  Widget? _buildPrimaryAction() {
    final LocalSourceManga? scanned = _scannedLocal;
    if (scanned != null) {
      return MediaDetailSecondaryButton(
        buttonKey: const ValueKey<String>('manga_series_add_to_bookshelf'),
        icon: MyComicIcons.libraryAdd,
        label: t.mihon_add_to_bookshelf,
        onPressed: _busy
            ? null
            : () => unawaited(_addScannedLocalToLibrary(scanned)),
      );
    }
    if (_isLocal) {
      if (_isLocalSource) {
        final int resumeIndex = _localResumeIndex;
        return MediaDetailPrimaryButton(
          buttonKey: const ValueKey<String>('manga_series_open_local'),
          icon: MyComicIcons.play,
          label: t.book_continue_reading,
          onPressed: _busy || resumeIndex < 0
              ? null
              : () => unawaited(_openChapterAt(resumeIndex)),
        );
      }
      return MediaDetailPrimaryButton(
        buttonKey: const ValueKey<String>('manga_series_open_local'),
        icon: MyComicIcons.play,
        label: t.book_continue_reading,
        onPressed: _busy ? null : () => unawaited(_openLocalBook()),
      );
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    final int resumeIndex = _resumeIndex;
    final OnlineMangaChapter? resumeChapter =
        entry != null && resumeIndex >= 0 && resumeIndex < entry.chapters.length
        ? entry.chapters[resumeIndex]
        : null;
    return MediaDetailPrimaryButton(
      buttonKey: const ValueKey<String>('manga_series_continue'),
      icon: MyComicIcons.play,
      label: resumeChapter == null
          ? t.book_continue_reading
          : '${t.book_continue_reading} · ${resumeChapter.name}',
      progress: _downloadProgress,
      onPressed: resumeChapter == null || _busy
          ? null
          : () => unawaited(_openChapterAt(resumeIndex)),
    );
  }

  /// 次按钮（tonal）：加入 ↔ 移出书架（同一位置，在库时 selected）、下载全部；
  /// 订阅（书签）与登录是图标钮。本地卷只有「OCR 设置」。
  List<Widget> _buildSecondaryActions() {
    // 未入库的本地扫描结果只有「加入书架」，且已作为主按钮渲染（唯一动作）。
    if (_scannedLocal != null) return <Widget>[];
    if (_isLocal) {
      // my-comic：端上 OCR 已移除，本地卷详情页不再提供识别 / OCR 设置入口。
      // Local source 作品在书架时必须能「移出书架」且默认不删文件（ADR 0013）；
      // 移出后（membership=false）按钮消失（票 04）。受管本地卷（mokuro/PDF
      // 转漫画）沿用书架长按菜单的删除路径，这里不加按钮。
      if (_isLocalSource && (_row?.isInLibrary ?? false)) {
        return <Widget>[
          MediaDetailSecondaryButton(
            buttonKey: const ValueKey<String>(
              'manga_series_remove_from_bookshelf',
            ),
            icon: MyComicIcons.libraryAdd,
            label: t.manga_series_remove_from_bookshelf,
            selected: true,
            onPressed: _busy ? null : () => unawaited(_removeFromLibrary()),
          ),
        ];
      }
      return <Widget>[];
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    // 加入 / 移出按 Library membership 判断：票 02 起源作品页一打开就有行，
    // 「有行」不再等于「在书架」。票 08：下载全部也不再要求页面先有行——入队
    // 会按下载身份补一条非书架行。
    final bool isLibraryMember = _row?.isInLibrary ?? false;
    final OnlineMangaLoginTarget? login = _loginTarget;
    return <Widget>[
      // 同一个位置、同一个按钮：不在库是「加入」，在库是「移出」（用户诉求：加了
      // 要能取消）。移出走书架同一条 deleteBook 路径，连已下载章节一起删。
      if (isLibraryMember)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>(
            'manga_series_remove_from_bookshelf',
          ),
          icon: MyComicIcons.libraryAdd,
          label: t.manga_series_remove_from_bookshelf,
          selected: true,
          onPressed: _busy ? null : () => unawaited(_removeFromLibrary()),
        )
      else
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_add_to_bookshelf'),
          icon: MyComicIcons.libraryAdd,
          label: t.mihon_add_to_bookshelf,
          onPressed: _busy ? null : () => unawaited(_addToLibrary()),
        ),
      if (entry != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_download_all'),
          icon: MyComicIcons.download,
          label: t.manga_series_download_all,
          onPressed: _busy ? null : () => unawaited(_downloadAll()),
        ),
      if (entry != null && isLibraryMember && _service != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_subscribe'),
          icon: entry.subscribed ? MyComicIcons.bookmark : MyComicIcons.bookmarkAdd,
          label: entry.subscribed
              ? t.manga_series_unsubscribe
              : t.manga_series_subscribe,
          selected: entry.subscribed,
          iconOnly: true,
          onPressed: _busy ? null : () => unawaited(_toggleSubscription()),
        ),
      // 源站要登录才给锁章（BUG-2497）：入口放在用户看到「锁」的这一页、常驻
      // 可见，不必先点一条锁章再从弹窗里找。
      if (login != null)
        MediaDetailSecondaryButton(
          buttonKey: const ValueKey<String>('manga_series_login'),
          icon: MyComicIcons.login,
          label: t.mihon_source_login,
          iconOnly: true,
          onPressed: _busy || _refreshing
              ? null
              : () => unawaited(_loginToSource(login)),
        ),
    ];
  }

  /// 「⋯」：在网站打开、刷新章节、新章自动下载（订阅中）、下载后自动识别、
  /// 识别全部已下载、OCR 设置（在库）。
  List<MediaDetailMenuItem> _buildMoreItems() {
    if (_isLocal) {
      final Future<void> Function()? showShelfMenu = switch (widget.target) {
        ShelfMangaSeriesTarget(:final showShelfMenu) => showShelfMenu,
        SourceMangaSeriesTarget() => null,
        LocalSourceMangaSeriesTarget() => null,
      };
      return <MediaDetailMenuItem>[
        if (showShelfMenu != null)
          MediaDetailMenuItem(
            key: const ValueKey<String>('manga_series_manage_volume'),
            icon: MyComicIcons.settings,
            label: t.manga_series_manage_volume,
            enabled: !_busy,
            onSelected: () => unawaited(_openShelfMenu(showShelfMenu)),
          ),
        // 删除本地文件是**单独**且二次确认的动作；「移出书架」只删记录。
        // Ticket 10 的恢复条目指向 downloads 根，不在 local 内，
        // LocalSourceLibrary.deleteLocalFiles 会拒绝——入口直接隐藏，不给一个
        // 必然失败的动作。
        if (_isLocalSource && _row != null && _canDeleteLocalSourceFiles(_row!))
          MediaDetailMenuItem(
            key: const ValueKey<String>('manga_series_delete_local_files'),
            icon: MyComicIcons.delete,
            label: t.manga_series_delete_local_files,
            enabled: !_busy,
            onSelected: () =>
                unawaited(_deleteLocalSourceFiles(_row!, _appModel)),
          ),
      ];
    }
    final OnlineMangaLibraryEntry? entry = _entry;
    final Object? adapter = _adapter;
    // 自动追更（新章自动下载）只对书架成员开放。
    final bool isLibraryMember = _row?.isInLibrary ?? false;
    return <MediaDetailMenuItem>[
      // 源站网页入口：只有在线源（Mihon）有网页可去，本地卷 / 互联对端没有。
      if (entry != null && adapter is OnlineMangaWebUrlCapable)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_open_website'),
          icon: MyComicIcons.openInNew,
          label: t.mihon_source_website_open,
          onSelected: () => unawaited(_openWebsite(adapter, entry)),
        ),
      if (entry != null)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_refresh'),
          icon: MyComicIcons.refresh,
          label: t.manga_series_refresh,
          enabled: !_refreshing,
          onSelected: () => unawaited(_refreshFromSource()),
        ),
      if (entry != null &&
          isLibraryMember &&
          _service != null &&
          entry.subscribed)
        MediaDetailMenuItem(
          key: const ValueKey<String>('manga_series_auto_download'),
          icon: entry.autoDownload
              ? MyComicIcons.filled(MyComicIcons.success)
              : MyComicIcons.cloudDownload,
          label: t.manga_series_auto_download,
          enabled: !_busy,
          onSelected: () => unawaited(_toggleAutoDownload()),
        ),
    ];
  }

  /// 「管理本卷」：开书架同一个菜单。页面不按「菜单关了」去重读——书架的动作
  /// 一律先关菜单、之后才弹二次确认 / 落库，那时重读拿到的还是旧行。页面跟随
  /// 的是库的写入通知（[_watchLocalVolume]）。
  Future<void> _openShelfMenu(Future<void> Function() showShelfMenu) =>
      showShelfMenu();

  /// 本地卷跟随库里的真实状态：行没了 / 转成普通书 = 这一页不成立，退出；改名
  /// （`preferences` 里的覆盖层）、重置进度、标记读完则重读刷新。
  void _watchLocalVolume(String bookKey) {
    if (_localVolumeChanges != null) return;
    final MyComicDatabase db = _appModel.database;
    _localVolumeChanges = db
        .tableUpdates(
          TableUpdateQuery.onAllTables(
            <ResultSetImplementation<dynamic, dynamic>>[
              db.epubBooks,
              db.readerPositions,
              db.preferences,
            ],
          ),
        )
        .listen((Set<TableUpdate> _) => unawaited(_syncLocalVolume(bookKey)));
  }

  Future<void> _syncLocalVolume(String bookKey) async {
    final int generation = ++_localVolumeGeneration;
    final EpubBookRow? row = await _appModel.database.getEpubBook(bookKey);
    final ReaderPosition? position = row == null
        ? null
        : await _readLocalPosition(row, null);
    if (!mounted || generation != _localVolumeGeneration) return;
    if (row == null || BookFormat.parseOrEpub(row.format) != BookFormat.manga) {
      // 阅读器还压在上面时不动栈（删书 / 转格式只能从菜单发起，走到这里时
      // 作品页就是顶层）。
      if (ModalRoute.of(context)?.isCurrent ?? false) {
        Navigator.of(context).pop();
      }
      return;
    }
    setState(() {
      _row = row;
      _localPosition = position;
      _localSource = LocalSourceMetadata.tryParse(row.sourceMetadata);
      _localChapters = decodeLocalSourceChapters(row.chaptersJson);
    });
  }

  /// 本地卷没有章节，章节区换成「这一卷有多少页、读到哪」。
  ///
  /// 刻意不去猜「同系列的其它卷」：本地导入是一卷一条目、标题由 mokuro 的
  /// `title`+`volume` 拼出来，按标题前缀猜同系列会把不相干的书归到一起。真正
  /// 的成组关系有合集（`MediaCollections`）承载，那是显式的。
  Widget _buildLocalDetails(BuildContext context) {
    final EpubBookRow? row = _row;
    if (row == null) return const SizedBox.shrink();
    final ReaderPosition? position = _localPosition;
    final int count = position == null ? 1 : 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MediaDetailSectionHeader(t.manga_series_volume_info),
        MediaDetailItemRow(
          index: 0,
          count: count,
          leading: const MyComicIcon(MyComicIcons.books),
          title: t.manga_series_page_count,
          trailing: Text(
            '${row.chapterCount}',
            style: context.myComicType.titleMediumEmphasized.tabular,
          ),
        ),
        // 没打开过就没有位置行，不画「读到第 1 页」冒充进度。
        if (position != null)
          MediaDetailItemRow(
            key: const ValueKey<String>('manga_series_local_progress'),
            index: 1,
            count: count,
            leading: const MyComicIcon(MyComicIcons.bookmark),
            title: row.chapterCount > 0
                ? t.manga_series_read_progress(
                    page: '${position.sectionIndex + 1}',
                    total: '${row.chapterCount}',
                  )
                : t.manga_series_read_progress_partial(
                    page: '${position.sectionIndex + 1}',
                  ),
            progress: row.chapterCount > 0
                ? ((position.sectionIndex + 1) / row.chapterCount).clamp(
                    0.0,
                    1.0,
                  )
                : null,
            completed: row.completedAt != null,
          ),
      ],
    );
  }
}

/// 锁定章弹窗的三条路；取消 = null。
enum _LockedChapterChoice { login, download }
