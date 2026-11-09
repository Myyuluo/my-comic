import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/trimmed_text.dart';

/// The completion report.
///
/// Ticket 01: a Fushi dialog instead of the old flush-left text list — hero
/// header with the processed total, body padding, two grouped cards
/// (「书架与阅读」/「设置与来源」), a warning notice for missing sources and no
/// extra navigation actions. Zero-only diagnostics are omitted.
class MihonBackupImportReportDialog extends StatelessWidget {
  const MihonBackupImportReportDialog({required this.report, super.key});

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
                  names: _missingSourceNames(),
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

  /// 缺失来源只列用户可读的名称：备份没带名称时用本地化的「来源未安装」，
  /// 绝不泄露数字 sourceId；重复名称（如多个未知来源）只列一次。
  String _missingSourceNames() {
    final Set<String> names = <String>{
      for (final MihonBackupSourceIssue issue in report.missingSources)
        trimmedOrNull(issue.sourceName) ?? t.manga_series_source_missing,
    };
    return names.join(', ');
  }

  /// 「书架与阅读」: the four library counts always render; skip/failure reason
  /// rows (diagnostics) only render when non-zero.
  List<String> _libraryLines() {
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
    ];
    _addPositiveLine(
      lines,
      report.categoriesSkipped,
      (int count) => t.backup_import_mihon_categories_skipped(count: count),
    );
    // `favorite=false` entries become persistent non-library rows; report them
    // as a count rather than a skip reason.
    _addPositiveLine(
      lines,
      report.nonLibraryEntriesImported + report.nonLibraryEntriesMerged,
      (int count) => t.backup_import_mihon_skip_not_in_library(count: count),
    );
    _addReasonLine(
      lines,
      report.failedByReason,
      MihonBackupFailureReason.missingUrl,
      (int count) => t.backup_import_mihon_fail_missing_url(count: count),
    );
    _addReasonLine(
      lines,
      report.failedByReason,
      MihonBackupFailureReason.databaseError,
      (int count) => t.backup_import_mihon_fail_database(count: count),
    );
    lines.add(
      t.backup_import_mihon_summary_progress(
        count: report.chapterStatesWritten,
      ),
    );
    lines.add(
      t.backup_import_mihon_summary_history(count: report.historyRowsWritten),
    );
    if (report.isEmpty) lines.add(t.backup_import_mihon_empty);

    if (report.nonLibraryHistoryImported + report.nonLibraryHistorySkipped >
        0) {
      lines.add(
        t.backup_import_mihon_summary_nonlibrary_history(
          imported: report.nonLibraryHistoryImported,
          skipped: report.nonLibraryHistorySkipped,
        ),
      );
      _addReasonLine(
        lines,
        report.nonLibraryHistorySkippedByReason,
        MihonBackupHistorySkipReason.noHistory,
        (int count) =>
            t.backup_import_mihon_nonlibrary_history_missing(count: count),
      );
      _addReasonLine(
        lines,
        report.nonLibraryHistorySkippedByReason,
        MihonBackupHistorySkipReason.missingUrl,
        (int count) =>
            t.backup_import_mihon_nonlibrary_history_missing_url(count: count),
      );
      _addReasonLine(
        lines,
        report.nonLibraryHistorySkippedByReason,
        MihonBackupHistorySkipReason.alreadyNewer,
        (int count) =>
            t.backup_import_mihon_nonlibrary_history_newer(count: count),
      );
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
      _addPositiveLine(
        lines,
        report.trackingInvalidRemoteIds,
        (int count) => t.backup_import_mihon_tracking_invalid(count: count),
      );
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
      _addReasonLine(
        lines,
        report.appPreferencesSkippedByReason,
        MihonBackupAppPreferenceSkipReason.notMyComicKey,
        (int count) =>
            t.backup_import_mihon_app_settings_not_mycomic(count: count),
      );
      _addReasonLine(
        lines,
        report.appPreferencesSkippedByReason,
        MihonBackupAppPreferenceSkipReason.deviceLocal,
        (int count) =>
            t.backup_import_mihon_app_settings_device_local(count: count),
      );
      _addReasonLine(
        lines,
        report.appPreferencesSkippedByReason,
        MihonBackupAppPreferenceSkipReason.alreadyPresent,
        (int count) => t.backup_import_mihon_app_settings_present(count: count),
      );
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
      _addPositiveLine(
        lines,
        report.sourcePreferencesSkipped,
        (int count) =>
            t.backup_import_mihon_source_preferences_skipped(count: count),
      );
      _addPositiveLine(
        lines,
        report.sourcePreferencesFailed,
        (int count) =>
            t.backup_import_mihon_source_preferences_failed(count: count),
      );
      _addPositiveLine(
        lines,
        report.sourcePreferencesForMissingSources,
        (int count) =>
            t.backup_import_mihon_source_preferences_missing(count: count),
      );
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
      _addPositiveLine(
        lines,
        report.extensionStoresSkipped,
        (int count) =>
            t.backup_import_mihon_extension_stores_skipped(count: count),
      );
      _addPositiveLine(
        lines,
        report.extensionStoresFailed,
        (int count) =>
            t.backup_import_mihon_extension_stores_failed(count: count),
      );
    }
    return lines;
  }
}

/// 只在计数大于 0 时追加一行诊断（零值行是噪音）。
void _addPositiveLine(
  List<String> lines,
  int count,
  String Function(int count) build,
) {
  if (count > 0) lines.add(build(count));
}

/// `map[reason] ?? 0` + `if > 0` 的重复形状：只追加非零原因行。
void _addReasonLine<T>(
  List<String> lines,
  Map<T, int> byReason,
  T reason,
  String Function(int count) build,
) {
  _addPositiveLine(lines, byReason[reason] ?? 0, build);
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
