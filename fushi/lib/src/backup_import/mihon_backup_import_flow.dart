import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/pages/implementations/tag_filter_sheet.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

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
/// directory (`<Content root>/autobackup`); `.fushi.zip` App snapshots are a
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
      service: MihonBackupImportService(database: settings.appModel.database),
    ),
  );
  if (outcome == null || !context.mounted) return;

  // Ticket 05：导入会把 Mihon 分类写成 Tag、把分类归属写成 Tag 分配，而漫画页的
  // 标签页签 / 数量 / 作品归属读的是缓存型 FutureProvider（不是 Drift stream）。
  // 不在这里失效，用户必须进一次「管理标签」再退出才能看到新页签。复用标签管理
  // 页退出时的同一组失效语义；放在报告弹窗**之前**，弹窗背后的书架即已是最新。
  // 失败 / 取消没有报告，空备份报告 isEmpty（没有数据变化）——两者都不刷新。
  // ADR 0016 的「书架 = 无 Tag」归属规则由现有页签筛选继续保证，不在此处干预。
  final MihonBackupImportReport? report = outcome.report;
  if (report != null && !report.isEmpty) {
    settings.ref.invalidate(allTagsProvider);
    settings.ref.invalidate(bookTagMapProvider);
  }

  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => outcome.report != null
        ? _MihonBackupImportReportDialog(report: outcome.report!)
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final MihonBackupImportProgress? progress = _progress;
    return FushiDialogFrame(
      maxWidth: 420,
      scrollable: false,
      child: FushiModalSheetFrame(
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

class _MihonBackupImportReportDialog extends StatelessWidget {
  const _MihonBackupImportReportDialog({required this.report});

  final MihonBackupImportReport report;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<Widget> lines = <Widget>[
      Text(
        t.backup_import_mihon_summary_entries(
          imported: report.importedEntries,
          merged: report.mergedEntries,
          skipped: report.skippedEntries,
          failed: report.failedEntries,
        ),
        style: tokens.type.listSubtitle,
      ),
      const SizedBox(height: 8),
      Text(
        t.backup_import_mihon_summary_categories(
          created: report.categoriesCreated,
          matched: report.categoriesMatched,
        ),
        style: tokens.type.listSubtitle,
      ),
      if (report.categoriesSkipped > 0)
        _ReportDetailLine(
          t.backup_import_mihon_categories_skipped(
            count: report.categoriesSkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
      const SizedBox(height: 8),
      Text(
        t.backup_import_mihon_summary_progress(
          count: report.chapterStatesWritten,
        ),
        style: tokens.type.listSubtitle,
      ),
      const SizedBox(height: 8),
      Text(
        t.backup_import_mihon_summary_history(count: report.historyRowsWritten),
        style: tokens.type.listSubtitle,
      ),
      if (report.nonLibraryHistoryImported + report.nonLibraryHistorySkipped >
          0) ...[
        const SizedBox(height: 8),
        Text(
          t.backup_import_mihon_summary_nonlibrary_history(
            imported: report.nonLibraryHistoryImported,
            skipped: report.nonLibraryHistorySkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
        if (report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                .noHistory] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_nonlibrary_history_missing(
              count:
                  report
                      .nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                      .noHistory]!,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                .missingUrl] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_nonlibrary_history_missing_url(
              count:
                  report
                      .nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                      .missingUrl]!,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                .alreadyNewer] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_nonlibrary_history_newer(
              count:
                  report
                      .nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
                      .alreadyNewer]!,
            ),
            style: tokens.type.listSubtitle,
          ),
      ],
      if (report.appPreferencesImported + report.appPreferencesSkipped > 0) ...[
        const SizedBox(height: 8),
        Text(
          t.backup_import_mihon_summary_app_settings(
            imported: report.appPreferencesImported,
            skipped: report.appPreferencesSkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
        if (report
                .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                .notMyComicKey] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_app_settings_not_mycomic(
              count:
                  report
                      .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                      .notMyComicKey]!,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report
                .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                .deviceLocal] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_app_settings_device_local(
              count:
                  report
                      .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                      .deviceLocal]!,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report
                .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                .alreadyPresent] !=
            null)
          _ReportDetailLine(
            t.backup_import_mihon_app_settings_present(
              count:
                  report
                      .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
                      .alreadyPresent]!,
            ),
            style: tokens.type.listSubtitle,
          ),
      ],
      if (report.trackingMappingsImported +
              report.trackingMappingsMerged +
              report.trackingSkipped >
          0) ...[
        const SizedBox(height: 8),
        Text(
          t.backup_import_mihon_summary_tracking(
            imported: report.trackingMappingsImported,
            merged: report.trackingMappingsMerged,
            skipped: report.trackingSkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
        if (report.trackingInvalidRemoteIds > 0)
          _ReportDetailLine(
            t.backup_import_mihon_tracking_invalid(
              count: report.trackingInvalidRemoteIds,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.unsupportedTrackers.isNotEmpty)
          _ReportDetailLine(
            t.backup_import_mihon_tracking_unsupported(
              names: report.unsupportedTrackers
                  .map(
                    (MihonBackupTrackerIssue issue) =>
                        '${issue.name} (${issue.count})',
                  )
                  .join(', '),
            ),
            style: tokens.type.listSubtitle,
          ),
      ],
      if (report.extensionStoresImported +
              report.extensionStoresMerged +
              report.extensionStoresSkipped >
          0) ...[
        const SizedBox(height: 8),
        Text(
          t.backup_import_mihon_summary_extension_stores(
            imported: report.extensionStoresImported,
            merged: report.extensionStoresMerged,
            skipped: report.extensionStoresSkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
        if (report.extensionStoresSkipped > 0)
          _ReportDetailLine(
            t.backup_import_mihon_extension_stores_skipped(
              count: report.extensionStoresSkipped,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.extensionStoresFailed > 0)
          _ReportDetailLine(
            t.backup_import_mihon_extension_stores_failed(
              count: report.extensionStoresFailed,
            ),
            style: tokens.type.listSubtitle,
          ),
      ],
      if (report.sourcePreferencesImported + report.sourcePreferencesSkipped >
          0) ...[
        const SizedBox(height: 8),
        Text(
          t.backup_import_mihon_summary_source_preferences(
            imported: report.sourcePreferencesImported,
            skipped: report.sourcePreferencesSkipped,
          ),
          style: tokens.type.listSubtitle,
        ),
        if (report.sourcePreferencesSkipped > 0)
          _ReportDetailLine(
            t.backup_import_mihon_source_preferences_skipped(
              count: report.sourcePreferencesSkipped,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.sourcePreferencesFailed > 0)
          _ReportDetailLine(
            t.backup_import_mihon_source_preferences_failed(
              count: report.sourcePreferencesFailed,
            ),
            style: tokens.type.listSubtitle,
          ),
        if (report.sourcePreferencesForMissingSources > 0)
          _ReportDetailLine(
            t.backup_import_mihon_source_preferences_missing(
              count: report.sourcePreferencesForMissingSources,
            ),
            style: tokens.type.listSubtitle,
          ),
      ],
      if (report.skippedByReason[MihonBackupSkipReason.notInLibrary] != null)
        _ReportDetailLine(
          t.backup_import_mihon_skip_not_in_library(
            count: report.skippedByReason[MihonBackupSkipReason.notInLibrary]!,
          ),
          style: tokens.type.listSubtitle,
        ),
      if (report.failedByReason[MihonBackupFailureReason.missingUrl] != null)
        _ReportDetailLine(
          t.backup_import_mihon_fail_missing_url(
            count: report.failedByReason[MihonBackupFailureReason.missingUrl]!,
          ),
          style: tokens.type.listSubtitle,
        ),
      if (report.failedByReason[MihonBackupFailureReason.databaseError] != null)
        _ReportDetailLine(
          t.backup_import_mihon_fail_database(
            count:
                report.failedByReason[MihonBackupFailureReason.databaseError]!,
          ),
          style: tokens.type.listSubtitle,
        ),
      if (report.missingSources.isNotEmpty)
        _ReportDetailLine(
          t.backup_import_mihon_missing_sources(
            count: report.missingSources.length,
            names: report.missingSources
                .map((MihonBackupSourceIssue issue) => issue.sourceName)
                .join(', '),
          ),
          style: tokens.type.listSubtitle,
        ),
      if (report.isEmpty) ...[
        const SizedBox(height: 8),
        Text(t.backup_import_mihon_empty, style: tokens.type.listSubtitle),
      ],
    ];
    return FushiDialogFrame(
      maxWidth: 520,
      child: FushiModalSheetFrame(
        title: t.backup_import_mihon_done_title,
        leadingIcon: Icons.check_circle_outline,
        scrollable: true,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
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
}

/// One extra report line (skip / failure reason). All reason rows share the
/// same 8px top gap and subtitle style, so they are built from one widget
/// instead of repeating the SizedBox + Text pair in every branch.
class _ReportDetailLine extends StatelessWidget {
  const _ReportDetailLine(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text, style: style),
    );
  }
}

class _MihonBackupImportErrorDialog extends StatelessWidget {
  const _MihonBackupImportErrorDialog({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 460,
      child: FushiModalSheetFrame(
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
