import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载」的「重建下载索引」小节（storage-layout 票 09）。
///
/// 整行可点的动作行：确认框 → 进度（可取消）→ 结果摘要。视觉全部复用现有设置
/// 组件、对话框壳与进度指示器，不改变设计/美术（ADR 0008）。
///
/// 服务只接收**当前** Content root 的 `downloads` / `local`，所以入口不会
/// 读旧 Content root，也不会扫描 `autobackup`。动作只重链书架中已有的漫画，
/// 不发现、不新增作品（「检索已下载」负责后者）。
SettingsSection buildRebuildDownloadIndexSection() {
  return SettingsSection(
    id: 'storage.rebuild.section',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.rebuild_download_index_section,
    visible: (SettingsContext ctx) => isDesktopPlatform,
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'storage.rebuild_index',
        title: t.rebuild_download_index_title,
        subtitle: t.rebuild_download_index_subtitle,
        icon: FushiIcons.refresh,
        cli: const SettingsCliAction.unsupported(
          'Rebuilding the download index shows a confirmation and progress '
          'dialog: Settings → Storage & downloads → Download index → '
          'Rebuild download index.',
        ),
        onTap: _rebuildDownloadIndex,
      ),
    ],
  );
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
  return RebuildDownloadIndexService(
    database: settings.appModel.database,
    downloadsRoot: paths.downloadsRoot,
    localComicRoot: paths.localComicRoot,
  ).run(cancelToken: cancelToken, onProgress: onProgress);
}

/// 确认 → 进度（可取消）→ 结果摘要。全程只触发服务，文件操作都在服务里。
Future<void> _rebuildDownloadIndex(SettingsContext settings) async {
  final bool confirmed = await showSettingsConfirmationDialog(
    settings,
    title: t.rebuild_download_index_confirm_title,
    body: t.rebuild_download_index_confirm_body,
    confirmLabel: t.rebuild_download_index_button,
  );
  if (!confirmed || !settings.context.mounted) return;

  final RebuildDownloadIndexCancelToken cancelToken =
      RebuildDownloadIndexCancelToken();
  final ValueNotifier<RebuildDownloadIndexProgress?> progressNotifier =
      ValueNotifier<RebuildDownloadIndexProgress?>(null);
  bool progressDialogOpen = true;
  if (settings.context.mounted) {
    unawaited(
      showAppDialog<void>(
        context: settings.context,
        barrierDismissible: false,
        builder: (BuildContext ctx) => PopScope(
          canPop: false,
          child: RebuildDownloadIndexProgressDialog(
            progressNotifier: progressNotifier,
            onCancel: () {
              cancelToken.cancel();
              Navigator.pop(ctx);
            },
          ),
        ),
      ).whenComplete(() => progressDialogOpen = false),
    );
  }

  final RebuildDownloadIndexReport report;
  try {
    report = await (debugRunRebuildDownloadIndex ?? _runRebuildDownloadIndex)(
      settings,
      cancelToken,
      (RebuildDownloadIndexProgress progress) =>
          progressNotifier.value = progress,
    );
  } on Object catch (error) {
    if (progressDialogOpen && settings.context.mounted) {
      Navigator.of(settings.context).pop();
    }
    progressNotifier.dispose();
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.rebuild_download_index_failed(message: '$error'),
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
  await _showRebuildReport(settings, report);
}

Future<void> _showRebuildReport(
  SettingsContext settings,
  RebuildDownloadIndexReport report,
) async {
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
          title: t.rebuild_download_index_report_title,
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
          body: Text(
            <String>[
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
            ].join('\n\n'),
            style: tokens.type.listSubtitle,
          ),
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

/// 重建进度框：线性进度 + 当前作品名 + 取消。复用现有对话框壳与进度组件。
class RebuildDownloadIndexProgressDialog extends StatelessWidget {
  const RebuildDownloadIndexProgressDialog({
    required this.progressNotifier,
    required this.onCancel,
    super.key,
  });

  final ValueNotifier<RebuildDownloadIndexProgress?> progressNotifier;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.rebuild_download_index_progress_title,
        leadingIcon: FushiIcons.refresh,
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
        body: ValueListenableBuilder<RebuildDownloadIndexProgress?>(
          valueListenable: progressNotifier,
          builder:
              (
                BuildContext context,
                RebuildDownloadIndexProgress? progress,
                Widget? _,
              ) {
                final String label = progress?.currentTitle ?? '';
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiLinearProgressIndicator(value: progress?.fraction),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      label,
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
