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
    show kMihonBangumiTrackerId;
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/manga_fushi_source.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';

/// Which Mihon backup sections the user asked for.
///
/// Ticket 07 ships Library + Chapters; ticket 08 adds History and the
/// non-library read works; ticket 09 adds Categories; ticket 10 adds Tracking;
/// ticket 11 adds App settings. Later tickets add extension stores and source
/// settings. The page owns the dependency rules; the exporter only honours the
/// resolved options.
class MihonBackupExportOptions {
  const MihonBackupExportOptions({
    this.includeLibrary = true,
    this.includeChapters = true,
    this.includeCategories = true,
    this.includeHistory = true,
    this.includeAllRead = true,
    this.includeTracking = true,
    this.includeAppSettings = true,
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

  /// 「包含敏感设置」: keep credentials in app / source settings. Device-local
  /// keys never leave the device even when this is true.
  final bool includeSensitiveSettings;

  /// Whether the resolved selection produces a non-empty backup. Later tickets
  /// add the remaining standalone sections here.
  bool get hasExportableContent =>
      includeLibrary || includeCategories || includeAppSettings;
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
    // 历史 / 所有已读作品 follow 「书架中的作品」; the page already greys them
    // out, but honouring the dependency here keeps direct API use consistent.
    final bool includeHistory = options.includeLibrary && options.includeHistory;
    final bool includeAllRead = options.includeLibrary && options.includeAllRead;
    final List<EpubBookRow> libraryRows = options.includeLibrary
        ? await database.getAllEpubBooks()
        : const <EpubBookRow>[];
    final List<_ExportableManga> exportable = _exportableManga(libraryRows);
    final Map<String, Map<String, MangaChapterStateRow>> chapterStates =
        options.includeChapters || includeHistory
        ? await _loadChapterStates()
        : const {};
    final List<MediaOpenHistoryRow> historyRows = includeHistory || includeAllRead
        ? await _loadHistoryRows()
        : const <MediaOpenHistoryRow>[];
    final Map<String, MediaOpenHistoryRow> historyByKey = includeHistory
        ? _historyRowsByKey(historyRows)
        : const <String, MediaOpenHistoryRow>{};
    final Map<String, MihonBackupTracking> trackingByBook =
        options.includeLibrary && options.includeTracking
        ? await _loadTrackingByBook()
        : const <String, MihonBackupTracking>{};
    // Categories (Tags) are independent of the Library section: they export
    // even when 书架中的作品 is unchecked.
    final _CategoryExport? categoryExport = options.includeCategories
        ? await _loadCategories()
        : null;
    final List<MihonBackupPreference> preferences = await _appPreferences(
      options,
    );

    final List<MihonBackupManga> mangas = <MihonBackupManga>[];
    final Map<int, String> sourceNames = <int, String>{};
    final Map<int, String> knownSourceNames = await _knownSourceNames();
    final List<MihonBackupManga> readOnly = includeAllRead
        ? _readOnlyMangas(
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
          ? _backupChapters(entry, states)
          : const <MihonBackupChapter>[];
      final MihonBackupHistory? history = includeHistory
          ? _libraryHistory(
              row: candidate.row,
              entry: entry,
              states: states,
              historyByKey: historyByKey,
            )
          : null;

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
    if (value is List && value.every((Object? item) => item is String)) {
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

  List<_ExportableManga> _exportableManga(List<EpubBookRow> rows) {
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
      byBook.putIfAbsent(
        state.bookUid,
        () => <String, MangaChapterStateRow>{},
      )[state.chapterKey] = state;
    }
    return byBook;
  }

  Future<List<MediaOpenHistoryRow>> _loadHistoryRows() =>
      database.select(database.mediaOpenHistory).get();

  /// Every History row keyed by its identity (`source\0id`), keeping the newest
  /// row when both the current online identity and the legacy import identity
  /// describe the same Manga.
  Map<String, MediaOpenHistoryRow> _historyRowsByKey(
    List<MediaOpenHistoryRow> rows,
  ) {
    final Map<String, MediaOpenHistoryRow> byKey =
        <String, MediaOpenHistoryRow>{};
    for (final MediaOpenHistoryRow row in rows) {
      final String key = '${row.mediaSource}\u0000${row.mediaId}';
      final MediaOpenHistoryRow? existing = byKey[key];
      if (existing == null || row.openedAt >= existing.openedAt) {
        byKey[key] = row;
      }
    }
    return byKey;
  }

  /// Read online works that are not in the Library, exported as `favorite=false`
  /// so Mihon keeps their reading history without adding them to the shelf.
  ///
  /// Library works are excluded by history identity and by (Source, URL): the
  /// Library row and its History row can carry different identities after a
  /// backup import or an extension-package change. Snapshot data without a
  /// chapter URL exports metadata only — no chapters or history links are
  /// invented.
  List<MihonBackupManga> _readOnlyMangas({
    required List<MediaOpenHistoryRow> historyRows,
    required List<EpubBookRow> libraryRows,
    required Map<int, String> knownSourceNames,
    required Map<int, String> sourceNames,
  }) {
    final _LibraryHistoryKeys library = _libraryHistoryKeys(libraryRows);
    final Set<String> seen = <String>{};
    final List<MihonBackupManga> mangas = <MihonBackupManga>[];
    for (final MediaOpenHistoryRow row in historyRows) {
      if (!row.mediaSource.startsWith(kMangaHistoryOnlineSourcePrefix)) {
        continue;
      }
      final String historyKey = '${row.mediaSource}\u0000${row.mediaId}';
      if (library.historyKeys.contains(historyKey)) continue;

      final Map<String, Object?>? rawSnapshot = _snapshotJson(
        row.snapshotJson,
      );
      final MangaHistorySnapshot? snapshot = MangaHistorySnapshot.tryParse(
        row.snapshotJson,
      );
      final MangaHistoryOnlineRef? online = snapshot?.online;
      final _HistorySource? source = _historySourceOf(row.mediaSource, online);
      if (source == null || source.runtime != OnlineMangaRuntimeKind.mihon) {
        continue;
      }
      final int? sourceId = int.tryParse(source.sourceId);
      if (sourceId == null || sourceId <= 0) continue;

      final String url = online?.seriesKey.trim().isNotEmpty == true
          ? online!.seriesKey.trim()
          : row.mediaId.trim();
      if (url.isEmpty) continue;
      if (library.seriesKeys.contains('$sourceId\u0000$url')) continue;
      if (!seen.add('$sourceId\u0000$url')) continue;

      final Map<String, Object?> raw = online?.raw ?? const <String, Object?>{};
      final String title =
          _firstNonEmpty(<String?>[
            snapshot?.title,
            raw['title']?.toString(),
            rawSnapshot?['title']?.toString(),
            url,
          ])!;
      final String? author = _firstNonEmpty(<String?>[
        snapshot?.author,
        raw['author']?.toString(),
        rawSnapshot?['author']?.toString(),
      ]);
      final String? artist = _firstNonEmpty(<String?>[
        raw['artist']?.toString(),
      ]);
      final String? description = _firstNonEmpty(<String?>[
        raw['description']?.toString(),
        rawSnapshot?['description']?.toString(),
      ]);
      final String? genre = _firstNonEmpty(<String?>[
        raw['genre']?.toString(),
        rawSnapshot?['genre']?.toString(),
      ]);
      final int status = (raw['status'] as num?)?.toInt() ?? 0;
      final String? thumbnailUrl =
          _remoteUrl(online?.coverUrl) ??
          _remoteUrl(snapshot?.imageUrl) ??
          _remoteUrl(raw['thumbnail_url']?.toString()) ??
          _remoteUrl(raw['coverUrl']?.toString());
      final String? chapterUrl = _snapshotChapterUrl(rawSnapshot);

      mangas.add(
        MihonBackupManga(
          source: sourceId,
          url: url,
          title: title,
          artist: artist,
          author: author,
          description: description,
          genres: _genresOf(genre),
          status: status,
          thumbnailUrl: thumbnailUrl,
          dateAdded: 0,
          favorite: false,
          chapters: const <MihonBackupChapter>[],
          categoryOrders: const <int>[],
          history: chapterUrl == null
              ? const <MihonBackupHistory>[]
              : <MihonBackupHistory>[
                  MihonBackupHistory(
                    url: chapterUrl,
                    lastRead: row.openedAt,
                    readDuration: _snapshotReadDuration(rawSnapshot),
                  ),
                ],
          tracking: const <MihonBackupTracking>[],
        ),
      );

      final String? knownName = knownSourceNames[sourceId];
      if (knownName != null) sourceNames[sourceId] = knownName;
    }
    return mangas;
  }

  _LibraryHistoryKeys _libraryHistoryKeys(List<EpubBookRow> rows) {
    final Set<String> historyKeys = <String>{};
    final Set<String> seriesKeys = <String>{};
    for (final EpubBookRow row in rows) {
      final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
      if (entry == null) continue;
      historyKeys.add(mangaHistoryIdentityForOnline(entry).key);
      historyKeys.add(
        '${MangaFushiSource.kUniqueKey}\u0000'
        '${readerBookMediaIdentifierFor(row.bookKey)}',
      );
      final int? sourceId = int.tryParse(entry.sourceId);
      if (sourceId != null && sourceId > 0) {
        seriesKeys.add('$sourceId\u0000${entry.series.key}');
      }
    }
    return _LibraryHistoryKeys(historyKeys, seriesKeys);
  }

  static _HistorySource? _historySourceOf(
    String mediaSource,
    MangaHistoryOnlineRef? online,
  ) {
    OnlineMangaRuntimeKind? runtime = online?.runtime;
    String sourceId = online?.sourceId ?? '';
    if (mediaSource.startsWith(kMangaHistoryOnlineSourcePrefix)) {
      try {
        final Object? decoded = jsonDecode(
          mediaSource.substring(kMangaHistoryOnlineSourcePrefix.length),
        );
        if (decoded is List<Object?> && decoded.length >= 3) {
          runtime ??= OnlineMangaRuntimeKind.fromWire(decoded[0]?.toString());
          if (sourceId.isEmpty) sourceId = decoded[2]?.toString() ?? '';
        }
      } on Object {
        return null;
      }
    }
    if (runtime == null) return null;
    return _HistorySource(runtime: runtime, sourceId: sourceId);
  }

  static List<String> _genresOf(String? genre) {
    if (genre == null || genre.trim().isEmpty) return const <String>[];
    return genre
        .split(RegExp(r'[,，、;；]'))
        .map((String item) => item.trim())
        .where((String item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static String? _remoteUrl(String? value) {
    final String? trimmed = value?.trim();
    if (trimmed == null) return null;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return null;
  }

  static String? _firstNonEmpty(List<String?> values) {
    for (final String? value in values) {
      final String? trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  /// The most recent History row of a Library Manga. Reader sessions write the
  /// current online identity; backups imported by earlier versions wrote the
  /// legacy book-key identity, and both must keep round-tripping.
  MediaOpenHistoryRow? _historyRowFor(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
    Map<String, MediaOpenHistoryRow> historyByKey,
  ) {
    final MangaHistoryIdentity identity = mangaHistoryIdentityForOnline(entry);
    final MediaOpenHistoryRow? current = historyByKey[identity.key];
    if (current != null) return current;
    final String legacyKey =
        '${MangaFushiSource.kUniqueKey}\u0000'
        '${readerBookMediaIdentifierFor(row.bookKey)}';
    return historyByKey[legacyKey];
  }

  /// Mihon stores History per chapter. A MyComic History row only knows the
  /// Manga and its open time, so the chapter comes from the imported snapshot
  /// when available and otherwise from the most recently touched chapter state.
  /// If neither exists there is no honest chapter URL to export.
  MihonBackupHistory? _libraryHistory({
    required EpubBookRow row,
    required OnlineMangaLibraryEntry entry,
    required Map<String, MangaChapterStateRow> states,
    required Map<String, MediaOpenHistoryRow> historyByKey,
  }) {
    final MediaOpenHistoryRow? history = _historyRowFor(
      row,
      entry,
      historyByKey,
    );
    if (history == null) return null;
    final Map<String, Object?>? snapshot = _snapshotJson(history.snapshotJson);
    final String? chapterUrl =
        _snapshotChapterUrl(snapshot) ?? _recentChapterKey(entry, states);
    if (chapterUrl == null || chapterUrl.isEmpty) return null;
    return MihonBackupHistory(
      url: chapterUrl,
      lastRead: history.openedAt,
      readDuration: _snapshotReadDuration(snapshot),
    );
  }

  static String? _recentChapterKey(
    OnlineMangaLibraryEntry entry,
    Map<String, MangaChapterStateRow> states,
  ) {
    String? bestKey;
    int bestUpdatedAt = -1;
    for (final OnlineMangaChapter chapter in entry.chapters) {
      final String key = chapter.key.trim();
      if (key.isEmpty) continue;
      final MangaChapterStateRow? state = states[key];
      if (state == null || state.updatedAt <= bestUpdatedAt) continue;
      bestUpdatedAt = state.updatedAt;
      bestKey = key;
    }
    if (bestKey != null) return bestKey;
    final String? current = entry.currentChapter?.key.trim();
    return current == null || current.isEmpty ? null : current;
  }

  static Map<String, Object?>? _snapshotJson(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<Object?, Object?>) {
        return decoded.cast<String, Object?>();
      }
    } on Object {
      // A corrupt snapshot must not abort the whole backup.
    }
    return null;
  }

  static String? _snapshotChapterUrl(Map<String, Object?>? snapshot) {
    final Object? history = snapshot?['mihon_history'];
    if (history is Map<Object?, Object?>) {
      final String? url = history['chapter_url']?.toString().trim();
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  static int _snapshotReadDuration(Map<String, Object?>? snapshot) {
    final Object? history = snapshot?['mihon_history'];
    if (history is Map<Object?, Object?>) {
      final Object? duration = history['read_duration'];
      if (duration is num) return duration.toInt();
    }
    return 0;
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

  /// Tags → Mihon categories.
  ///
  /// Mihon identifies categories inside `BackupManga.categories` by their
  /// **order**, so orders must be unique even though `BookTags.sortOrder` is
  /// not guaranteed to be (legacy rows default to 0). Display order is the
  /// source of truth: tags are visited in [FushiDatabase.getAllTags] order and
  /// a colliding sort order moves to the next free integer. Tag colours have
  /// no Mihon category field and are deliberately dropped.
  Future<_CategoryExport> _loadCategories() async {
    final List<BookTagRow> tags = await database.getAllTags();
    final Set<int> usedOrders = <int>{};
    final Map<int, int> orderByTagId = <int, int>{};
    final List<MihonBackupCategory> categories = <MihonBackupCategory>[];
    for (final BookTagRow tag in tags) {
      int order = tag.sortOrder < 0 ? 0 : tag.sortOrder;
      while (usedOrders.contains(order)) {
        order++;
      }
      usedOrders.add(order);
      orderByTagId[tag.id] = order;
      categories.add(
        MihonBackupCategory(name: tag.name, order: order, id: tag.id),
      );
    }

    final List<TagAssignmentRow> assignments = await database
        .getTagAssignmentsForKind(TagHostKind.epub);
    final Map<String, List<int>> ordersByBookKey = <String, List<int>>{};
    for (final TagAssignmentRow assignment in assignments) {
      final int? order = orderByTagId[assignment.tagId];
      if (order == null) continue;
      ordersByBookKey
          .putIfAbsent(assignment.entryKey, () => <int>[])
          .add(order);
    }
    for (final List<int> orders in ordersByBookKey.values) {
      orders.sort();
    }
    return _CategoryExport(
      categories: List<MihonBackupCategory>.unmodifiable(categories),
      ordersByBookKey: ordersByBookKey,
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

/// Resolved category section: the exported Mihon categories plus each book's
/// category orders (never tag ids — Mihon references categories by order).
class _CategoryExport {
  const _CategoryExport({
    required this.categories,
    required this.ordersByBookKey,
  });

  final List<MihonBackupCategory> categories;
  final Map<String, List<int>> ordersByBookKey;

  List<int> ordersFor(String bookKey) =>
      ordersByBookKey[bookKey] ?? const <int>[];
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

/// Identities that must not be re-exported as `favorite=false` read works.
class _LibraryHistoryKeys {
  const _LibraryHistoryKeys(this.historyKeys, this.seriesKeys);

  /// `mediaSource\0mediaId` of every Library Manga (current + legacy import).
  final Set<String> historyKeys;

  /// `<sourceId>\0url` of every Library Manga.
  final Set<String> seriesKeys;
}

class _HistorySource {
  const _HistorySource({required this.runtime, required this.sourceId});

  final OnlineMangaRuntimeKind runtime;
  final String sourceId;
}
