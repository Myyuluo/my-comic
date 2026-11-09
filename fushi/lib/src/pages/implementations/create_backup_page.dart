import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/backup_export/mihon_backup_exporter.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// Signature of the native save dialog, injectable for widget tests.
typedef CreateBackupSavePathPicker =
    Future<String?> Function({
      required String initialDirectory,
      required String fileName,
    });

/// Opens the save dialog for a `.tachibk` backup, starting in the Backup
/// directory (`<Content root>/autobackup`) with the spec's default file name.
Future<String?> pickMihonBackupSavePath({
  required String initialDirectory,
  required String fileName,
  FilePicker? picker,
}) {
  return (picker ?? FilePicker.platform).saveFile(
    dialogTitle: t.backup_export_mihon_title,
    fileName: fileName,
    initialDirectory: initialDirectory,
    type: FileType.custom,
    allowedExtensions: const <String>['tachibk'],
  );
}

/// 「创建备份」页：Bookshelf / Settings group cards with a bottom 创建 button.
///
/// Ticket 07 delivers the Library options (书架中的作品 / 章节) and the file
/// plumbing. History, categories, tracking, app settings and source settings
/// are appended to these same groups by later tickets; an empty group card is
/// not rendered, so this slice shows only the 书架 card.
class CreateBackupPage extends ConsumerStatefulWidget {
  const CreateBackupPage({super.key, this.savePathPicker, this.exporter});

  /// Test injection for the native save dialog. null = [pickMihonBackupSavePath].
  final CreateBackupSavePathPicker? savePathPicker;

  /// Test injection for the export run. null = a real [MihonBackupExporter].
  final MihonBackupExporter? exporter;

  @override
  ConsumerState<CreateBackupPage> createState() => _CreateBackupPageState();
}

class _CreateBackupPageState extends ConsumerState<CreateBackupPage> {
  // Every open starts from the defaults; the choice is deliberately not
  // persisted (spec: 每次打开创建备份页都恢复默认勾选).
  bool _includeLibrary = true;
  bool _includeChapters = true;
  bool _includeAppSettings = true;
  bool _includeSensitiveSettings = false;

  /// 「包含敏感设置」only means something when a settings section is exported.
  /// Ticket 12 adds「图源设置」to this condition.
  bool get _sensitiveSettingsAvailable => _includeAppSettings;

  /// Standalone exportable sections: 书架中的作品 and 应用设置. Later tickets
  /// add 分类 / 插件商店 / 图源设置 here.
  bool get _canCreate => _includeLibrary || _includeAppSettings;

  MihonBackupExportOptions get _options => MihonBackupExportOptions(
    includeLibrary: _includeLibrary,
    includeChapters: _includeLibrary && _includeChapters,
    includeAppSettings: _includeAppSettings,
    includeSensitiveSettings: _includeSensitiveSettings,
  );

  Future<void> _create() async {
    if (!_canCreate) return;
    final AppModel appModel = ref.read(appProvider);
    final String fileName = mihonBackupDefaultFileName(DateTime.now());
    final CreateBackupSavePathPicker picker =
        widget.savePathPicker ?? _defaultSavePathPicker;
    final String? path = await picker(
      initialDirectory: appModel.appPaths.autobackupRoot.path,
      fileName: fileName,
    );
    if (path == null || !mounted) return;

    final MihonBackupExporter exporter =
        widget.exporter ?? MihonBackupExporter(database: appModel.database);
    final _CreateBackupOutcome? outcome = await showAppDialog<_CreateBackupOutcome>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext _) => _CreateBackupProgressDialog(
        exporter: exporter,
        options: _options,
        target: File(path),
      ),
    );
    if (outcome == null || !mounted) return;

    await showAppDialog<void>(
      context: context,
      builder: (BuildContext _) => _CreateBackupResultDialog(
        outcome: outcome,
        targetPath: path,
      ),
    );
  }

  static Future<String?> _defaultSavePathPicker({
    required String initialDirectory,
    required String fileName,
  }) => pickMihonBackupSavePath(
    initialDirectory: initialDirectory,
    fileName: fileName,
  );

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> libraryRows = <Widget>[
      FushiCheckboxListTile(
        key: const Key('create_backup_include_library'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeLibrary,
        title: Text(t.backup_create_library_manga),
        onChanged: (bool? value) {
          setState(() => _includeLibrary = value ?? false);
        },
      ),
      FushiCheckboxListTile(
        key: const Key('create_backup_include_chapters'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeChapters,
        enabled: _includeLibrary,
        title: Text(t.backup_create_chapters),
        onChanged: _includeLibrary
            ? (bool? value) {
                setState(() => _includeChapters = value ?? false);
              }
            : null,
      ),
    ];
    // 应用设置 exports MyComic's own preference keys; 包含敏感设置 is gated on
    // a settings section being exported. Ticket 12 appends 插件商店 / 图源设置.
    final List<Widget> settingsRows = <Widget>[
      FushiCheckboxListTile(
        key: const Key('create_backup_include_app_settings'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeAppSettings,
        title: Text(t.backup_create_app_settings),
        onChanged: (bool? value) {
          setState(() => _includeAppSettings = value ?? false);
        },
      ),
      FushiCheckboxListTile(
        key: const Key('create_backup_include_sensitive_settings'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeSensitiveSettings,
        enabled: _sensitiveSettingsAvailable,
        title: Text(t.backup_create_sensitive_settings),
        onChanged: _sensitiveSettingsAvailable
            ? (bool? value) {
                setState(() => _includeSensitiveSettings = value ?? false);
              }
            : null,
      ),
    ];

    return SettingsKitScaffold(
      title: t.backup_export_mihon_title,
      leadingIcon: FushiIcons.upload,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            return SafeArea(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: ListView(
                      controller: controller,
                      padding: EdgeInsets.fromLTRB(
                        tokens.spacing.page,
                        tokens.spacing.gap,
                        tokens.spacing.page,
                        tokens.spacing.gap,
                      ),
                      children: <Widget>[
                        AdaptiveSettingsSection(
                          title: t.backup_create_group_library,
                          children: libraryRows,
                        ),
                        SizedBox(height: tokens.spacing.gap),
                        AdaptiveSettingsSection(
                          title: t.backup_create_group_settings,
                          children: settingsRows,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      tokens.spacing.page,
                      0,
                      tokens.spacing.page,
                      tokens.spacing.page,
                    ),
                    child: SizedBox(
                      width: double.infinity,
                      child: FushiFilledButton(
                        key: const Key('create_backup_create'),
                        onPressed: _canCreate ? _create : null,
                        child: Text(t.backup_create_action),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
    );
  }
}

class _CreateBackupOutcome {
  const _CreateBackupOutcome.success(this.report) : error = null;
  const _CreateBackupOutcome.failure(this.error) : report = null;

  final MihonBackupExportReport? report;
  final Object? error;
}

class _CreateBackupProgressDialog extends StatefulWidget {
  const _CreateBackupProgressDialog({
    required this.exporter,
    required this.options,
    required this.target,
  });

  final MihonBackupExporter exporter;
  final MihonBackupExportOptions options;
  final File target;

  @override
  State<_CreateBackupProgressDialog> createState() =>
      _CreateBackupProgressDialogState();
}

class _CreateBackupProgressDialogState
    extends State<_CreateBackupProgressDialog> {
  MihonBackupExportProgress? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _run();
    });
  }

  Future<void> _run() async {
    try {
      final MihonBackupExportReport report = await widget.exporter.exportToFile(
        target: widget.target,
        options: widget.options,
        onProgress: (MihonBackupExportProgress progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (mounted) {
        Navigator.of(context).pop(_CreateBackupOutcome.success(report));
      }
    } on Object catch (error) {
      if (mounted) {
        Navigator.of(context).pop(_CreateBackupOutcome.failure(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MihonBackupExportProgress? progress = _progress;
    return FushiDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.backup_exporting,
        leadingIcon: Icons.upload_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LinearProgressIndicator(
              value: progress == null || progress.total == 0
                  ? null
                  : progress.processed / progress.total,
            ),
            const SizedBox(height: 16),
            Text(
              progress == null
                  ? t.backup_exporting
                  : t.backup_create_progress(
                      processed: progress.processed,
                      total: progress.total,
                    ),
              style: tokens.type.listSubtitle,
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateBackupResultDialog extends StatelessWidget {
  const _CreateBackupResultDialog({
    required this.outcome,
    required this.targetPath,
  });

  final _CreateBackupOutcome outcome;
  final String targetPath;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final Object? error = outcome.error;
    return FushiDialogFrame(
      maxWidth: 460,
      child: FushiModalSheetFrame(
        title: error == null
            ? t.backup_export_success
            : t.backup_create_failed_title,
        leadingIcon: error == null
            ? Icons.check_circle_outline
            : Icons.error_outline,
        scrollable: true,
        body: Text(
          error == null
              ? t.backup_create_saved_path(path: targetPath)
              : t.backup_export_failed(message: _errorMessage(error)),
          style: tokens.type.listSubtitle,
        ),
        footer: adaptiveDialogAction(
          context: context,
          isDefaultAction: true,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dialog_done),
        ),
      ),
    );
  }

  static String _errorMessage(Object error) {
    if (error is FileSystemException) {
      return error.message.isEmpty ? error.toString() : error.message;
    }
    return error.toString();
  }
}
