import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/src/backup_import/mihon_backup_import_report_dialog.dart';
import 'package:my_comic/src/backup_import/mihon_backup_import_service.dart';
import 'package:my_comic/src/backup_import/mihon_backup_parser.dart';
import 'package:my_comic/src/pages/implementations/tag_filter_sheet.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/my_comic_design_tokens.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/misc/show_app_dialog.dart';

/// The Backup directory's path: `<Content root>/autobackup` (ADR 0011,
/// ADR 0005 update). `.tachibk` import/export pickers start here.
String mihonBackupPickerInitialDirectory(AppPaths paths) =>
    paths.autobackupRoot.path;

/// Picks one `.tachibk` Backup file, starting in [initialDirectory].
///
/// [picker] is injectable so tests can assert the picker request (default
/// directory and allowed extension) without opening a native dialog.
Future<String?> pickMihonBackupFile({
  required String initialDirectory,
  FilePicker? picker,
}) async {
  final FilePickerResult? picked = await (picker ?? FilePicker.platform)
      .pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['tachibk'],
        allowMultiple: false,
        initialDirectory: initialDirectory,
        dialogTitle: t.backup_import_mihon_title,
      );
  return picked?.files.single.path;
}

/// Settings → Storage & downloads → Backup: pick a `.tachibk` file and import it.
///
/// The backup is read from local disk and written into the local Library only.
/// There is no network path in this flow. The picker opens in the Backup
/// directory (`<Content root>/autobackup`); `.mycomic.zip` App snapshots are a
/// different format and are deliberately not offered here.
Future<void> runMihonBackupImport(SettingsContext settings) async {
  final String? path = await pickMihonBackupFile(
    initialDirectory: mihonBackupPickerInitialDirectory(
      settings.appModel.appPaths,
    ),
  );
  if (path == null) return;
  final BuildContext context = settings.context;
  if (!context.mounted) return;

  final _ImportOutcome? outcome = await showAppDialog<_ImportOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext _) => _MihonBackupImportProgressDialog(
      file: File(path),
      service: MihonBackupImportService(
        database: settings.appModel.database,
        // Ticket 11: the import re-links only the imported Manga against the
        // current Content root's download/local roots. Both are resolved by the
        // time Settings can open the importer.
        downloadsRoot: settings.appModel.appPaths.downloadsRoot,
        localComicRoot: settings.appModel.appPaths.localComicRoot,
      ),
    ),
  );
  if (outcome == null || !context.mounted) return;

  // Ticket 05：导入会把 Mihon 分类写成 Tag、把分类归属写成 Tag 分配，而漫画页的
  // 标签页签 / 数量 / 作品归属读的是缓存型 FutureProvider（不是 Drift stream）。
  // 不在这里失效，用户必须进一次「管理标签」再退出才能看到新页签。复用标签管理
  // 页（漫画部分）的同一组失效语义；放在报告弹窗**之前**，弹窗背后的书架即已是
  // 最新。分类可以在没有任何 Library 条目时单独写 Tag 表，所以除了非空报告，
  // 分类写入也必须触发刷新（[MihonBackupImportReport.isEmpty] 不覆盖分类）。
  // 失败 / 取消没有报告——不刷新。ADR 0016 的「书架 = 无 Tag」归属规则由现有
  // 页签筛选继续保证，不在此处干预。
  final MihonBackupImportReport? report = outcome.report;
  if (report != null && (!report.isEmpty || report.hasCategoryTagWrites)) {
    invalidateMangaTagProviders(settings.ref);
  }

  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => outcome.report != null
        ? MihonBackupImportReportDialog(report: outcome.report!)
        : _MihonBackupImportErrorDialog(error: outcome.error!),
  );
}

class _ImportOutcome {
  const _ImportOutcome.success(this.report) : error = null;
  const _ImportOutcome.failure(this.error) : report = null;

  final MihonBackupImportReport? report;
  final Object? error;
}

class _MihonBackupImportProgressDialog extends StatefulWidget {
  const _MihonBackupImportProgressDialog({
    required this.file,
    required this.service,
  });

  final File file;
  final MihonBackupImportService service;

  @override
  State<_MihonBackupImportProgressDialog> createState() =>
      _MihonBackupImportProgressDialogState();
}

class _MihonBackupImportProgressDialogState
    extends State<_MihonBackupImportProgressDialog> {
  MihonBackupImportProgress? _progress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _run();
    });
  }

  Future<void> _run() async {
    try {
      final MihonBackupImportReport report = await widget.service.importFile(
        widget.file,
        onProgress: (MihonBackupImportProgress progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (mounted) {
        Navigator.of(context).pop(_ImportOutcome.success(report));
      }
    } on Object catch (error) {
      if (mounted) {
        Navigator.of(context).pop(_ImportOutcome.failure(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final MihonBackupImportProgress? progress = _progress;
    return MyComicDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: MyComicModalSheetFrame(
        title: t.backup_import_mihon_running,
        leadingIcon: Icons.restore_outlined,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const LinearProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              progress == null
                  ? t.backup_import_mihon_running
                  : t.backup_import_mihon_progress(
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

class _MihonBackupImportErrorDialog extends StatelessWidget {
  const _MihonBackupImportErrorDialog({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    return MyComicDialogFrame(
      maxWidth: 460,
      child: MyComicModalSheetFrame(
        title: t.backup_import_mihon_failed_title,
        leadingIcon: Icons.error_outline,
        scrollable: true,
        body: Text(_errorMessage(error), style: tokens.type.listSubtitle),
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
    if (error is MihonBackupFormatException) {
      return switch (error.error) {
        MihonBackupFormatError.emptyFile => t.backup_import_mihon_invalid_empty,
        MihonBackupFormatError.unsupportedFormat =>
          t.backup_import_mihon_invalid_json,
        MihonBackupFormatError.corrupt => t.backup_import_mihon_invalid_corrupt,
      };
    }
    if (error is FileSystemException) {
      return t.backup_import_mihon_file_unreadable(error: error.message);
    }
    return t.backup_import_mihon_invalid_unknown;
  }
}
