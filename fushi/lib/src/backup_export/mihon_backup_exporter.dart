import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show readerBookMediaIdentifierFor;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show kTrackingProviderBangumi, TrackingMediaType;

import 'package:fushi/src/backup_export/mihon_backup_writer.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart'
    show kMihonBangumiTrackerId, kUnavailableMihonExtensionPackage;
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/utils/misc/pref_redaction_policy.dart';

part 'mihon_backup_exporter_categories.part.dart';
part 'mihon_backup_exporter_library.part.dart';
part 'mihon_backup_exporter_read_only.part.dart';
part 'mihon_backup_exporter_settings.part.dart';

/// Which Mihon backup sections the user asked for.
///
/// The page owns the dependency rules; the exporter only honours the resolved
/// options. Each section loader lives in its own focused part file (Library /
/// read-only works / categories / settings), so no single file has to know the
/// whole backup surface.
class MihonBackupExportOptions {
  const MihonBackupExportOptions({
    this.includeLibrary = true,
    this.includeChapters = true,
    this.includeCategories = true,
    this.includeHistory = true,
    this.includeAllRead = true,
    this.includeTracking = true,
    this.includeAppSettings = true,
    this.includeExtensionStores = true,
    this.includeSourceSettings = true,
    this.includeSensitiveSettings = false,
  });

  /// 「书架中的作品」: export Library manga as `favorite=true`.
  final bool includeLibrary;

  /// 「章节」: export each manga's chapter list (read state, progress, dates).
  final bool includeChapters;

  /// 「分类」: export every Tag as a Mihon category and reference the matching
  /// category orders from each exported manga. Independent of [includeLibrary]
  /// so categories can be exported on their own.
  final bool includeCategories;

  /// 「历史」: export the most recent History row of every Library manga.
  final bool includeHistory;

  /// 「所有已读作品」: export read online works that are not in the Library as
  /// `favorite=false` entries (Mihon keeps them for history continuity).
  final bool includeAllRead;

  /// 「进度记录」: export each manga's Bangumi tracking record. The UI label
  /// follows Mihon's reference layout, but the data is Tracking, not Reading
  /// progress. Depends on [includeLibrary] like the other per-manga sections.
  final bool includeTracking;

  /// 「应用设置」: export MyComic's own preference rows (`BackupPreferences`,
  /// proto field 104) without mapping key names to Mihon's.
  final bool includeAppSettings;

  /// 「插件商店」: export manga extension stores only — the app is manga-only
  /// and Mihon's backup format has no media-kind field, so Aniyomi (video)
  /// stores are deliberately never written
  /// (`BackupExtensionStores`, proto field 106).
  final bool includeExtensionStores;

  /// 「图源设置」: export per-source preferences grouped as
  /// `source_<sourceId>` (`BackupSourcePreferences`, proto field 105).
  final bool includeSourceSettings;

  /// 「包含敏感设置」: keep credentials in app / source settings. Device-local
  /// keys never leave the device even when this is true.
  final bool includeSensitiveSettings;
}

class MihonBackupExportProgress {
  const MihonBackupExportProgress({
    required this.processed,
    required this.total,
    required this.currentTitle,
  });

  final int processed;
  final int total;
  final String currentTitle;
}

class MihonBackupExportReport {
  const MihonBackupExportReport({
    required this.mangaCount,
    required this.chapterCount,
    required this.elapsed,
  });

  final int mangaCount;
  final int chapterCount;
  final Duration elapsed;
}

/// The default file name from the spec:
/// `my-comic_YYYY-MM-DD_HH-mm.tachibk` (local time).
String mihonBackupDefaultFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'my-comic_${now.year}-${two(now.month)}-${two(now.day)}'
      '_${two(now.hour)}-${two(now.minute)}.tachibk';
}

/// Builds a Mihon v0.21.3 `.tachibk` (gzip + protobuf) from the local Library.
///
/// The generated file round-trips through [MihonBackupParser] and
/// [MihonBackupImportService], and uses only Mihon's standard preference value
/// envelopes (see [MihonBackupWriter]). Section loaders are split into part
/// files alongside this one; this class only coordinates them.
class MihonBackupExporter {
  MihonBackupExporter({required this.database});

  final FushiDatabase database;

  /// Reads the database and builds the backup model. Exposed for tests and for
  /// direct API use without the page plumbing.
  Future<MihonBackupData> buildBackup({
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    // 历史 / 所有已读作品 follow 「书架中的作品」; the page already greys them
    // out, but honouring the dependency here keeps direct API use consistent.
    final bool includeHistory =
        options.includeLibrary && options.includeHistory;
    final bool includeAllRead =
        options.includeLibrary && options.includeAllRead;
    final _LibraryExportSection library = _LibraryExportSection(database);
    // 「书架中的作品」= Library membership 行。非书架作品不导出为 Library
    // 条目；它们若要保留阅读记录，由「所有已读作品」以 favorite=false 导出。
    final List<EpubBookRow> libraryRows = options.includeLibrary
        ? await database.getLibraryEpubBooks()
        : const <EpubBookRow>[];
    final List<_ExportableManga> exportable = library.exportableManga(
      libraryRows,
    );
    final Map<String, Map<String, MangaChapterStateRow>> chapterStates =
        options.includeChapters || includeHistory
        ? await library.loadChapterStates()
        : const {};
    final List<MediaOpenHistoryRow> historyRows =
        includeHistory || includeAllRead
        ? await library.loadHistoryRows()
        : const <MediaOpenHistoryRow>[];
    final Map<String, MediaOpenHistoryRow> historyByKey = includeHistory
        ? library.historyRowsByKey(historyRows)
        : const <String, MediaOpenHistoryRow>{};
    final Map<String, MihonBackupTracking> trackingByBook =
        options.includeLibrary && options.includeTracking
        ? await library.loadTrackingByBook()
        : const <String, MihonBackupTracking>{};
    // Categories (Tags) are independent of the Library section: they export
    // even when 书架中的作品 is unchecked.
    final _CategoryExport? categoryExport = options.includeCategories
        ? await _CategoryExportSection(database).load()
        : null;
    final List<MihonBackupPreference> preferences =
        await _AppSettingsExportSection(database).load(options);
    final List<MihonBackupExtensionStore> extensionStores =
        await _MangaExtensionStoreExportSection(database).load(options);
    final List<MihonBackupSourcePreferences> sourcePreferences =
        await _SourceSettingsExportSection(database).load(options);

    final List<MihonBackupManga> mangas = <MihonBackupManga>[];
    final Map<int, String> sourceNames = <int, String>{};
    final Map<int, String> knownSourceNames = await library.knownSourceNames();
    final List<MihonBackupManga> readOnly = includeAllRead
        ? const _ReadOnlyExportSection().mangas(
            historyRows: historyRows,
            libraryRows: libraryRows,
            knownSourceNames: knownSourceNames,
            sourceNames: sourceNames,
          )
        : const <MihonBackupManga>[];
    final int total = exportable.length + readOnly.length;

    int processed = 0;
    for (final _ExportableManga candidate in exportable) {
      processed++;
      final OnlineMangaLibraryEntry entry = candidate.entry;
      final Map<String, MangaChapterStateRow> states =
          chapterStates[candidate.row.uid] ?? const {};
      final List<MihonBackupChapter> chapters = options.includeChapters
          ? library.backupChapters(entry, states)
          : const <MihonBackupChapter>[];
      final MihonBackupHistory? history = includeHistory
          ? library.libraryHistory(
              row: candidate.row,
              entry: entry,
              states: states,
              historyByKey: historyByKey,
            )
          : null;

      final MihonBackupTracking? tracking =
          trackingByBook[candidate.row.bookKey];
      mangas.add(
        MihonBackupManga(
          source: candidate.sourceId,
          url: entry.series.key,
          title: candidate.row.title.trim().isEmpty
              ? entry.series.title
              : candidate.row.title,
          artist: _nonEmpty(entry.series.artist),
          author: _nonEmpty(entry.series.author),
          description: _nonEmpty(entry.series.description),
          genres: entry.series.genreLabels,
          status: _LibraryExportSection.statusOf(entry),
          thumbnailUrl: _nonEmpty(entry.series.coverUrl),
          dateAdded: candidate.row.importedAt,
          favorite: true,
          chapters: chapters,
          categoryOrders:
              categoryExport?.ordersFor(candidate.row.bookKey) ?? const <int>[],
          history: history == null
              ? const <MihonBackupHistory>[]
              : <MihonBackupHistory>[history],
          tracking: tracking == null
              ? const <MihonBackupTracking>[]
              : <MihonBackupTracking>[tracking],
        ),
      );

      final String? knownName = knownSourceNames[candidate.sourceId];
      if (knownName != null) sourceNames[candidate.sourceId] = knownName;

      if (processed % 25 == 0 || processed == total) {
        onProgress?.call(
          MihonBackupExportProgress(
            processed: processed,
            total: total,
            currentTitle: candidate.row.title,
          ),
        );
      }
    }
    for (final MihonBackupManga manga in readOnly) {
      processed++;
      if (processed % 25 == 0 || processed == total) {
        onProgress?.call(
          MihonBackupExportProgress(
            processed: processed,
            total: total,
            currentTitle: manga.title,
          ),
        );
      }
    }
    mangas.addAll(readOnly);

    return MihonBackupData(
      mangas: List<MihonBackupManga>.unmodifiable(mangas),
      categories: categoryExport?.categories ?? const <MihonBackupCategory>[],
      sourceNames: Map<int, String>.unmodifiable(sourceNames),
      preferences: List<MihonBackupPreference>.unmodifiable(preferences),
      extensionStores: List<MihonBackupExtensionStore>.unmodifiable(
        extensionStores,
      ),
      sourcePreferences: List<MihonBackupSourcePreferences>.unmodifiable(
        sourcePreferences,
      ),
    );
  }

  /// Writes the backup into [target] via a temp file in the same directory,
  /// then moves it into place. A failure deletes the temp file so a half-written
  /// `.tachibk` never remains next to the user's backups.
  Future<MihonBackupExportReport> exportToFile({
    required File target,
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final MihonBackupData data = await buildBackup(
      options: options,
      onProgress: onProgress,
    );
    final int chapterCount = data.mangas.fold<int>(
      0,
      (int sum, MihonBackupManga manga) => sum + manga.chapters.length,
    );
    final List<int> bytes = const MihonBackupWriter().encodeGzip(data);

    final String tempPath =
        '${target.path}.$pid.'
        '${DateTime.now().microsecondsSinceEpoch}.part';
    final File temp = File(tempPath);
    try {
      await temp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
    } on Object {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // Best effort: the original error is the one worth reporting.
        }
      }
      rethrow;
    }

    stopwatch.stop();
    return MihonBackupExportReport(
      mangaCount: data.mangas.length,
      chapterCount: chapterCount,
      elapsed: stopwatch.elapsed,
    );
  }
}

/// Trimmed value, or null when empty. Shared by the section loaders.
String? _nonEmpty(String? value) {
  final String? trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
}
