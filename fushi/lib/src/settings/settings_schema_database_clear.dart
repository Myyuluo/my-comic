import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi/src/utils/components/deletion_disclosure.dart'
    show DeleteConfirmCheckboxRow;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载」→「数据存储位置」的「清理数据库」动作行（ticket 13）。
///
/// 对齐 Mihon 的 Clear database：复用现有设置危险操作行、确认框、进度指示器与
/// toast（ADR 0008）。确认框列出有非书架作品的 Source 及数量，可多选；默认开启
/// 「保留有阅读记录的作品」，关闭时明确警告。动作只删数据库记录：所选 Source 的
/// 非书架作品及其章节/进度/已读/下载索引、被清理作品的 History；书架作品与
/// History、Download library 文件、Local source 文件、设置、源、扩展与 Tracking
/// 全部保留。
///
/// 删除在服务层一个事务内完成（[MangaDatabaseClearService]）；本文件只负责
/// 「读取 Source → 选择 → 进度 → 结果」的交互，不需要重启。
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

/// 测试缝：替换确认前的 Source 列表读取（页面测试不碰真实数据库）。
@visibleForTesting
Future<List<MangaDatabaseClearSource>> Function(SettingsContext context)?
debugMeasureMangaDatabaseClearSources;

/// 测试缝：替换真正的删除执行体（页面测试不碰真实数据库）。
@visibleForTesting
Future<MangaDatabaseClearCounts> Function(
  SettingsContext context,
  Set<String> sourceKeys,
  bool keepRead,
  void Function(MangaDatabaseClearProgress progress)? onProgress,
)?
debugRunMangaDatabaseClear;

Future<List<MangaDatabaseClearSource>> _measureMangaDatabaseClearSources(
  SettingsContext context,
) => MangaDatabaseClearService(
  database: context.appModel.database,
).measureSources();

Future<MangaDatabaseClearCounts> _runMangaDatabaseClear(
  SettingsContext context,
  Set<String> sourceKeys,
  bool keepRead,
  void Function(MangaDatabaseClearProgress progress)? onProgress,
) => MangaDatabaseClearService(
  database: context.appModel.database,
).run(sourceKeys: sourceKeys, keepRead: keepRead, onProgress: onProgress);

/// 用户在清理确认框里做出的选择。取消返回 null。
class MangaDatabaseClearSelection {
  const MangaDatabaseClearSelection({
    required this.sourceKeys,
    required this.keepRead,
  });

  final Set<String> sourceKeys;
  final bool keepRead;
}

String _sourceLabel(MangaDatabaseClearSource source) {
  return switch (source.kind) {
    MangaDatabaseClearSourceKind.localSource => t.local_source_title,
    MangaDatabaseClearSourceKind.imported => t.database_clear_source_imported,
    MangaDatabaseClearSourceKind.online => _onlineSourceLabel(source),
  };
}

String _onlineSourceLabel(MangaDatabaseClearSource source) {
  final String? name = source.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  if (source.runtime == OnlineMangaRuntimeKind.interconnect) {
    return t.database_clear_source_interconnect;
  }
  final String id = source.sourceId.trim();
  if (id.isNotEmpty) return t.database_clear_source_unknown(id: id);
  return t.database_clear_source_unknown(id: source.runtime?.wireValue ?? '—');
}

/// 入口：读取 Source → 选择 → 破坏性确认 → 进度框 → 完成 toast；不需要重启。
Future<void> clearMangaDatabase(SettingsContext settings) async {
  final List<MangaDatabaseClearSource> sources;
  try {
    sources =
        await (debugMeasureMangaDatabaseClearSources ??
            _measureMangaDatabaseClearSources)(settings);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log(
      'MangaDatabaseClear.measureSources',
      error,
      stack,
    );
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.database_clear_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
    }
    return;
  }
  if (!settings.context.mounted) return;
  if (sources.isEmpty) {
    FushiToast.show(msg: t.database_clear_nothing);
    return;
  }

  final MangaDatabaseClearSelection? selection =
      await showAppDialog<MangaDatabaseClearSelection>(
        context: settings.context,
        builder: (BuildContext context) =>
            _MangaDatabaseClearDialog(sources: sources),
      );
  if (selection == null || !settings.context.mounted) return;

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
      selection.sourceKeys,
      selection.keepRead,
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
    ),
    severity: ToastSeverity.success,
  );
}

/// 清理确认框：Source 多选、默认开启「保留有阅读记录的作品」、动态显示将删除的
/// 作品与 History 数量。复用现有 Fushi 对话框 / 行 / 开关 / 警告组件。
class _MangaDatabaseClearDialog extends StatefulWidget {
  const _MangaDatabaseClearDialog({required this.sources});

  final List<MangaDatabaseClearSource> sources;

  @override
  State<_MangaDatabaseClearDialog> createState() =>
      _MangaDatabaseClearDialogState();
}

class _MangaDatabaseClearDialogState extends State<_MangaDatabaseClearDialog> {
  final Set<String> _selectedKeys = <String>{};
  bool _keepRead = true;

  List<MangaDatabaseClearSource> get _orderedSources {
    final List<MangaDatabaseClearSource> ordered =
        List<MangaDatabaseClearSource>.of(widget.sources);
    ordered.sort(
      (MangaDatabaseClearSource a, MangaDatabaseClearSource b) => _sourceLabel(
        a,
      ).toLowerCase().compareTo(_sourceLabel(b).toLowerCase()),
    );
    return ordered;
  }

  Iterable<MangaDatabaseClearSource> get _selectedSources =>
      widget.sources.where(
        (MangaDatabaseClearSource source) => _selectedKeys.contains(source.key),
      );

  int get _worksToDelete => _selectedSources.fold<int>(
    0,
    (int total, MangaDatabaseClearSource source) =>
        total + source.worksToDelete(keepRead: _keepRead),
  );

  int get _historyToDelete => _selectedSources.fold<int>(
    0,
    (int total, MangaDatabaseClearSource source) =>
        total + source.historyToDelete(keepRead: _keepRead),
  );

  void _toggleSource(MangaDatabaseClearSource source, bool selected) {
    setState(() {
      if (selected) {
        _selectedKeys.add(source.key);
      } else {
        _selectedKeys.remove(source.key);
      }
    });
  }

  void _confirm() {
    if (_selectedKeys.isEmpty) return;
    Navigator.pop(
      context,
      MangaDatabaseClearSelection(
        sourceKeys: Set<String>.unmodifiable(_selectedKeys),
        keepRead: _keepRead,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 460,
      maxHeightFactor: 0.86,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.database_clear_confirm_title,
        leadingIcon: FushiIcons.delete,
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
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.database_clear_dialog_intro,
              style: tokens.type.listSubtitle,
            ),
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.database_clear_select_sources,
              style: tokens.type.sectionLabel,
            ),
            SizedBox(height: tokens.spacing.gap),
            for (final MangaDatabaseClearSource source in _orderedSources)
              DeleteConfirmCheckboxRow(
                key: ValueKey<String>('database_clear_source_${source.key}'),
                title: _sourceLabel(source),
                subtitle: t.database_clear_source_count(
                  count: source.nonLibraryWorks,
                ),
                value: _selectedKeys.contains(source.key),
                onChanged: (bool selected) => _toggleSource(source, selected),
              ),
            SizedBox(height: tokens.spacing.gap),
            AdaptiveSettingsSwitchRow(
              key: const ValueKey<String>('database_clear_keep_read'),
              title: t.database_clear_keep_read_title,
              subtitle: t.database_clear_keep_read_subtitle,
              value: _keepRead,
              horizontalPadding: 0,
              onChanged: (bool value) => setState(() => _keepRead = value),
            ),
            if (!_keepRead) ...<Widget>[
              SizedBox(height: tokens.spacing.gap),
              FushiInlineNotice(
                message: t.database_clear_keep_read_warning,
                severity: FushiNoticeSeverity.warning,
                showIcon: true,
              ),
            ],
            SizedBox(height: tokens.spacing.gap),
            Text(
              t.database_clear_confirm_body(
                works: _worksToDelete,
                history: _historyToDelete,
              ),
              style: tokens.type.listSubtitle,
            ),
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: _selectedKeys.isEmpty ? null : _confirm,
              child: Text(t.database_clear_button),
            ),
          ],
        ),
      ),
    );
  }
}

/// 清理数据库进度框：线性进度 + 当前阶段。视觉复用重建下载索引 / 清除缓存的
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
    MangaDatabaseClearStep.readingState =>
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
