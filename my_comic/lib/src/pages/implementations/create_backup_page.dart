import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/backup_export/mihon_backup_exporter.dart';
import 'package:my_comic/src/settings/settings_kit.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/my_comic_design_tokens.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_buttons.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_feedback.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_toggles.dart';
import 'package:my_comic/src/utils/components/settings_shared.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/src/utils/misc/show_app_dialog.dart';

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
/// plumbing; ticket 08 adds 历史 and 所有已读作品, which depend on 书架中的作品;
/// ticket 09 adds 分类 (Categories), ticket 10 adds 进度记录 (Tracking),
/// ticket 11 adds 应用设置 / 包含敏感设置 and ticket 12 adds 插件商店 /
/// 图源设置 in the 设置 card. An empty group card is not rendered.
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
  bool _includeHistory = true;
  bool _includeAllRead = true;
  bool _includeTracking = true;
  bool _includeCategories = true;
  bool _includeAppSettings = true;
  bool _includeExtensionStores = true;
  bool _includeSourceSettings = true;
  bool _includeSensitiveSettings = false;

  /// 「包含敏感设置」only means something when a settings section is exported.
  bool get _sensitiveSettingsAvailable =>
      _includeAppSettings || _includeSourceSettings;

  /// Standalone exportable sections: 书架中的作品, 分类, 应用设置, 插件商店 and
  /// 图源设置. 章节 / 进度记录 / 历史 / 所有已读作品 depend on 书架中的作品.
  bool get _canCreate =>
      _includeLibrary ||
      _includeCategories ||
      _includeAppSettings ||
      _includeExtensionStores ||
      _includeSourceSettings;

  MihonBackupExportOptions get _options => MihonBackupExportOptions(
    includeLibrary: _includeLibrary,
    includeChapters: _includeLibrary && _includeChapters,
    includeHistory: _includeLibrary && _includeHistory,
    includeAllRead: _includeLibrary && _includeAllRead,
    includeTracking: _includeLibrary && _includeTracking,
    includeCategories: _includeCategories,
    includeAppSettings: _includeAppSettings,
    includeExtensionStores: _includeExtensionStores,
    includeSourceSettings: _includeSourceSettings,
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
    final _CreateBackupOutcome? outcome =
        await showAppDialog<_CreateBackupOutcome>(
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
      builder: (BuildContext _) =>
          _CreateBackupResultDialog(outcome: outcome, targetPath: path),
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
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final List<Widget> libraryRows = <Widget>[
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_library'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeLibrary,
        title: Text(t.backup_create_library_manga),
        onChanged: (bool? value) {
          setState(() => _includeLibrary = value ?? false);
        },
      ),
      MyComicCheckboxListTile(
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
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_tracking'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeTracking,
        enabled: _includeLibrary,
        title: Text(t.backup_create_tracking),
        onChanged: _includeLibrary
            ? (bool? value) {
                setState(() => _includeTracking = value ?? false);
              }
            : null,
      ),
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_history'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeHistory,
        enabled: _includeLibrary,
        title: Text(t.backup_create_history),
        onChanged: _includeLibrary
            ? (bool? value) {
                setState(() => _includeHistory = value ?? false);
              }
            : null,
      ),
      // 分类 = Tags exported as Mihon categories. It is deliberately not tied
      // to 书架中的作品 so a tags-only backup can be created. Spec order puts
      // it before 所有已读作品.
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_categories'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeCategories,
        title: Text(t.backup_create_categories),
        onChanged: (bool? value) {
          setState(() => _includeCategories = value ?? false);
        },
      ),
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_all_read'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeAllRead,
        enabled: _includeLibrary,
        title: Text(t.backup_create_all_read),
        onChanged: _includeLibrary
            ? (bool? value) {
                setState(() => _includeAllRead = value ?? false);
              }
            : null,
      ),
    ];
    // 应用设置 exports MyComic's own preference keys; 插件商店 exports every
    // Extension store; 图源设置 exports per-source preferences. 包含敏感设置 is
    // gated on either settings section being exported.
    final List<Widget> settingsRows = <Widget>[
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_app_settings'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeAppSettings,
        title: Text(t.backup_create_app_settings),
        onChanged: (bool? value) {
          setState(() => _includeAppSettings = value ?? false);
        },
      ),
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_extension_stores'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeExtensionStores,
        title: Text(t.backup_create_extension_stores),
        onChanged: (bool? value) {
          setState(() => _includeExtensionStores = value ?? false);
        },
      ),
      MyComicCheckboxListTile(
        key: const Key('create_backup_include_source_settings'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _includeSourceSettings,
        title: Text(t.backup_create_source_settings),
        onChanged: (bool? value) {
          setState(() => _includeSourceSettings = value ?? false);
        },
      ),
      MyComicCheckboxListTile(
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
      leadingIcon: MyComicIcons.upload,
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
                      child: MyComicFilledButton(
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
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final MihonBackupExportProgress? progress = _progress;
    return MyComicDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: MyComicModalSheetFrame(
        title: t.backup_exporting,
        leadingIcon: Icons.upload_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            MyComicLinearProgressIndicator(
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
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final Object? error = outcome.error;
    return MyComicDialogFrame(
      maxWidth: 460,
      child: MyComicModalSheetFrame(
        title: error == null
            ? t.backup_export_success
            : t.backup_create_failed_title,
        leadingIcon: error == null
            ? Icons.check_circle_outline
            : Icons.error_outline,
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
