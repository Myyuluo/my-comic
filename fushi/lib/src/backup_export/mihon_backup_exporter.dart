import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show kTrackingProviderBangumi, TrackingMediaType;

import 'package:fushi/src/backup_export/mihon_backup_writer.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart'
    show kMihonBangumiTrackerId;
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// Which Mihon backup sections the user asked for.
///
/// Ticket 07 ships Library + Chapters; ticket 10 adds Tracking. Later tickets
/// add History, categories, app settings, extension stores and source settings.
/// The page owns the dependency rules; the exporter only honours the resolved
/// options.
class MihonBackupExportOptions {
  const MihonBackupExportOptions({
    this.includeLibrary = true,
    this.includeChapters = true,
    this.includeTracking = true,
    this.includeAppSettings = true,
    this.includeSensitiveSettings = false,
  });

  /// 「书架中的作品」: export Library manga as `favorite=true`.
  final bool includeLibrary;

  /// 「章节」: export each manga's chapter list (read state, progress, dates).
  final bool includeChapters;

  /// 「进度记录」: export each manga's Bangumi tracking record. The UI label
  /// follows Mihon's reference layout, but the data is Tracking, not Reading
  /// progress. Depends on [includeLibrary] like the other per-manga sections.
  final bool includeTracking;

  /// 「应用设置」: export MyComic's own preference rows (`BackupPreferences`,
  /// proto field 104) without mapping key names to Mihon's.
  final bool includeAppSettings;

  /// 「包含敏感设置」: keep credentials in app / source settings. Device-local
  /// keys never leave the device even when this is true.
  final bool includeSensitiveSettings;

  /// Whether the resolved selection produces a non-empty backup. Later tickets
  /// add the standalone categories / settings sections here.
  bool get hasExportableContent => includeLibrary || includeAppSettings;
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
/// envelopes (see [MihonBackupWriter]).
class MihonBackupExporter {
  MihonBackupExporter({required this.database});

  final FushiDatabase database;

  /// Reads the database and builds the backup model. Exposed for tests and for
  /// later tickets that add more sections without changing the file plumbing.
  Future<MihonBackupData> buildBackup({
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    final List<_ExportableManga> exportable = await _exportableManga(options);
    final Map<String, Map<String, MangaChapterStateRow>> chapterStates =
        options.includeChapters ? await _loadChapterStates() : const {};
    final Map<String, MihonBackupTracking> trackingByBook =
        options.includeLibrary && options.includeTracking
        ? await _loadTrackingByBook()
        : const <String, MihonBackupTracking>{};
    final List<MihonBackupPreference> preferences = await _appPreferences(
      options,
    );

    final List<MihonBackupManga> mangas = <MihonBackupManga>[];
    final Map<int, String> sourceNames = <int, String>{};
    final Map<int, String> knownSourceNames = await _knownSourceNames();

    int processed = 0;
    for (final _ExportableManga candidate in exportable) {
      processed++;
      final OnlineMangaLibraryEntry entry = candidate.entry;
      final List<MihonBackupChapter> chapters = options.includeChapters
          ? _backupChapters(
              entry,
              chapterStates[candidate.row.uid] ?? const {},
            )
          : const <MihonBackupChapter>[];

      final MihonBackupTracking? tracking = trackingByBook[candidate.row.bookKey];
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
          status: _statusOf(entry),
          thumbnailUrl: _nonEmpty(entry.series.coverUrl),
          dateAdded: candidate.row.importedAt,
          favorite: true,
          chapters: chapters,
          categoryOrders: const <int>[],
          history: const <MihonBackupHistory>[],
          tracking: tracking == null
              ? const <MihonBackupTracking>[]
              : <MihonBackupTracking>[tracking],
        ),
      );

      final String? knownName = knownSourceNames[candidate.sourceId];
      if (knownName != null) sourceNames[candidate.sourceId] = knownName;

      if (processed % 25 == 0 || processed == exportable.length) {
        onProgress?.call(
          MihonBackupExportProgress(
            processed: processed,
            total: exportable.length,
            currentTitle: candidate.row.title,
          ),
        );
      }
    }

    return MihonBackupData(
      mangas: List<MihonBackupManga>.unmodifiable(mangas),
      categories: const <MihonBackupCategory>[],
      sourceNames: Map<int, String>.unmodifiable(sourceNames),
      preferences: List<MihonBackupPreference>.unmodifiable(preferences),
    );
  }

  /// Exports MyComic's own `preferences` rows under their original key names,
  /// wrapped in Mihon's six standard value envelopes. MyComic keys are not
  /// mapped to Mihon key names on purpose (spec: 不做 Mihon 键名映射).
  Future<List<MihonBackupPreference>> _appPreferences(
    MihonBackupExportOptions options,
  ) async {
    if (!options.includeAppSettings) {
      return const <MihonBackupPreference>[];
    }
    final Map<String, String> all = await database.getAllPrefs();
    // Stable order keeps backup bytes deterministic for a given database.
    final List<String> keys = all.keys.toList()..sort();
    final List<MihonBackupPreference> preferences = <MihonBackupPreference>[];
    for (final String key in keys) {
      if (!_shouldExportPreference(
        key,
        includeSensitive: options.includeSensitiveSettings,
      )) {
        continue;
      }
      final MihonBackupPreferenceValue? value = _preferenceValue(all[key]!);
      if (value == null) continue;
      preferences.add(MihonBackupPreference(key: key, value: value));
    }
    return preferences;
  }

  /// Device-local rows describe this device (paths, device ids, sync state) and
  /// never belong in a portable backup, sensitive checkbox or not. Credential
  /// rows use the existing [PrefRedactionPolicy] semantics and are only written
  /// when the user explicitly includes sensitive settings.
  static bool _shouldExportPreference(
    String key, {
    required bool includeSensitive,
  }) {
    // The prefs-version counter is a per-install cache-invalidation signal
    // written on every preference change, not a user setting.
    if (key == FushiDatabase.prefsVersionKey) return false;
    if (SyncRepository.deviceLocalPrefKeys.contains(key)) return false;
    if (includeSensitive) return true;
    return !PrefRedactionPolicy.isDeviceLocalOrCredential(key);
  }

  /// Maps a [PrefCodec]-encoded row onto one of Mihon's six standard preference
  /// value envelopes. Returns null for shapes no standard envelope can carry
  /// (explicit null, JSON objects, non-string lists): Mihon aborts the whole
  /// restore on an unknown serial name, so those rows are skipped instead.
  static MihonBackupPreferenceValue? _preferenceValue(String raw) {
    final Object? value = PrefCodec.decodeUntyped(raw);
    if (value is bool) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.boolean,
        value: value,
      );
    }
    if (value is int) {
      final bool fitsInt32 = value >= -0x80000000 && value <= 0x7fffffff;
      return MihonBackupPreferenceValue(
        type: fitsInt32
            ? MihonBackupPreferenceType.integer
            : MihonBackupPreferenceType.long,
        value: value,
      );
    }
    if (value is double) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.float,
        value: value,
      );
    }
    if (value is String) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.string,
        value: value,
      );
    }
    if (value is List &&
        value.every((Object? item) => item is String)) {
      return MihonBackupPreferenceValue(
        type: MihonBackupPreferenceType.stringSet,
        value: List<String>.from(value),
      );
    }
    return null;
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

  Future<List<_ExportableManga>> _exportableManga(
    MihonBackupExportOptions options,
  ) async {
    if (!options.includeLibrary) return const <_ExportableManga>[];
    final List<EpubBookRow> rows = await database.getAllEpubBooks();
    final List<_ExportableManga> exportable = <_ExportableManga>[];
    for (final EpubBookRow row in rows) {
      if (row.format != 'manga') continue;
      final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
      // Local-source rows and imported manga volumes have no Mihon Source ID /
      // manga URL, so they cannot be represented in a `.tachibk` at all.
      if (entry == null || entry.runtime != OnlineMangaRuntimeKind.mihon) {
        continue;
      }
      final int? sourceId = int.tryParse(entry.sourceId);
      if (sourceId == null || sourceId <= 0) continue;
      if (entry.series.key.trim().isEmpty) continue;
      exportable.add(
        _ExportableManga(row: row, entry: entry, sourceId: sourceId),
      );
    }
    return exportable;
  }

  Future<Map<String, Map<String, MangaChapterStateRow>>>
  _loadChapterStates() async {
    final List<MangaChapterStateRow> states = await database
        .select(database.mangaChapterStates)
        .get();
    final Map<String, Map<String, MangaChapterStateRow>> byBook =
        <String, Map<String, MangaChapterStateRow>>{};
    for (final MangaChapterStateRow state in states) {
      byBook
          .putIfAbsent(
            state.bookUid,
            () => <String, MangaChapterStateRow>{},
          )[state.chapterKey] = state;
    }
    return byBook;
  }

  /// Loads the Bangumi Tracking records stored for Library manga, keyed by the
  /// book key that also identifies the Manga row.
  ///
  /// MyComic has no tracker rows other than `provider = bangumi`, and Mihon
  /// trackers it cannot represent are never written here, so nothing is
  /// fabricated for unsupported providers.
  Future<Map<String, MihonBackupTracking>> _loadTrackingByBook() async {
    final List<MediaTrackingMappingRow> mappings =
        await (database.select(database.mediaTrackingMappings)..where(
              (t) =>
                  t.provider.equals(kTrackingProviderBangumi) &
                  t.mediaType.equals(TrackingMediaType.book.value),
            ))
            .get();
    if (mappings.isEmpty) return const <String, MihonBackupTracking>{};

    final Set<int> mappingIds = <int>{
      for (final MediaTrackingMappingRow mapping in mappings) mapping.id,
    };
    final Map<int, MediaTrackingOutboxRow> outboxByMapping =
        <int, MediaTrackingOutboxRow>{
          for (final MediaTrackingOutboxRow outbox
              in await (database.select(database.mediaTrackingOutbox)
                    ..where((t) => t.mappingId.isIn(mappingIds)))
                  .get())
            outbox.mappingId: outbox,
        };

    final Map<String, MihonBackupTracking> result =
        <String, MihonBackupTracking>{};
    for (final MediaTrackingMappingRow mapping in mappings) {
      result[mapping.mediaKey] = _backupTracking(
        mapping,
        outboxByMapping[mapping.id],
      );
    }
    return result;
  }

  /// Maps the locally stored mapping + sync progress to Mihon's BackupTracking.
  ///
  /// Only the fields MyComic actually keeps are exported: remote work id, last
  /// chapter read, completion (derived Bangumi status), and the stored dates.
  /// Score and total chapters have no local source, so they stay at proto
  /// defaults instead of being invented.
  static MihonBackupTracking _backupTracking(
    MediaTrackingMappingRow mapping,
    MediaTrackingOutboxRow? outbox,
  ) {
    final int progress = outbox?.progress ?? 0;
    final bool completed = outbox?.completed ?? false;
    // Bangumi collection types: 1 = wish, 2 = completed, 3 = reading.
    final int status = completed ? 2 : (progress > 0 ? 3 : 1);
    final String title = mapping.subjectName.trim().isNotEmpty
        ? mapping.subjectName
        : mapping.mediaTitle;
    return MihonBackupTracking(
      syncId: kMihonBangumiTrackerId,
      libraryId: null,
      mediaIdInt: null,
      trackingUrl: '',
      title: title,
      lastChapterRead: progress.toDouble(),
      totalChapters: 0,
      score: 0,
      status: status,
      startedReadingDate: mapping.createdAt > 0 ? mapping.createdAt : null,
      finishedReadingDate: completed && mapping.updatedAt > 0
          ? mapping.updatedAt
          : null,
      private: false,
      mediaId: mapping.subjectId,
    );
  }

  Future<Map<int, String>> _knownSourceNames() async {
    final List<MangaOnlineSourceRow> sources = await database
        .getMangaOnlineSources(mediaKind: 'manga');
    final Map<int, String> names = <int, String>{};
    for (final MangaOnlineSourceRow source in sources) {
      final int? id = int.tryParse(source.sourceId);
      if (id == null || source.name.trim().isEmpty) continue;
      names[id] = source.name;
    }
    return names;
  }

  List<MihonBackupChapter> _backupChapters(
    OnlineMangaLibraryEntry entry,
    Map<String, MangaChapterStateRow> states,
  ) {
    final List<MihonBackupChapter> chapters = <MihonBackupChapter>[];
    for (int index = 0; index < entry.chapters.length; index++) {
      final OnlineMangaChapter chapter = entry.chapters[index];
      final String key = chapter.key.trim();
      if (key.isEmpty) continue;
      final MangaChapterStateRow? state = states[key];
      final Map<String, Object?> raw = chapter.raw;
      final int rawLastPage = (raw['last_page_read'] as num?)?.toInt() ?? 0;
      chapters.add(
        MihonBackupChapter(
          url: key,
          name: chapter.name,
          scanlator: _nonEmpty(chapter.scanlator),
          read: state?.readAt != null || raw['read'] == true,
          bookmark: raw['bookmark'] == true,
          lastPageRead: state?.lastPage ?? rawLastPage,
          dateFetch: (raw['date_fetch'] as num?)?.toInt() ?? 0,
          dateUpload: chapter.uploadedAt ?? 0,
          chapterNumber: chapter.number ?? 0,
          sourceOrder: index,
        ),
      );
    }
    return chapters;
  }

  static int _statusOf(OnlineMangaLibraryEntry entry) =>
      (entry.series.raw['status'] as num?)?.toInt() ?? 0;

  static String? _nonEmpty(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : value;
  }
}

class _ExportableManga {
  const _ExportableManga({
    required this.row,
    required this.entry,
    required this.sourceId,
  });

  final EpubBookRow row;
  final OnlineMangaLibraryEntry entry;
  final int sourceId;
}
