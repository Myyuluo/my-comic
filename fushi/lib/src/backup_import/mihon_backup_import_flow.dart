import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
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

/// The completion report.
///
/// Ticket 01: a Fushi dialog instead of the old flush-left text list — hero
/// header with the processed total, body padding, two grouped cards
/// (「书架与阅读」/「设置与来源」), a warning notice for missing sources and no
/// extra navigation actions. Zero-only diagnostics are omitted.
class _MihonBackupImportReportDialog extends StatelessWidget {
  const _MihonBackupImportReportDialog({required this.report});

  final MihonBackupImportReport report;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> libraryLines = _libraryLines();
    final List<String> settingsLines = _settingsLines();
    return FushiDialogFrame(
      maxWidth: 520,
      maxHeightFactor: 0.86,
      // [FushiModalSheetFrame] already wraps its Flexible body in a
      // SingleChildScrollView; keep the outer frame non-scrolling so the report
      // has exactly one scroll viewport on short windows.
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.backup_import_mihon_done_title,
        subtitle: t.backup_import_mihon_done_subtitle(
          count: report.totalEntries,
        ),
        leadingIcon: Icons.check_circle_outline,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (report.missingSources.isNotEmpty) ...<Widget>[
              FushiInlineNotice(
                severity: FushiNoticeSeverity.warning,
                message: t.backup_import_mihon_missing_sources(
                  count: report.missingSources.length,
                  names: report.missingSources
                      .map((MihonBackupSourceIssue issue) => issue.sourceName)
                      .join(', '),
                ),
              ),
              SizedBox(height: tokens.spacing.card),
            ],
            _ReportGroupCard(
              title: t.backup_import_mihon_report_group_library,
              lines: libraryLines,
            ),
            if (settingsLines.isNotEmpty) ...<Widget>[
              SizedBox(height: tokens.spacing.card),
              _ReportGroupCard(
                title: t.backup_import_mihon_report_group_settings,
                lines: settingsLines,
              ),
            ],
          ],
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

  /// 「书架与阅读」: the four library counts always render; skip/failure reason
  /// rows (diagnostics) only render when non-zero.
  List<String> _libraryLines() {
    final int skippedNotInLibrary =
        report.skippedByReason[MihonBackupSkipReason.notInLibrary] ?? 0;
    final int failedMissingUrl =
        report.failedByReason[MihonBackupFailureReason.missingUrl] ?? 0;
    final int failedDatabase =
        report.failedByReason[MihonBackupFailureReason.databaseError] ?? 0;
    final List<String> lines = <String>[
      t.backup_import_mihon_summary_entries(
        imported: report.importedEntries,
        merged: report.mergedEntries,
        skipped: report.skippedEntries,
        failed: report.failedEntries,
      ),
      t.backup_import_mihon_summary_categories(
        created: report.categoriesCreated,
        matched: report.categoriesMatched,
      ),
      if (report.categoriesSkipped > 0)
        t.backup_import_mihon_categories_skipped(
          count: report.categoriesSkipped,
        ),
      if (skippedNotInLibrary > 0)
        t.backup_import_mihon_skip_not_in_library(count: skippedNotInLibrary),
      if (failedMissingUrl > 0)
        t.backup_import_mihon_fail_missing_url(count: failedMissingUrl),
      if (failedDatabase > 0)
        t.backup_import_mihon_fail_database(count: failedDatabase),
      t.backup_import_mihon_summary_progress(
        count: report.chapterStatesWritten,
      ),
      t.backup_import_mihon_summary_history(count: report.historyRowsWritten),
      if (report.isEmpty) t.backup_import_mihon_empty,
    ];

    if (report.nonLibraryHistoryImported + report.nonLibraryHistorySkipped >
        0) {
      lines.add(
        t.backup_import_mihon_summary_nonlibrary_history(
          imported: report.nonLibraryHistoryImported,
          skipped: report.nonLibraryHistorySkipped,
        ),
      );
      final int noHistory =
          report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
              .noHistory] ??
          0;
      final int missingUrl =
          report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
              .missingUrl] ??
          0;
      final int alreadyNewer =
          report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
              .alreadyNewer] ??
          0;
      if (noHistory > 0) {
        lines.add(
          t.backup_import_mihon_nonlibrary_history_missing(count: noHistory),
        );
      }
      if (missingUrl > 0) {
        lines.add(
          t.backup_import_mihon_nonlibrary_history_missing_url(
            count: missingUrl,
          ),
        );
      }
      if (alreadyNewer > 0) {
        lines.add(
          t.backup_import_mihon_nonlibrary_history_newer(count: alreadyNewer),
        );
      }
    }

    if (report.trackingMappingsImported +
            report.trackingMappingsMerged +
            report.trackingSkipped >
        0) {
      lines.add(
        t.backup_import_mihon_summary_tracking(
          imported: report.trackingMappingsImported,
          merged: report.trackingMappingsMerged,
          skipped: report.trackingSkipped,
        ),
      );
      if (report.trackingInvalidRemoteIds > 0) {
        lines.add(
          t.backup_import_mihon_tracking_invalid(
            count: report.trackingInvalidRemoteIds,
          ),
        );
      }
      if (report.unsupportedTrackers.isNotEmpty) {
        lines.add(
          t.backup_import_mihon_tracking_unsupported(
            names: report.unsupportedTrackers
                .map(
                  (MihonBackupTrackerIssue issue) =>
                      '${issue.name} (${issue.count})',
                )
                .join(', '),
          ),
        );
      }
    }
    return lines;
  }

  /// 「设置与来源」: only render a section (and its diagnostics) when the backup
  /// actually carried data for it.
  List<String> _settingsLines() {
    final List<String> lines = <String>[];

    final int appPreferencesTotal =
        report.appPreferencesImported + report.appPreferencesSkipped;
    if (appPreferencesTotal > 0) {
      lines.add(
        t.backup_import_mihon_summary_app_settings(
          imported: report.appPreferencesImported,
          skipped: report.appPreferencesSkipped,
        ),
      );
      final int notMyComic =
          report
              .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
              .notMyComicKey] ??
          0;
      final int deviceLocal =
          report
              .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
              .deviceLocal] ??
          0;
      final int alreadyPresent =
          report
              .appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
              .alreadyPresent] ??
          0;
      if (notMyComic > 0) {
        lines.add(
          t.backup_import_mihon_app_settings_not_mycomic(count: notMyComic),
        );
      }
      if (deviceLocal > 0) {
        lines.add(
          t.backup_import_mihon_app_settings_device_local(count: deviceLocal),
        );
      }
      if (alreadyPresent > 0) {
        lines.add(
          t.backup_import_mihon_app_settings_present(count: alreadyPresent),
        );
      }
    }

    final int sourcePreferencesTotal =
        report.sourcePreferencesImported +
        report.sourcePreferencesSkipped +
        report.sourcePreferencesFailed;
    if (sourcePreferencesTotal > 0) {
      lines.add(
        t.backup_import_mihon_summary_source_preferences(
          imported: report.sourcePreferencesImported,
          skipped: report.sourcePreferencesSkipped,
        ),
      );
      if (report.sourcePreferencesSkipped > 0) {
        lines.add(
          t.backup_import_mihon_source_preferences_skipped(
            count: report.sourcePreferencesSkipped,
          ),
        );
      }
      if (report.sourcePreferencesFailed > 0) {
        lines.add(
          t.backup_import_mihon_source_preferences_failed(
            count: report.sourcePreferencesFailed,
          ),
        );
      }
      if (report.sourcePreferencesForMissingSources > 0) {
        lines.add(
          t.backup_import_mihon_source_preferences_missing(
            count: report.sourcePreferencesForMissingSources,
          ),
        );
      }
    }

    final int extensionStoresTotal =
        report.extensionStoresImported +
        report.extensionStoresMerged +
        report.extensionStoresSkipped +
        report.extensionStoresFailed;
    if (extensionStoresTotal > 0) {
      lines.add(
        t.backup_import_mihon_summary_extension_stores(
          imported: report.extensionStoresImported,
          merged: report.extensionStoresMerged,
          skipped: report.extensionStoresSkipped,
        ),
      );
      if (report.extensionStoresSkipped > 0) {
        lines.add(
          t.backup_import_mihon_extension_stores_skipped(
            count: report.extensionStoresSkipped,
          ),
        );
      }
      if (report.extensionStoresFailed > 0) {
        lines.add(
          t.backup_import_mihon_extension_stores_failed(
            count: report.extensionStoresFailed,
          ),
        );
      }
    }
    return lines;
  }
}

/// One titled report card. All lines share the subtitle role; the title uses
/// the list-title role so the two groups read as sections inside the dialog.
class _ReportGroupCard extends StatelessWidget {
  const _ReportGroupCard({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              title,
              style: tokens.type.listTitle.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          for (int i = 0; i < lines.length; i++)
            Padding(
              padding: EdgeInsets.only(
                top: i == 0 ? 0 : tokens.spacing.gap / 2,
              ),
              child: Text(lines[i], style: tokens.type.listSubtitle),
            ),
        ],
      ),
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
