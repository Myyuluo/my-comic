import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/manga/download/scan_downloaded_manga_service.dart';
import 'package:fushi/src/media/manga/library/manga_first_page_cover_service.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载 → 备份索引」的下载索引动作行（storage-layout 票 09 /
/// ticket 06）。
///
/// 整行可点的动作行：确认框 → 进度（可取消）→ 结果摘要。视觉全部复用现有设置
/// 组件、对话框壳与进度指示器，不改变设计/美术（ADR 0008）。
///
/// 这两个行由 [buildBackupIndexSection] 并入「备份索引」分组；桌面可见性挂在
/// **各自 item** 上，分组本身在所有平台可见，因此移动端仍保留备份功能。
///
/// 服务只接收**当前** Content root 的 `downloads` / `local`，所以入口不会
/// 读旧 Content root，也不会扫描 `autobackup`。动作只重链书架中已有的漫画，
/// 不发现、不新增作品（「检索已下载」负责后者）。
List<SettingsItem> buildDownloadIndexItems() {
  return <SettingsItem>[
    SettingsActionItem(
      id: 'storage.rebuild_index',
      title: t.rebuild_download_index_title,
      subtitle: t.rebuild_download_index_subtitle,
      icon: FushiIcons.refresh,
      visible: (SettingsContext ctx) => isDesktopPlatform,
      cli: const SettingsCliAction.unsupported(
        'Rebuilding the download index shows a confirmation and progress '
        'dialog: Settings → Storage & downloads → Backup index → '
        'Rebuild download index.',
      ),
      onTap: _rebuildDownloadIndex,
    ),
    // 「检索已下载」（票 03）：只发现并加入 `downloads` 中尚未入库的完整作品。
    SettingsActionItem(
      id: 'storage.scan_downloaded',
      title: t.scan_downloaded_title,
      subtitle: t.scan_downloaded_subtitle,
      icon: FushiIcons.search,
      visible: (SettingsContext ctx) => isDesktopPlatform,
      cli: const SettingsCliAction.unsupported(
        'Scanning downloads shows a confirmation and progress dialog: '
        'Settings → Storage & downloads → Backup index → Scan downloaded.',
      ),
      onTap: _scanDownloaded,
    ),
  ];
}

/// 测试缝：替换真正的重建执行体（避免 widget 测试碰真实数据库 / 文件系统）。
@visibleForTesting
Future<RebuildDownloadIndexReport> Function(
  SettingsContext settings,
  RebuildDownloadIndexCancelToken cancelToken,
  void Function(RebuildDownloadIndexProgress progress)? onProgress,
)?
debugRunRebuildDownloadIndex;

Future<RebuildDownloadIndexReport> _runRebuildDownloadIndex(
  SettingsContext settings,
  RebuildDownloadIndexCancelToken cancelToken,
  void Function(RebuildDownloadIndexProgress progress)? onProgress,
) {
  final paths = settings.appModel.appPaths;
  // Ticket 03：重链书架成员时为缺封面的作品预热第一页封面。生成字节只写
  // Program state 的 shelf cover 缓存；来源可用性只读数据库，用来判断远程
  // 封面是否优先于生成封面。
  final MangaFirstPageCoverService? firstPageCoverService =
      MangaFirstPageCoverService.forAppCache(
        database: settings.appModel.database,
        cacheRoot: paths.cacheRoot,
      );
  // 只借来源可用性 predicate：直接调用共享函数，不再为了这一个判断构造整个
  // `MangaShelfCoverService`（也不需要它的缓存）。
  OnlineMangaLibraryService? serviceFor(OnlineMangaRuntimeKind runtime) {
    try {
      return settings.appModel.onlineMangaLibraryService(runtime);
    } on Object {
      return null;
    }
  }

  return RebuildDownloadIndexService(
    database: settings.appModel.database,
    downloadsRoot: paths.downloadsRoot,
    localComicRoot: paths.localComicRoot,
    firstPageCoverService: firstPageCoverService,
    isRemoteCoverAvailable: (entry) =>
        isOnlineMangaSourceAvailable(serviceFor: serviceFor, entry: entry),
  ).run(cancelToken: cancelToken, onProgress: onProgress);
}

/// 两个下载索引动作共用的「确认 → 可取消进度 → 结果摘要」流程。
///
/// 动作差异全部通过参数传入：确认文案、进度标题/图标、执行体、失败提示与
/// 报告正文。进度快照的两个字段（fraction / 当前作品名）用访问器读取，两个
/// 服务各自的 Progress 类型不需要互相认识。
Future<void> _runDownloadIndexAction<TProgress, TReport>({
  required SettingsContext settings,
  required String confirmTitle,
  required String confirmBody,
  required String confirmLabel,
  required String progressTitle,
  required IconData progressIcon,
  required double? Function(TProgress? progress) progressFraction,
  required String? Function(TProgress? progress) progressLabel,
  required void Function() requestCancel,
  required Future<TReport> Function(
    void Function(TProgress progress) onProgress,
  )
  run,
  required String Function(Object error) failureMessage,
  required Future<void> Function(TReport report) showReport,
}) async {
  final bool confirmed = await showSettingsConfirmationDialog(
    settings,
    title: confirmTitle,
    body: confirmBody,
    confirmLabel: confirmLabel,
  );
  if (!confirmed || !settings.context.mounted) return;

  final ValueNotifier<TProgress?> progressNotifier = ValueNotifier<TProgress?>(
    null,
  );
  bool progressDialogOpen = true;
  if (settings.context.mounted) {
    unawaited(
      showAppDialog<void>(
        context: settings.context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => PopScope(
          canPop: false,
          child: _DownloadIndexProgressDialog<TProgress>(
            title: progressTitle,
            leadingIcon: progressIcon,
            progressNotifier: progressNotifier,
            fraction: progressFraction,
            label: progressLabel,
            onCancel: () {
              requestCancel();
              Navigator.pop(ctx);
            },
          ),
        ),
      ).whenComplete(() => progressDialogOpen = false),
    );
  }

  final TReport report;
  try {
    report = await run(
      (TProgress progress) => progressNotifier.value = progress,
    );
  } on Object catch (error) {
    if (progressDialogOpen && settings.context.mounted) {
      Navigator.of(settings.context).pop();
    }
    progressNotifier.dispose();
    if (settings.context.mounted) {
      FushiToast.show(
        msg: failureMessage(error),
        severity: ToastSeverity.error,
      );
    }
    return;
  }
  // 用户点取消时进度框已经自己关掉，别再 pop 一次（那会把设置页也弹掉）。
  if (progressDialogOpen && settings.context.mounted) {
    Navigator.of(settings.context).pop();
  }
  progressNotifier.dispose();
  if (!settings.context.mounted) return;
  await showReport(report);
}

/// 确认 → 进度（可取消）→ 结果摘要。全程只触发服务，文件操作都在服务里。
Future<void> _rebuildDownloadIndex(SettingsContext settings) async {
  final RebuildDownloadIndexCancelToken cancelToken =
      RebuildDownloadIndexCancelToken();
  await _runDownloadIndexAction<
    RebuildDownloadIndexProgress,
    RebuildDownloadIndexReport
  >(
    settings: settings,
    confirmTitle: t.rebuild_download_index_confirm_title,
    confirmBody: t.rebuild_download_index_confirm_body,
    confirmLabel: t.rebuild_download_index_button,
    progressTitle: t.rebuild_download_index_progress_title,
    progressIcon: FushiIcons.refresh,
    progressFraction: (RebuildDownloadIndexProgress? progress) =>
        progress?.fraction,
    progressLabel: (RebuildDownloadIndexProgress? progress) =>
        progress?.currentTitle,
    requestCancel: cancelToken.cancel,
    run: (void Function(RebuildDownloadIndexProgress) onProgress) =>
        (debugRunRebuildDownloadIndex ?? _runRebuildDownloadIndex)(
          settings,
          cancelToken,
          onProgress,
        ),
    failureMessage: (Object error) =>
        t.rebuild_download_index_failed(message: '$error'),
    showReport: (RebuildDownloadIndexReport report) =>
        _showRebuildReport(settings, report),
  );
}

Future<void> _showRebuildReport(
  SettingsContext settings,
  RebuildDownloadIndexReport report,
) => _showDownloadIndexReport(
  settings: settings,
  title: t.rebuild_download_index_report_title,
  body: <String>[
    if (report.cancelled) t.rebuild_download_index_report_cancelled,
    t.rebuild_download_index_report_body(
      scanned: report.booksScanned,
      matched: report.booksMatched,
      books: report.booksRelinked,
      chapters: report.chaptersRelinked,
      missingBooks: report.booksMissing,
      missingChapters: report.chaptersMissing,
      skippedBooks: report.booksSkipped,
      ambiguous: report.booksAmbiguous,
      skippedChapters: report.chaptersSkipped,
      failed: report.failed,
    ),
    t.rebuild_download_index_report_covers(
      generated: report.coversGenerated,
      updated: report.coversUpdated,
      skipped: report.coversSkipped,
      failed: report.coversFailed,
    ),
  ].join('\n\n'),
);

/// 两个动作共用的结果摘要对话框壳；正文由各自报告的字段拼接。
Future<void> _showDownloadIndexReport({
  required SettingsContext settings,
  required String title,
  required String body,
}) async {
  await showAppDialog<void>(
    context: settings.context,
    builder: (BuildContext ctx) {
      final FushiDesignTokens tokens = FushiDesignTokens.of(ctx);
      return FushiDialogFrame(
        maxWidth: 440,
        maxHeightFactor: 0.86,
        insetPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.card,
          vertical: tokens.spacing.card,
        ),
        scrollable: false,
        child: FushiModalSheetFrame(
          title: title,
          scrollable: true,
          bodyPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            0,
            tokens.spacing.card,
            tokens.spacing.gap,
          ),
          footerPadding: EdgeInsets.fromLTRB(
            tokens.spacing.card,
            tokens.spacing.gap,
            tokens.spacing.card,
            tokens.spacing.card,
          ),
          body: Text(body, style: tokens.type.listSubtitle),
          footer: Wrap(
            alignment: WrapAlignment.end,
            children: <Widget>[
              adaptiveDialogAction(
                context: ctx,
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx),
                child: Text(t.dialog_done),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 测试缝：替换真正的「检索已下载」执行体（避免 widget 测试碰真实数据库 / 文件系统）。
@visibleForTesting
Future<ScanDownloadedMangaReport> Function(
  SettingsContext settings,
  ScanDownloadedMangaCancelToken cancelToken,
  void Function(ScanDownloadedMangaProgress progress)? onProgress,
)?
debugRunScanDownloadedManga;

Future<ScanDownloadedMangaReport> _runScanDownloaded(
  SettingsContext settings,
  ScanDownloadedMangaCancelToken cancelToken,
  void Function(ScanDownloadedMangaProgress progress)? onProgress,
) {
  final paths = settings.appModel.appPaths;
  return ScanDownloadedMangaService(
    database: settings.appModel.database,
    downloadsRoot: paths.downloadsRoot,
  ).run(cancelToken: cancelToken, onProgress: onProgress);
}

/// 检索确认 → 进度（可取消）→ 结果摘要。全程只触发服务，文件操作都在服务里。
Future<void> _scanDownloaded(SettingsContext settings) async {
  final ScanDownloadedMangaCancelToken cancelToken =
      ScanDownloadedMangaCancelToken();
  await _runDownloadIndexAction<
    ScanDownloadedMangaProgress,
    ScanDownloadedMangaReport
  >(
    settings: settings,
    confirmTitle: t.scan_downloaded_confirm_title,
    confirmBody: t.scan_downloaded_confirm_body,
    confirmLabel: t.scan_downloaded_button,
    progressTitle: t.scan_downloaded_progress_title,
    progressIcon: FushiIcons.search,
    progressFraction: (ScanDownloadedMangaProgress? progress) =>
        progress?.fraction,
    progressLabel: (ScanDownloadedMangaProgress? progress) =>
        progress?.currentTitle,
    requestCancel: cancelToken.cancel,
    run: (void Function(ScanDownloadedMangaProgress) onProgress) =>
        (debugRunScanDownloadedManga ?? _runScanDownloaded)(
          settings,
          cancelToken,
          onProgress,
        ),
    failureMessage: (Object error) =>
        t.scan_downloaded_failed(message: '$error'),
    showReport: (ScanDownloadedMangaReport report) =>
        _showScanReport(settings, report),
  );
}

Future<void> _showScanReport(
  SettingsContext settings,
  ScanDownloadedMangaReport report,
) => _showDownloadIndexReport(
  settings: settings,
  title: t.scan_downloaded_report_title,
  body: <String>[
    if (report.cancelled) t.scan_downloaded_report_cancelled,
    t.scan_downloaded_report_body(
      scanned: report.foldersScanned,
      online: report.addedOnline,
      local: report.addedLocal,
      sourceMissing: report.addedLocalSourceMissing,
      promoted: report.promoted,
      revived: report.revivedTombstones,
      incomplete: report.skippedIncomplete,
      ambiguous: report.skippedAmbiguous,
      failed: report.failed,
    ),
  ].join('\n\n'),
);

/// 下载索引动作共用的进度框：线性进度 + 当前作品名 + 取消。
///
/// 进度快照由各服务自己的类型承载，通过 [fraction] / [label] 访问器读取，
/// 对话框本身不依赖具体服务。
class _DownloadIndexProgressDialog<TProgress> extends StatelessWidget {
  const _DownloadIndexProgressDialog({
    required this.title,
    required this.leadingIcon,
    required this.progressNotifier,
    required this.fraction,
    required this.label,
    required this.onCancel,
  });

  final String title;
  final IconData leadingIcon;
  final ValueNotifier<TProgress?> progressNotifier;
  final double? Function(TProgress? progress) fraction;
  final String? Function(TProgress? progress) label;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: title,
        leadingIcon: leadingIcon,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<TProgress?>(
          valueListenable: progressNotifier,
          builder: (BuildContext context, TProgress? progress, Widget? _) {
            final String currentLabel = label(progress) ?? '';
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiLinearProgressIndicator(value: fraction(progress)),
                SizedBox(height: tokens.spacing.gap),
                Text(
                  currentLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.type.listSubtitle,
                ),
              ],
            );
          },
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: onCancel,
              child: Text(t.dialog_cancel),
            ),
          ],
        ),
      ),
    );
  }
}
