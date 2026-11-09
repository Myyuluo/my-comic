import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载」→「数据存储位置」的「清除数据库」动作行（ticket 13）。
///
/// 复用现有设置危险操作行、确认框、进度指示器与 toast（ADR 0008）。动作只删
/// 数据库记录：全部 History、不在 Library 中的作品记录（记录级级联）与孤儿阅读
/// 记录；Library 作品及其 Reading progress / 已读 / 完成标记、Download library、
/// Local source 文件、设置、源、扩展、搜索历史与 Tracking 全部保留。
///
/// 删除在服务层一个事务内完成（[MangaDatabaseClearService]）；本文件只负责
/// 「测量数量 → 确认 → 进度 → 结果」的交互，不需要重启。
SettingsActionItem buildClearDatabaseSettingsItem() {
  return SettingsActionItem(
    id: 'storage.clear_database',
    title: t.database_clear_title,
    subtitle: t.database_clear_subtitle,
    icon: FushiIcons.delete,
    destructive: true,
    cli: const SettingsCliAction.unsupported(
      'Clearing the database is destructive and confirmed in the app window: '
      'Settings → Storage & downloads → Data storage locations → '
      'Clear database.',
    ),
    onTap: clearMangaDatabase,
  );
}

/// 测试缝：替换确认前的数量测量（页面测试不碰真实数据库）。
@visibleForTesting
Future<MangaDatabaseClearCounts> Function(SettingsContext context)?
debugMeasureMangaDatabaseClearCounts;

/// 测试缝：替换真正的删除执行体（页面测试不碰真实数据库）。
@visibleForTesting
Future<MangaDatabaseClearCounts> Function(
  SettingsContext context,
  void Function(MangaDatabaseClearProgress progress)? onProgress,
)?
debugRunMangaDatabaseClear;

Future<MangaDatabaseClearCounts> _measureMangaDatabaseClear(
  SettingsContext context,
) => MangaDatabaseClearService(database: context.appModel.database).measure();

Future<MangaDatabaseClearCounts> _runMangaDatabaseClear(
  SettingsContext context,
  void Function(MangaDatabaseClearProgress progress)? onProgress,
) => MangaDatabaseClearService(
  database: context.appModel.database,
).run(onProgress: onProgress);

/// 入口：测量数量 → 破坏性确认 → 进度框 → 完成 toast；不需要重启。
Future<void> clearMangaDatabase(SettingsContext settings) async {
  final MangaDatabaseClearCounts counts;
  try {
    counts =
        await (debugMeasureMangaDatabaseClearCounts ??
            _measureMangaDatabaseClear)(settings);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaDatabaseClear.measure', error, stack);
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.database_clear_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
    }
    return;
  }
  if (!settings.context.mounted) return;

  final bool confirmed = await showSettingsConfirmationDialog(
    settings,
    title: t.database_clear_confirm_title,
    body: t.database_clear_confirm_body(
      works: counts.works,
      history: counts.historyEntries,
      records: counts.readingRecords,
    ),
    confirmLabel: t.database_clear_button,
    destructive: true,
  );
  if (!confirmed || !settings.context.mounted) return;

  final ValueNotifier<MangaDatabaseClearProgress?> progressNotifier =
      ValueNotifier<MangaDatabaseClearProgress?>(null);
  bool progressDialogOpen = true;
  unawaited(
    showAppDialog<void>(
      context: settings.context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: MangaDatabaseClearProgressDialog(
          progressNotifier: progressNotifier,
        ),
      ),
    ).whenComplete(() => progressDialogOpen = false),
  );

  final MangaDatabaseClearCounts report;
  try {
    report = await (debugRunMangaDatabaseClear ?? _runMangaDatabaseClear)(
      settings,
      (MangaDatabaseClearProgress progress) =>
          progressNotifier.value = progress,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaDatabaseClear.run', error, stack);
    if (progressDialogOpen && settings.context.mounted) {
      Navigator.of(settings.context).pop();
    }
    progressNotifier.dispose();
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.database_clear_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
    }
    return;
  }

  if (progressDialogOpen && settings.context.mounted) {
    Navigator.of(settings.context).pop();
  }
  progressNotifier.dispose();
  if (!settings.context.mounted) return;
  FushiToast.show(
    msg: t.database_clear_done(
      works: report.works,
      history: report.historyEntries,
      records: report.readingRecords,
    ),
    severity: ToastSeverity.success,
  );
}

/// 清除数据库进度框：线性进度 + 当前阶段。视觉复用重建下载索引 / 清除缓存的
/// 进度框，不引入新的视觉语言。
class MangaDatabaseClearProgressDialog extends StatelessWidget {
  const MangaDatabaseClearProgressDialog({
    required this.progressNotifier,
    super.key,
  });

  final ValueNotifier<MangaDatabaseClearProgress?> progressNotifier;

  static String _stepLabel(MangaDatabaseClearStep step) => switch (step) {
    MangaDatabaseClearStep.works => t.database_clear_step_works,
    MangaDatabaseClearStep.history => t.database_clear_step_history,
    MangaDatabaseClearStep.readingRecords =>
      t.database_clear_step_reading_records,
  };

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.database_clear_progress_title,
        leadingIcon: FushiIcons.delete,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<MangaDatabaseClearProgress?>(
          valueListenable: progressNotifier,
          builder:
              (
                BuildContext context,
                MangaDatabaseClearProgress? progress,
                Widget? _,
              ) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiLinearProgressIndicator(value: progress?.fraction),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      progress == null ? '' : _stepLabel(progress.step),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listSubtitle,
                    ),
                  ],
                );
              },
        ),
      ),
    );
  }
}
