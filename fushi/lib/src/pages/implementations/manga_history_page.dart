import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeHost,
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetSpacer;
import 'package:fushi/src/utils/components/fushi_header_search.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一级「历史」页（ADR 0018）。
///
/// 唯一数据源是 `media_open_history`（[loadMangaHistory]）；不读
/// `reader_positions.updatedAt`，也不拿读者进度反推历史。布局沿用 Fushi v3.0.0
/// 的库页语言：MD3 宽窗页内标题胶囊 + 封面网格 + 书名 footer；按本地阅读日期
/// 分组，并在每组上方显示日期头。
///
/// 右上角只有「搜索」「删除」两个动作：搜索复用页头可展开搜索（
/// [FushiHeaderSearchController] + [FushiFloatingChromeBar] 整行换搜索栏），按
/// 书名实时过滤；删除分单本与全部，单本立即删除并 toast，全部先二次确认。
/// 删除只动 `media_open_history`，不碰 Reading progress / 章节 `readAt` / 书级
/// 完成标记 / 书架状态（ADR 0018）。
class MangaHistoryPage extends ConsumerStatefulWidget {
  const MangaHistoryPage({super.key});

  @override
  ConsumerState<MangaHistoryPage> createState() => _MangaHistoryPageState();
}

class _MangaHistoryPageState extends ConsumerState<MangaHistoryPage> {
  late Future<List<MangaHistoryEntry>> _entries;

  /// 会话内搜索词（不落库）：由页头可展开搜索实时给出，收起即清空。
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  /// 页头可展开搜索（ticket 01 修复后的共享组件）：展开时整行换成搜索栏，
  /// 输入实时过滤网格，Esc / ← 先清空再收起。
  late final FushiHeaderSearchController _headerSearch =
      FushiHeaderSearchController(
        textController: _searchController,
        buttonFocusId: const FushiFocusId('manga-history-search'),
        hintText: t.manga_history_search_hint,
        fieldKey: const ValueKey<String>('manga_history_search_field'),
        onQueryChanged: (String value) => setState(() => _query = value),
      );

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  @override
  void dispose() {
    _headerSearch.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<List<MangaHistoryEntry>> _load() =>
      loadMangaHistory(ref.read(appProvider).database);

  Future<void> _reload() async {
    final Future<List<MangaHistoryEntry>> next = _load();
    setState(() => _entries = next);
    await next;
  }

  /// 单本删除：立即删历史行并 toast，不逐条确认。
  Future<void> _deleteEntry(MangaHistoryEntry entry) async {
    List<MangaHistoryEntry> current = const <MangaHistoryEntry>[];
    try {
      current = await _entries;
    } on Object {
      // 加载失败时仍允许删除（用户看到的是错误态，历史行本身可能读不出来）。
    }
    if (!mounted) return;
    await deleteMangaHistoryEntry(ref.read(appProvider).database, entry);
    if (!mounted) return;
    setState(() {
      _entries = Future<List<MangaHistoryEntry>>.value(
        current
            .where((MangaHistoryEntry item) => item.key != entry.key)
            .toList(growable: false),
      );
    });
    FushiToast.show(msg: t.manga_history_deleted_entry);
  }

  /// 全部删除：二次确认后清空全部漫画历史。
  Future<void> _confirmDeleteAll() async {
    final bool confirmed = await showFushiConfirmDialog(
      context: context,
      title: t.manga_history_delete_all_confirm_title,
      message: t.manga_history_delete_all_confirm_body,
      confirmLabel: t.manga_history_delete_all_confirm_action,
      icon: FushiIcons.deleteSweep,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await clearMangaHistory(ref.read(appProvider).database);
    if (!mounted) return;
    setState(() {
      _entries = Future<List<MangaHistoryEntry>>.value(
        const <MangaHistoryEntry>[],
      );
    });
    FushiToast.show(msg: t.manga_history_deleted_all);
  }

  void _toastUnavailable() {
    FushiToast.show(
      msg: t.manga_series_source_disabled,
      severity: ToastSeverity.error,
    );
  }

  Future<void> _openEntry(MangaHistoryEntry entry) async {
    final AppModel appModel = ref.read(appProvider);
    // 在 Library：直接进作品页（章节、已读标记、下载状态都齐）。
    final String? bookKey = entry.bookKey;
    if (bookKey != null) {
      // 历史页加载与点击之间作品可能已被删除（书架删除 / 同步删除 / 清库）：
      // 带 bookKey 进作品页会因行不存在落到错误态。先确认 Library 行还在；
      // 不在就按快照回退到来源作品页，来源也没有时给错误提示并保留条目。
      final bool rowExists =
          (await appModel.database.getEpubBook(bookKey)) != null;
      if (!mounted) return;
      if (rowExists) {
        await _pushSeries(ShelfMangaSeriesTarget(bookKey));
        return;
      }
    }
    // 未入书架 / 已移出书架：快照里带着来源身份，按来源重新打开作品页。
    final MangaHistoryOnlineRef? online = entry.online;
    if (online != null) {
      final OnlineMangaLibraryService service;
      try {
        service = appModel.onlineMangaLibraryService(online.runtime);
      } on Object {
        _toastUnavailable();
        return;
      }
      if (!service.adapter.isSupportedOnThisPlatform) {
        FushiToast.show(
          msg: t.manga_series_platform_unsupported,
          severity: ToastSeverity.error,
        );
        return;
      }
      await _pushSeries(
        SourceMangaSeriesTarget(
          adapter: service.adapter,
          service: service,
          seed: online.seed(title: entry.title),
        ),
      );
      return;
    }
    // 本地作品 / Local source 的 Library 行已经不在：来源不可用。
    _toastUnavailable();
  }

  Future<void> _pushSeries(MangaSeriesTarget target) async {
    await Navigator.of(context).push(
      adaptivePageRoute<void>(
        context: context,
        builder: (BuildContext context) => MangaSeriesPage(target: target),
      ),
    );
    if (!mounted) return;
    // 作品页里可能读了新章节 / 手动改了已读：回来重取一次历史（openedAt 置顶）。
    await _reload();
  }

  /// 右上角动作：搜索（展开整行搜索栏）+ 全部删除。只有这两个。
  Widget _buildHeaderActions() => FushiShellHeaderActions(
    actions: <Widget>[
      fushiHeaderSearchButton(_headerSearch),
      FushiIconButton(
        key: const ValueKey<String>('manga_history_delete_all'),
        icon: FushiIcons.deleteSweep,
        tooltip: t.manga_history_delete_all,
        onTap: _confirmDeleteAll,
      ),
    ],
    search: _headerSearch,
  );

  /// 空态 / 错误态的占位列表：与网格一样让出浮动工具区的顶边留白。
  Widget _buildPlaceholder(
    FushiDesignTokens tokens, {
    required IconData icon,
    required String message,
    Key? key,
  }) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.page,
        tokens.spacing.page,
        tokens.spacing.page,
      ),
      children: <Widget>[
        const FushiFloatingChromeInsetSpacer(),
        Padding(
          padding: EdgeInsets.only(top: tokens.spacing.page),
          child: FushiPlaceholderMessage(
            key: key,
            icon: icon,
            message: message,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiFloatingChromeHost(
      // 与浏览页 / 库页浮动工具栏同一接线：整行由 [FushiFloatingChromeBar] 画，
      // 页内标题胶囊由外壳下发；搜索展开时整行换成搜索栏（ticket 01 的共享
      // 组件）。动作只有「搜索」「删除」两颗。
      chromeBuilder: (BuildContext context, _, FushiShellActionsSlot slot) {
        slot.claimActions(this, visible: true, actions: _buildHeaderActions());
        return FushiFloatingChromeBar(
          tabs: const SizedBox.shrink(),
          slot: slot,
        );
      },
      child: FushiEntranceScope(
        child: FutureBuilder<List<MangaHistoryEntry>>(
          future: _entries,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<MangaHistoryEntry>> snapshot,
              ) {
                if (snapshot.hasError) {
                  return _buildPlaceholder(
                    tokens,
                    icon: FushiIcons.cloudOff,
                    message: t.online_source_error_generic,
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: FushiLoadingView());
                }
                final List<MangaHistoryEntry> entries = snapshot.data!;
                if (entries.isEmpty) {
                  return _buildPlaceholder(
                    tokens,
                    key: const ValueKey<String>('manga_history_empty'),
                    icon: FushiIcons.history,
                    message: t.manga_history_empty,
                  );
                }
                // 搜索实时按书名过滤；清空 / 收起后 `_query` 为空，恢复完整列表。
                final List<MangaHistoryEntry> visible = filterByMediaSearch(
                  entries,
                  _query,
                  (MangaHistoryEntry entry) => <String>[entry.title],
                );
                if (visible.isEmpty) {
                  return _buildPlaceholder(
                    tokens,
                    key: const ValueKey<String>('manga_history_search_empty'),
                    icon: FushiIcons.searchOff,
                    message: t.manga_history_search_empty,
                  );
                }
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final List<_MangaHistoryDateGroup> groups =
                        _groupHistoryByDate(visible);
                    final List<int> startIndexes = <int>[];
                    int nextIndex = 0;
                    for (final _MangaHistoryDateGroup group in groups) {
                      startIndexes.add(nextIndex);
                      nextIndex += group.entries.length;
                    }
                    final double topInset =
                        FushiFloatingChromeInset.of(context);
                    return CustomScrollView(
                      key: const ValueKey<String>('manga_history_grid'),
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: <Widget>[
                        for (int g = 0; g < groups.length; g++) ...<Widget>[
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                tokens.spacing.page,
                                g == 0
                                    ? topInset + tokens.spacing.page
                                    : tokens.spacing.gap +
                                        tokens.spacing.gap / 2,
                                tokens.spacing.page,
                                tokens.spacing.gap,
                              ),
                              child: Text(
                                _historyDateLabel(groups[g].date),
                                key: ValueKey<String>(
                                  'manga_history_date_${groups[g].key}',
                                ),
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurface,
                                    ),
                              ),
                            ),
                          ),
                          SliverPadding(
                            padding: EdgeInsets.symmetric(
                              horizontal: tokens.spacing.page,
                            ),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent:
                                    readerShelfGridExtentForLayout(
                                  mediaWidth: MediaQuery.sizeOf(context).width,
                                  contentWidth: constraints.maxWidth,
                                ),
                                childAspectRatio:
                                    MangaFushiSource.instance.aspectRatio,
                                mainAxisSpacing:
                                    tokens.spacing.gap + tokens.spacing.gap / 2,
                                crossAxisSpacing:
                                    tokens.spacing.gap + tokens.spacing.gap / 2,
                              ),
                              delegate: SliverChildBuilderDelegate(
                                (BuildContext context, int i) {
                                  final MangaHistoryEntry entry =
                                      groups[g].entries[i];
                                  return FushiStaggeredEntrance(
                                    index: startIndexes[g] + i,
                                    child: _MangaHistoryCard(
                                      key: ValueKey<String>(
                                        'manga_history_card_${entry.key}',
                                      ),
                                      entry: entry,
                                      onTap: () => _openEntry(entry),
                                      onDelete: () => _deleteEntry(entry),
                                    ),
                                  );
                                },
                                childCount: groups[g].entries.length,
                              ),
                            ),
                          ),
                        ],
                        SliverToBoxAdapter(
                          child: SizedBox(height: tokens.spacing.page),
                        ),
                      ],
                    );
                  },
                );
              },
        ),
      ),
    );
  }
}

/// 历史日期分组：同一本地日期的条目共享一个日期头。
class _MangaHistoryDateGroup {
  _MangaHistoryDateGroup(this.key, this.date);

  final String key;
  final DateTime date;
  final List<MangaHistoryEntry> entries = <MangaHistoryEntry>[];
}

List<_MangaHistoryDateGroup> _groupHistoryByDate(
  List<MangaHistoryEntry> entries,
) {
  final Map<String, _MangaHistoryDateGroup> groups =
      <String, _MangaHistoryDateGroup>{};
  for (final MangaHistoryEntry entry in entries) {
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(entry.openedAt);
    final DateTime day = DateTime(at.year, at.month, at.day);
    final String key = '${day.year}-${day.month}-${day.day}';
    groups
        .putIfAbsent(key, () => _MangaHistoryDateGroup(key, day))
        .entries
        .add(entry);
  }
  return groups.values.toList(growable: false);
}

/// 日期头文案与参考图一致：`11月07日`（日零填充）。
String _historyDateLabel(DateTime day) =>
    '${day.month}月${day.day.toString().padLeft(2, '0')}日';

/// 历史卡：共享 [ShelfCoverFrame] + [ShelfCardFooter]，与书架卡同一视觉语言。
class _MangaHistoryCard extends StatelessWidget {
  const _MangaHistoryCard({
    required this.entry,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final MangaHistoryEntry entry;
  final VoidCallback onTap;

  /// 单本删除：立即执行，不逐条确认。
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final double overlayInset = tokens.spacing.gap * 0.75;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FushiHoverLift(
        builder: (BuildContext context, bool _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  ShelfCoverFrame(child: _MangaHistoryCover(entry)),
                  // 封面右上角原未读角标位置：单本删除按钮。
                  PositionedDirectional(
                    top: overlayInset,
                    end: overlayInset,
                    child: FushiIconButton(
                      key: ValueKey<String>(
                        'manga_history_delete_${entry.key}',
                      ),
                      icon: FushiIcons.delete,
                      tooltip: t.manga_history_delete_entry,
                      size: 16,
                      padding: const EdgeInsets.all(8),
                      backgroundColor: coverBadgeScrim(context),
                      enabledColor: coverBadgeForeground(context),
                      onTap: onDelete,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: ShelfCardFooter.heightFor(context),
              child: ShelfCardFooter(title: entry.title),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面：Library 命中的本地落盘封面优先；否则快照里的本地文件 / 远端封面。
class _MangaHistoryCover extends StatelessWidget {
  const _MangaHistoryCover(this.entry);

  final MangaHistoryEntry entry;

  Widget _placeholder() => const ShelfCoverPlaceholder(icon: FushiIcons.manga);

  @override
  Widget build(BuildContext context) {
    final String? path = entry.coverFilePath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    final String? url = entry.coverUrl;
    if (url != null && url.isNotEmpty) {
      return Image(
        image: AppCachedHttpImage(url, cacheKey: entry.key),
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }
    return _placeholder();
  }
}
