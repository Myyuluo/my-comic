import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show
        FushiFloatingChromeBar,
        FushiFloatingChromeHost,
        FushiFloatingChromeInset,
        FushiFloatingChromeInsetSpacer;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 一级「历史」页（ADR 0018）。
///
/// 唯一数据源是 `media_open_history`（[loadMangaHistory]）；不读
/// `reader_positions.updatedAt`，也不拿读者进度反推历史。布局沿用 Fushi v3.0.0
/// 的库页语言：MD3 宽窗页内标题胶囊 + 封面网格 + 书名 footer；不显示日期分组。
///
/// 本票只做浏览与打开：点击进入作品页（在库走 [ShelfMangaSeriesTarget]，已移出
/// 书架 / 未入书架走来源作品页；来源不可用给错误提示）。搜索与删除由后续票加。
class MangaHistoryPage extends ConsumerStatefulWidget {
  const MangaHistoryPage({super.key});

  @override
  ConsumerState<MangaHistoryPage> createState() => _MangaHistoryPageState();
}

class _MangaHistoryPageState extends ConsumerState<MangaHistoryPage> {
  late Future<List<MangaHistoryEntry>> _entries;

  @override
  void initState() {
    super.initState();
    _entries = _load();
  }

  Future<List<MangaHistoryEntry>> _load() =>
      loadMangaHistory(ref.read(appProvider).database);

  Future<void> _reload() async {
    final Future<List<MangaHistoryEntry>> next = _load();
    setState(() => _entries = next);
    await next;
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

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiFloatingChromeHost(
      // 与下载页 / 浏览页同一接线：MD3 宽窗只画页内标题胶囊（外壳下发），
      // 窄窗标题交给底栏，Apple / 玻璃设计交给外壳大标题。
      chromeBuilder: (BuildContext context, _, FushiShellActionsSlot slot) =>
          isGlassDesign(context)
          ? const SizedBox.shrink()
          : FushiFloatingChromeBar(tabs: const SizedBox.shrink(), slot: slot),
      child: FushiEntranceScope(
        child: FutureBuilder<List<MangaHistoryEntry>>(
          future: _entries,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<MangaHistoryEntry>> snapshot,
              ) {
                if (snapshot.hasError) {
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
                          icon: FushiIcons.cloudOff,
                          message: t.online_source_error_generic,
                        ),
                      ),
                    ],
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: FushiLoadingView());
                }
                final List<MangaHistoryEntry> entries = snapshot.data!;
                if (entries.isEmpty) {
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
                          key: const ValueKey<String>('manga_history_empty'),
                          icon: FushiIcons.history,
                          message: t.manga_history_empty,
                        ),
                      ),
                    ],
                  );
                }
                return LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) =>
                      GridView.builder(
                        key: const ValueKey<String>('manga_history_grid'),
                        padding: EdgeInsets.fromLTRB(
                          tokens.spacing.page,
                          FushiFloatingChromeInset.of(context) +
                              tokens.spacing.page,
                          tokens.spacing.page,
                          tokens.spacing.page,
                        ),
                        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: readerShelfGridExtentForLayout(
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
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        itemCount: entries.length,
                        itemBuilder: (BuildContext context, int index) {
                          final MangaHistoryEntry entry = entries[index];
                          return FushiStaggeredEntrance(
                            index: index,
                            child: _MangaHistoryCard(
                              key: ValueKey<String>(
                                'manga_history_card_${entry.key}',
                              ),
                              entry: entry,
                              onTap: () => _openEntry(entry),
                            ),
                          );
                        },
                      ),
                );
              },
        ),
      ),
    );
  }
}

/// 历史卡：共享 [ShelfCoverFrame] + [ShelfCardFooter]，与书架卡同一视觉语言。
class _MangaHistoryCard extends StatelessWidget {
  const _MangaHistoryCard({
    required this.entry,
    required this.onTap,
    super.key,
  });

  final MangaHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: FushiHoverLift(
        builder: (BuildContext context, bool _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(child: ShelfCoverFrame(child: _MangaHistoryCover(entry))),
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
