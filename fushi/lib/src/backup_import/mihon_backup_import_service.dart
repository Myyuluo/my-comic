import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/media_pref_keys.dart'
    show readerBookMediaIdentifierFor;
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show
        kTrackingProviderBangumi,
        TrackingKind,
        TrackingMediaType,
        TrackingProgressMode;

import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/sync/sync_repository.dart' show SyncRepository;

/// 占位 extension package：备份里的 Source 尚未安装时，书架条目仍要有一个稳定
/// 身份，否则每次导入都会因为 package 不同而新建一行。
///
/// 已知限制（后续 ticket 收口）：扩展安装后 `MihonLibraryAdapter` 用真实 package
/// 匹配源，本条目的身份不会自动改写；「安装缺失源后接管备份条目」不在 ticket 06
/// 的最小路径内。
const String kUnavailableMihonExtensionPackage = 'mihon.unavailable';

enum MihonBackupSkipReason { notInLibrary }

/// Why a top-level `BackupPreference` was not applied to MyComic's settings.
enum MihonBackupAppPreferenceSkipReason {
  /// The key is not one of MyComic's own app preference keys (Mihon native or
  /// completely unknown).
  notMyComicKey,

  /// The key describes another installation (device id, local paths, sync
  /// baselines). Restoring it would make this device impersonate the exporter.
  deviceLocal,

  /// This device already has a value for the key; local settings win.
  alreadyPresent,
}

/// Why a `favorite=false` ("read, not in library") entry restored no History.
enum MihonBackupHistorySkipReason {
  /// The entry carries no History rows, so there is no read timestamp.
  noHistory,

  /// The entry has no manga URL, so its History cannot be identified.
  missingUrl,

  /// A local History row is at least as new as the backup's.
  alreadyNewer,
}

enum MihonBackupFailureReason { missingUrl, databaseError }

class MihonBackupSourceIssue {
  const MihonBackupSourceIssue({
    required this.sourceId,
    required this.sourceName,
    required this.entryCount,
    this.preferenceCount = 0,
  });

  final int sourceId;
  final String sourceName;
  final int entryCount;

  /// Source preferences kept for this source even though its extension is not
  /// installed. They live under [kUnavailableMihonExtensionPackage] until the
  /// extension is installed and the entry is refreshed.
  final int preferenceCount;
}

/// One unsupported Mihon tracker (`syncId`) encountered in the backup.
class MihonBackupTrackerIssue {
  const MihonBackupTrackerIssue({
    required this.syncId,
    required this.name,
    required this.count,
  });

  final int syncId;
  final String name;
  final int count;
}

/// Mihon `TrackerManager` ids (v0.21.3) → display names.
const Map<int, String> kMihonTrackerNames = <int, String>{
  1: 'MyAnimeList',
  2: 'AniList',
  3: 'Kitsu',
  4: 'Shikimori',
  5: 'Bangumi',
  6: 'Komga',
  7: 'MangaUpdates',
  8: 'Kavita',
  9: 'Suwayomi',
  10: 'Hikka',
  11: 'MangaBaka',
  12: 'Comick',
};

/// Fushi only implements Bangumi tracking, so every other Mihon tracker is
/// skipped and reported instead of aborting the import.
const int kMihonBangumiTrackerId = 5;

class MihonBackupImportProgress {
  const MihonBackupImportProgress({
    required this.processed,
    required this.total,
    required this.currentTitle,
  });

  final int processed;
  final int total;
  final String currentTitle;
}

class MihonBackupImportReport {
  const MihonBackupImportReport({
    required this.totalEntries,
    required this.importedEntries,
    required this.mergedEntries,
    required this.skippedEntries,
    required this.failedEntries,
    required this.categoriesCreated,
    required this.categoriesMatched,
    required this.categoriesSkipped,
    required this.appPreferencesImported,
    required this.appPreferencesSkippedByReason,
    required this.nonLibraryHistoryImported,
    required this.nonLibraryHistorySkippedByReason,
    required this.chapterStatesWritten,
    required this.historyRowsWritten,
    required this.trackingMappingsImported,
    required this.trackingMappingsMerged,
    required this.trackingSkipped,
    required this.trackingInvalidRemoteIds,
    required this.unsupportedTrackers,
    required this.extensionStoresImported,
    required this.extensionStoresMerged,
    required this.extensionStoresSkipped,
    required this.extensionStoresFailed,
    required this.sourcePreferencesImported,
    required this.sourcePreferencesForMissingSources,
    required this.sourcePreferencesSkipped,
    required this.sourcePreferencesFailed,
    required this.skippedByReason,
    required this.failedByReason,
    required this.missingSources,
    required this.elapsed,
  });

  final int totalEntries;

  /// New library rows.
  final int importedEntries;

  /// Entries already in the library, matched by (source, manga url). Their
  /// reading progress and category membership were merged in place.
  final int mergedEntries;

  /// `favorite=false` ("read, not in library") entries. They never become
  /// Library rows; their History may still be restored — see
  /// [nonLibraryHistoryImported].
  final int skippedEntries;

  final int failedEntries;

  /// Tags created from Backup categories (Mihon categories import as Tags).
  final int categoriesCreated;

  /// Backup categories matched an existing Tag by trimmed name and reused it.
  final int categoriesMatched;

  /// Backup categories skipped because their name is blank.
  final int categoriesSkipped;

  /// MyComic app settings written because this device lacked the key.
  final int appPreferencesImported;

  /// App settings left untouched, grouped by why.
  final Map<MihonBackupAppPreferenceSkipReason, int>
  appPreferencesSkippedByReason;

  /// `media_open_history` rows restored from `favorite=false` entries.
  final int nonLibraryHistoryImported;

  /// `favorite=false` entries that restored no History, grouped by why.
  final Map<MihonBackupHistorySkipReason, int> nonLibraryHistorySkippedByReason;

  /// Chapter progress rows written or merged (read + partially read + history).
  final int chapterStatesWritten;

  /// `media_open_history` rows written (one per library entry with history).
  final int historyRowsWritten;

  /// New Bangumi tracking mappings written.
  final int trackingMappingsImported;

  /// Existing Bangumi mappings updated or kept in sync.
  final int trackingMappingsMerged;

  /// Tracking entries skipped because the tracker is unsupported or the
  /// remote id is missing.
  final int trackingSkipped;

  /// Subset of [trackingSkipped]: supported tracker with no remote id.
  final int trackingInvalidRemoteIds;

  /// Unsupported trackers grouped by Mihon `syncId` (never includes Bangumi).
  final List<MihonBackupTrackerIssue> unsupportedTrackers;

  final int extensionStoresImported;
  final int extensionStoresMerged;

  /// Stores skipped because the backup entry has no usable index URL.
  final int extensionStoresSkipped;

  /// Stores that failed to persist (database error); the import continued.
  final int extensionStoresFailed;

  /// Source preference rows written (installed or placeholder package).
  final int sourcePreferencesImported;

  /// Subset of [sourcePreferencesImported] kept for sources whose extension is
  /// not installed. They are reported so the user knows to install the source.
  final int sourcePreferencesForMissingSources;

  /// Preferences skipped because they have no usable key/source id.
  final int sourcePreferencesSkipped;

  /// Preferences that failed to persist (database error); the import continued.
  final int sourcePreferencesFailed;

  final Map<MihonBackupSkipReason, int> skippedByReason;
  final Map<MihonBackupFailureReason, int> failedByReason;

  /// Sources from the backup that are not installed (or disabled) on this
  /// machine. Their entries are still imported and open as "source unavailable"
  /// until the extension is installed.
  final List<MihonBackupSourceIssue> missingSources;

  final Duration elapsed;

  bool get isEmpty =>
      totalEntries == 0 &&
      extensionStoresImported == 0 &&
      extensionStoresMerged == 0 &&
      sourcePreferencesImported == 0 &&
      appPreferencesImported == 0 &&
      nonLibraryHistoryImported == 0;

  int get successfulEntries => importedEntries + mergedEntries;

  int get appPreferencesSkipped => appPreferencesSkippedByReason.values
      .fold<int>(0, (int sum, int count) => sum + count);

  int get nonLibraryHistorySkipped => nonLibraryHistorySkippedByReason.values
      .fold<int>(0, (int sum, int count) => sum + count);
}

/// Imports a Mihon v0.21.3 `.tachibk` backup into the my-comic library.
///
/// This is the test seam: file in, domain report out. Parsing (gzip + protobuf)
/// and persistence stay behind it. The backup is read from local disk only;
/// nothing is uploaded.
class MihonBackupImportService {
  MihonBackupImportService({
    required this.database,
    Future<String> Function(String bookKey)? bookDirectory,
    int Function()? now,
  }) : _bookDirectory = bookDirectory ?? MangaStorage.bookPath,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final FushiDatabase database;
  final Future<String> Function(String bookKey) _bookDirectory;
  final int Function() _now;

  Future<MihonBackupImportReport> importFile(
    File file, {
    void Function(MihonBackupImportProgress progress)? onProgress,
  }) async {
    final Stopwatch stopwatch = Stopwatch()..start();
    final MihonBackupData data = MihonBackupParser.parseFile(file);
    final int importNow = _now();

    final List<MangaOnlineSourceRow> installed = await database
        .getMangaOnlineSources(mediaKind: 'manga');
    final Map<int, MangaOnlineSourceRow> installedBySourceId =
        <int, MangaOnlineSourceRow>{
          for (final MangaOnlineSourceRow row in installed)
            if (int.tryParse(row.sourceId) case final int id) id: row,
        };

    // App settings are planned (and validated) before the first write. An
    // unknown preference value type aborts the whole import instead of
    // applying half a backup (Mihon itself refuses to restore an unknown
    // serial name). This must stay above Tag creation below, which writes.
    final _AppPreferencePlan appPreferences = _planAppPreferences(
      data.preferences,
      await database.getAllPrefs(),
    );

    // Mihon categories import as Tags. Resolve/create each one by trimmed name
    // and align its sort order with the category order, so a MyComic-generated
    // backup (Tags exported as categories) round-trips. Per-manga
    // BackupManga.categories stores category *orders*, not ids.
    final List<BookTagRow> existingTags = await database.getAllTags();
    final Map<String, int> tagIdByName = <String, int>{
      for (final BookTagRow tag in existingTags) tag.name: tag.id,
    };
    final Map<String, int> tagSortOrderByName = <String, int>{
      for (final BookTagRow tag in existingTags) tag.name: tag.sortOrder,
    };
    final Map<int, int> tagIdByCategoryOrder = <int, int>{};
    int categoriesCreated = 0;
    int categoriesMatched = 0;
    int categoriesSkipped = 0;
    for (final MihonBackupCategory category in data.categories) {
      final String name = category.name.trim();
      if (name.isEmpty) {
        categoriesSkipped++;
        continue;
      }
      final int? existingTagId = tagIdByName[name];
      final int tagId;
      if (existingTagId == null) {
        tagId = await database.getOrCreateTagByName(name);
        tagIdByName[name] = tagId;
        categoriesCreated++;
      } else {
        tagId = existingTagId;
        categoriesMatched++;
      }
      if (tagSortOrderByName[name] != category.order) {
        await (database.update(database.bookTags)
              ..where((t) => t.id.equals(tagId)))
            .write(BookTagsCompanion(sortOrder: Value<int>(category.order)));
        tagSortOrderByName[name] = category.order;
      }
      tagIdByCategoryOrder[category.order] = tagId;
    }

    final Map<String, _ExistingEntry> existing = await _loadExistingEntries();
    final Map<int, _MissingSourceBuilder> missing =
        <int, _MissingSourceBuilder>{};
    final Map<MihonBackupSkipReason, int> skippedByReason =
        <MihonBackupSkipReason, int>{};
    final Map<MihonBackupFailureReason, int> failedByReason =
        <MihonBackupFailureReason, int>{};
    final Map<MihonBackupHistorySkipReason, int> nonLibraryHistorySkipped =
        <MihonBackupHistorySkipReason, int>{};
    int nonLibraryHistoryImported = 0;
    int imported = 0;
    int merged = 0;
    int skipped = 0;
    int failed = 0;
    int chapterStatesWritten = 0;
    int historyRowsWritten = 0;
    int trackingMappingsImported = 0;
    int trackingMappingsMerged = 0;
    int trackingSkipped = 0;
    int trackingInvalidRemoteIds = 0;
    final Map<int, int> skippedTrackers = <int, int>{};
    int extensionStoresImported = 0;
    int extensionStoresMerged = 0;
    int extensionStoresSkipped = 0;
    int extensionStoresFailed = 0;
    int sourcePreferencesImported = 0;
    int sourcePreferencesForMissingSources = 0;
    int sourcePreferencesSkipped = 0;
    int sourcePreferencesFailed = 0;

    // One transaction for the whole import: a backup with thousands of entries
    // otherwise pays one fsync per row/chapter-state, which on Windows turns a
    // few seconds of SQLite work into tens of minutes. Directory creation is
    // deliberately deferred to first open (`ensureBookDirectory`) so importing
    // 5k+ entries does not create 5k folders synchronously.
    await database.transaction(() async {
      int processed = 0;
      for (final MihonBackupManga manga in data.mangas) {
        processed++;
        if (processed % 25 == 0 || processed == data.mangas.length) {
          onProgress?.call(
            MihonBackupImportProgress(
              processed: processed,
              total: data.mangas.length,
              currentTitle: manga.title,
            ),
          );
        }

        if (!manga.favorite) {
          skipped++;
          _increment(skippedByReason, MihonBackupSkipReason.notInLibrary);
          // Mihon exports read works that are not in the Library as
          // `favorite=false` so their History survives a restore. MyComic
          // restores that History without adding a Library row.
          final MihonBackupHistorySkipReason? historySkip =
              await _importNonLibraryHistory(
                manga,
                local: existing[_identityKey(manga.source, manga.url.trim())],
                installedBySourceId: installedBySourceId,
              );
          if (historySkip == null) {
            nonLibraryHistoryImported++;
          } else {
            _increment(nonLibraryHistorySkipped, historySkip);
          }
          continue;
        }

        final String url = manga.url.trim();
        if (url.isEmpty) {
          failed++;
          failedByReason.update(
            MihonBackupFailureReason.missingUrl,
            (int value) => value + 1,
            ifAbsent: () => 1,
          );
          continue;
        }

        final MangaOnlineSourceRow? source = installedBySourceId[manga.source];
        if (source == null || !source.enabled) {
          missing
              .putIfAbsent(
                manga.source,
                () => _MissingSourceBuilder(
                  sourceId: manga.source,
                  sourceName:
                      data.sourceNames[manga.source] ??
                      'Source ${manga.source}',
                ),
              )
              .entryCount++;
        }
        final String extensionPackage =
            source?.extensionPackage ?? kUnavailableMihonExtensionPackage;
        final String identityKey = _identityKey(manga.source, url);

        try {
          final _ExistingEntry? duplicate = existing[identityKey];
          final EpubBookRow row;
          if (duplicate == null) {
            row = await _insertEntry(
              manga,
              extensionPackage: extensionPackage,
              importNow: importNow,
            );
            existing[identityKey] = _ExistingEntry(
              row: row,
              entry: OnlineMangaLibraryEntry.tryParse(row.sourceMetadata),
            );
            imported++;
          } else {
            row = await _mergeChaptersIntoExisting(duplicate, manga);
            merged++;
          }

          chapterStatesWritten += await _applyReadingProgress(
            row: row,
            manga: manga,
            importNow: importNow,
          );
          historyRowsWritten += await _applyHistory(row: row, manga: manga);
          final _TrackingWriteResult tracking = await _applyTracking(
            row: row,
            manga: manga,
            importNow: importNow,
          );
          trackingMappingsImported += tracking.imported;
          trackingMappingsMerged += tracking.merged;
          trackingSkipped += tracking.skipped;
          trackingInvalidRemoteIds += tracking.invalidRemoteIds;
          for (final MapEntry<int, int> entry
              in tracking.skippedByTracker.entries) {
            skippedTrackers.update(
              entry.key,
              (int value) => value + entry.value,
              ifAbsent: () => entry.value,
            );
          }
          await _applyTags(
            row: row,
            manga: manga,
            tagIdByCategoryOrder: tagIdByCategoryOrder,
          );
        } on Object {
          failed++;
          failedByReason.update(
            MihonBackupFailureReason.databaseError,
            (int value) => value + 1,
            ifAbsent: () => 1,
          );
        }
      }

      final _ExtensionStoreWriteResult stores = await _importExtensionStores(
        data.extensionStores,
        importNow: importNow,
      );
      extensionStoresImported += stores.imported;
      extensionStoresMerged += stores.merged;
      extensionStoresSkipped += stores.skipped;
      extensionStoresFailed += stores.failed;

      final _SourcePreferenceWriteResult preferences =
          await _importSourcePreferences(
            data.sourcePreferences,
            installedBySourceId: installedBySourceId,
            sourceNames: data.sourceNames,
            missing: missing,
            importNow: importNow,
          );
      sourcePreferencesImported += preferences.imported;
      sourcePreferencesForMissingSources += preferences.forMissingSources;
      sourcePreferencesSkipped += preferences.skipped;
      sourcePreferencesFailed += preferences.failed;

      // Fills only the keys this device lacks; `setPrefs` also bumps the
      // cross-process prefs-version signal in the same transaction.
      await database.setPrefs(appPreferences.values);
    });

    stopwatch.stop();
    return MihonBackupImportReport(
      totalEntries: data.mangas.length,
      importedEntries: imported,
      mergedEntries: merged,
      skippedEntries: skipped,
      failedEntries: failed,
      categoriesCreated: categoriesCreated,
      categoriesMatched: categoriesMatched,
      categoriesSkipped: categoriesSkipped,
      appPreferencesImported: appPreferences.values.length,
      appPreferencesSkippedByReason:
          Map<MihonBackupAppPreferenceSkipReason, int>.unmodifiable(
            appPreferences.skippedByReason,
          ),
      nonLibraryHistoryImported: nonLibraryHistoryImported,
      nonLibraryHistorySkippedByReason:
          Map<MihonBackupHistorySkipReason, int>.unmodifiable(
            nonLibraryHistorySkipped,
          ),
      chapterStatesWritten: chapterStatesWritten,
      historyRowsWritten: historyRowsWritten,
      trackingMappingsImported: trackingMappingsImported,
      trackingMappingsMerged: trackingMappingsMerged,
      trackingSkipped: trackingSkipped,
      trackingInvalidRemoteIds: trackingInvalidRemoteIds,
      unsupportedTrackers: List<MihonBackupTrackerIssue>.unmodifiable(
        <MihonBackupTrackerIssue>[
          for (final MapEntry<int, int> entry in skippedTrackers.entries)
            MihonBackupTrackerIssue(
              syncId: entry.key,
              name: kMihonTrackerNames[entry.key] ?? 'Tracker ${entry.key}',
              count: entry.value,
            ),
        ]..sort(
          (MihonBackupTrackerIssue a, MihonBackupTrackerIssue b) =>
              a.syncId.compareTo(b.syncId),
        ),
      ),
      extensionStoresImported: extensionStoresImported,
      extensionStoresMerged: extensionStoresMerged,
      extensionStoresSkipped: extensionStoresSkipped,
      extensionStoresFailed: extensionStoresFailed,
      sourcePreferencesImported: sourcePreferencesImported,
      sourcePreferencesForMissingSources: sourcePreferencesForMissingSources,
      sourcePreferencesSkipped: sourcePreferencesSkipped,
      sourcePreferencesFailed: sourcePreferencesFailed,
      skippedByReason: Map<MihonBackupSkipReason, int>.unmodifiable(
        skippedByReason,
      ),
      failedByReason: Map<MihonBackupFailureReason, int>.unmodifiable(
        failedByReason,
      ),
      missingSources: List<MihonBackupSourceIssue>.unmodifiable(
        <MihonBackupSourceIssue>[
          for (final _MissingSourceBuilder builder in missing.values)
            builder.build(),
        ],
      ),
      elapsed: stopwatch.elapsed,
    );
  }

  String _identityKey(int sourceId, String mangaUrl) =>
      '$sourceId${String.fromCharCode(0)}$mangaUrl';

  static void _increment<T>(Map<T, int> counts, T key) {
    counts.update(key, (int value) => value + 1, ifAbsent: () => 1);
  }

  /// Decides which top-level `BackupPreference` rows become MyComic settings.
  ///
  /// Only MyComic's own keys are eligible: the static [kKnownPreferenceKeys]
  /// registry plus the registered dynamic-prefix families. Mihon's native keys
  /// (and anything unknown) are reported as [notMyComicKey] instead of being
  /// written into the `preferences` table. Device-local keys describe the
  /// exporting machine and are skipped even though they are "known". Existing
  /// local values always win (spec: 只补齐本机缺失的键).
  ///
  /// Throws [MihonBackupFormatException] for an unknown value type on a known
  /// key. This runs before the first write, so a rejected file leaves no
  /// partial import behind.
  _AppPreferencePlan _planAppPreferences(
    List<MihonBackupPreference> preferences,
    Map<String, String> existing,
  ) {
    final Map<String, String> values = <String, String>{};
    final Map<MihonBackupAppPreferenceSkipReason, int> skippedByReason =
        <MihonBackupAppPreferenceSkipReason, int>{};
    final Set<String> present = existing.keys.toSet();
    for (final MihonBackupPreference preference in preferences) {
      final String key = preference.key;
      if (key.isEmpty || !_isKnownAppPreferenceKey(key)) {
        _increment(
          skippedByReason,
          MihonBackupAppPreferenceSkipReason.notMyComicKey,
        );
        continue;
      }
      // Validate first: an unknown standard type must abort even when this
      // device happens to already have the key.
      final String encoded = _encodeAppPreferenceValue(preference);
      if (SyncRepository.deviceLocalPrefKeys.contains(key)) {
        _increment(
          skippedByReason,
          MihonBackupAppPreferenceSkipReason.deviceLocal,
        );
        continue;
      }
      if (!present.add(key)) {
        _increment(
          skippedByReason,
          MihonBackupAppPreferenceSkipReason.alreadyPresent,
        );
        continue;
      }
      values[key] = encoded;
    }
    return _AppPreferencePlan(values: values, skippedByReason: skippedByReason);
  }

  static bool _isKnownAppPreferenceKey(String key) =>
      kKnownPreferenceKeys.contains(key) ||
      kKnownPreferenceKeyPrefixes.any(key.startsWith);

  /// Re-encodes a backup preference value in MyComic's [PrefCodec] format.
  ///
  /// All six standard Mihon envelopes map 1:1. An unknown serial name (or a
  /// value whose runtime type does not match its envelope) aborts the import:
  /// writing a guess would silently corrupt a setting.
  static String _encodeAppPreferenceValue(MihonBackupPreference preference) {
    final MihonBackupPreferenceType type = preference.value.type;
    final Object? value = preference.value.value;
    final bool valid = switch (type) {
      MihonBackupPreferenceType.string => value is String,
      MihonBackupPreferenceType.boolean => value is bool,
      MihonBackupPreferenceType.integer ||
      MihonBackupPreferenceType.long => value is int,
      MihonBackupPreferenceType.float => value is double,
      MihonBackupPreferenceType.stringSet => value is List<String>,
      MihonBackupPreferenceType.unsupported => false,
    };
    if (!valid) {
      throw MihonBackupFormatException(
        MihonBackupFormatError.corrupt,
        'unsupported value type for preference "${preference.key}"',
      );
    }
    return PrefCodec.encode(value);
  }

  /// Restores the newest History row of a `favorite=false` entry without
  /// creating a Library row.
  ///
  /// Returns null when a row was written, or the reason nothing was restored.
  /// The row carries the same snapshot shape the reader writes, so the History
  /// page can show and reopen the work. When the work already exists in the
  /// local Library, its identity (and source package) is reused so the History
  /// does not appear twice.
  Future<MihonBackupHistorySkipReason?> _importNonLibraryHistory(
    MihonBackupManga manga, {
    required _ExistingEntry? local,
    required Map<int, MangaOnlineSourceRow> installedBySourceId,
  }) async {
    MihonBackupHistory? latest;
    for (final MihonBackupHistory history in manga.history) {
      if (history.lastRead <= 0) continue;
      if (latest == null || history.lastRead > latest.lastRead) {
        latest = history;
      }
    }
    if (latest == null) {
      return MihonBackupHistorySkipReason.noHistory;
    }

    final String url = manga.url.trim();
    if (url.isEmpty) {
      return MihonBackupHistorySkipReason.missingUrl;
    }

    final MangaHistoryIdentity identity;
    final MangaHistoryOnlineRef online;
    final OnlineMangaLibraryEntry? localEntry = local?.entry;
    if (localEntry != null) {
      identity = mangaHistoryIdentityForOnline(localEntry);
      online = MangaHistoryOnlineRef.fromEntry(localEntry);
    } else {
      final String extensionPackage =
          installedBySourceId[manga.source]?.extensionPackage ??
          kUnavailableMihonExtensionPackage;
      final OnlineMangaLibraryEntry entry = _entryFromBackup(
        manga,
        extensionPackage: extensionPackage,
      );
      identity = mangaHistoryIdentityForOnline(entry);
      online = MangaHistoryOnlineRef.fromEntry(entry);
    }

    final MediaOpenHistoryRow? existing =
        await (database.select(database.mediaOpenHistory)..where(
              (t) =>
                  t.mediaSource.equals(identity.mediaSource) &
                  t.mediaId.equals(identity.mediaId),
            ))
            .getSingleOrNull();
    if (existing != null && existing.openedAt >= latest.lastRead) {
      return MihonBackupHistorySkipReason.alreadyNewer;
    }

    final Map<String, Object?> snapshot = MangaHistorySnapshot(
      title: manga.title,
      author: manga.author,
      imageUrl: manga.thumbnailUrl ?? online.coverUrl,
      online: online,
    ).toJson();
    // `mihon_history` is the top-level block the exporter reads back (chapter
    // URL + duration); `MangaHistorySnapshot` deliberately ignores it.
    snapshot['mihon_history'] = <String, Object?>{
      'chapter_url': latest.url,
      'read_at': latest.lastRead,
      'read_duration': latest.readDuration,
    };

    await database.upsertMediaOpenHistory(
      MediaOpenHistoryCompanion(
        mediaType: const Value<String>('reader_media_type'),
        mediaSource: Value<String>(identity.mediaSource),
        mediaId: Value<String>(identity.mediaId),
        openedAt: Value<int>(latest.lastRead),
        position: const Value<int>(0),
        duration: const Value<int>(0),
        snapshotJson: Value<String>(jsonEncode(snapshot)),
      ),
    );
    return null;
  }

  Future<Map<String, _ExistingEntry>> _loadExistingEntries() async {
    final List<EpubBookRow> rows = await database
        .select(database.epubBooks)
        .get();
    final Map<String, _ExistingEntry> existing = <String, _ExistingEntry>{};
    for (final EpubBookRow row in rows) {
      if (row.format != 'manga') continue;
      final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
      if (entry == null || entry.runtime != OnlineMangaRuntimeKind.mihon) {
        continue;
      }
      existing[_identityKey(
        int.tryParse(entry.sourceId) ?? 0,
        entry.series.key,
      )] = _ExistingEntry(
        row: row,
        entry: entry,
      );
    }
    return existing;
  }

  Future<EpubBookRow> _insertEntry(
    MihonBackupManga manga, {
    required String extensionPackage,
    required int importNow,
  }) async {
    final String sourceId = '${manga.source}';
    final String mangaUrl = manga.url.trim();
    final OnlineMangaLibraryEntry entry = _entryFromBackup(
      manga,
      extensionPackage: extensionPackage,
    );
    final String bookKey = onlineMangaBookKeyFor(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      seriesKey: mangaUrl,
    );
    // Path only; the directory is created lazily by `ensureBookDirectory`
    // when the user first opens the entry. Creating thousands of folders (and
    // their placeholder manga.json files) during import is pure latency.
    final String directoryPath = await _bookDirectory(bookKey);

    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: manga.title,
        author: Value<String?>(_bylineOf(manga)),
        epubPath: MangaStorage.kMangaJsonFileName,
        extractDir: directoryPath,
        chapterCount: entry.chapters.length,
        chaptersJson: _chaptersJson(entry.chapters),
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: manga.dateAdded > 0 ? manga.dateAdded : importNow,
        format: const Value<String>('manga'),
      ),
    );
    return (await database.getEpubBook(bookKey))!;
  }

  /// Merge a duplicate entry: keep local metadata (local wins, as in Mihon's
  /// restore), but adopt chapters the backup knows about that the local
  /// descriptor does not, so merged progress rows remain reachable.
  Future<EpubBookRow> _mergeChaptersIntoExisting(
    _ExistingEntry duplicate,
    MihonBackupManga manga,
  ) async {
    final OnlineMangaLibraryEntry? local = duplicate.entry;
    if (local == null) return duplicate.row;

    final Map<String, OnlineMangaChapter> byKey = <String, OnlineMangaChapter>{
      for (final OnlineMangaChapter chapter in local.chapters)
        chapter.key: chapter,
    };
    bool changed = false;
    for (final MihonBackupChapter chapter in manga.chapters) {
      final String key = chapter.url.trim();
      if (key.isEmpty) continue;
      final OnlineMangaChapter? current = byKey[key];
      if (current == null) {
        byKey[key] = _onlineChapter(chapter);
        changed = true;
        continue;
      }
      final OnlineMangaChapter merged = _mergeChapter(current, chapter);
      if (!identical(merged, current)) {
        byKey[key] = merged;
        changed = true;
      }
    }
    if (!changed) return duplicate.row;

    final List<OnlineMangaChapter> mergedChapters =
        List<OnlineMangaChapter>.unmodifiable(byKey.values);
    final OnlineMangaLibraryEntry updated = local.copyWith(
      chapters: mergedChapters,
      currentChapterIndex: local.currentChapterIndex,
    );
    await database.updateEpubBookMihonState(
      duplicate.row.bookKey,
      sourceMetadata: updated.encode(),
      chapterCount: mergedChapters.length,
      chaptersJson: _chaptersJson(mergedChapters),
    );
    final EpubBookRow? refreshed = await database.getEpubBook(
      duplicate.row.bookKey,
    );
    return refreshed ?? duplicate.row;
  }

  Future<int> _applyReadingProgress({
    required EpubBookRow row,
    required MihonBackupManga manga,
    required int importNow,
  }) async {
    // History timestamps are the only per-chapter "when" in the backup.
    final Map<String, int> historyByUrl = <String, int>{
      for (final MihonBackupHistory history in manga.history)
        if (history.url.isNotEmpty && history.lastRead > 0)
          history.url: history.lastRead,
    };

    int written = 0;
    int? latestChapterAt;
    int? latestChapterIndex;
    for (int index = 0; index < manga.chapters.length; index++) {
      final MihonBackupChapter chapter = manga.chapters[index];
      final String chapterKey = chapter.url.trim();
      if (chapterKey.isEmpty) continue;
      final int? historyAt = historyByUrl[chapterKey];
      final bool hasProgress = chapter.read || chapter.lastPageRead > 0;
      if (!hasProgress && historyAt == null) continue;

      final int fallbackAt = chapter.dateFetch > 0
          ? chapter.dateFetch
          : importNow;
      final int updatedAt = historyAt ?? fallbackAt;
      final int? readAt = chapter.read ? (historyAt ?? fallbackAt) : null;
      await database.importMangaChapterState(
        bookUid: row.uid,
        chapterKey: chapterKey,
        lastPage: chapter.lastPageRead,
        readAt: readAt,
        updatedAt: updatedAt,
      );
      written++;

      // Book-level recency (`reader_positions.updatedAt`) is what the shelf's
      // "recently read" sort reads. Only backup timestamps count here; the
      // importNow fallback above must never make everything look freshly read.
      final int? backupAt =
          historyAt ?? (chapter.dateFetch > 0 ? chapter.dateFetch : null);
      if (backupAt != null && backupAt > (latestChapterAt ?? 0)) {
        latestChapterAt = backupAt;
        latestChapterIndex = index;
      }
    }

    if (latestChapterAt != null && row.uid.isNotEmpty) {
      final ReaderPositionRow? existing = await database.getReaderPosition(
        row.uid,
      );
      if (existing == null || existing.updatedAt < latestChapterAt) {
        await database.upsertReaderPosition(
          ReaderPositionsCompanion.insert(
            bookUid: row.uid,
            sectionIndex: latestChapterIndex ?? 0,
            normCharOffset: 0,
            updatedAt: latestChapterAt,
          ),
        );
      }
    }
    return written;
  }

  /// Write the newest Mihon history entry as one `media_open_history` row.
  ///
  /// `media_open_history` has one row per media item, so per-chapter history
  /// entries collapse to the newest read. The per-chapter timestamps still
  /// feed `manga_chapter_states` (above), independently of this row.
  Future<int> _applyHistory({
    required EpubBookRow row,
    required MihonBackupManga manga,
  }) async {
    if (manga.history.isEmpty) return 0;
    MihonBackupHistory latest = manga.history.first;
    for (final MihonBackupHistory candidate in manga.history) {
      if (candidate.lastRead > latest.lastRead) latest = candidate;
    }

    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    final int total = entry?.chapters.length ?? manga.chapters.length;
    final int? selected = entry?.currentChapterIndex;
    final int duration = total > 0 ? total : 1;
    final int position = selected == null || selected < 0 || selected >= total
        ? 0
        : (total - selected).clamp(0, total);
    final String mediaId = readerBookMediaIdentifierFor(row.bookKey);

    final MediaOpenHistoryRow? existing =
        await (database.select(database.mediaOpenHistory)..where(
              (t) =>
                  t.mediaSource.equals('reader_manga') &
                  t.mediaId.equals(mediaId),
            ))
            .getSingleOrNull();
    final bool writeRow =
        existing == null || latest.lastRead >= existing.openedAt;

    if (writeRow) {
      final String snapshot = jsonEncode(<String, Object?>{
        'title': row.title,
        'author': row.author,
        if (manga.thumbnailUrl != null) 'imageUrl': manga.thumbnailUrl,
        'mihon_history': <String, Object?>{
          'chapter_url': latest.url,
          'read_at': latest.lastRead,
          'read_duration': latest.readDuration,
        },
      });
      await database.upsertMediaOpenHistory(
        MediaOpenHistoryCompanion(
          mediaType: const Value<String>('reader_media_type'),
          mediaSource: const Value<String>('reader_manga'),
          mediaId: Value<String>(mediaId),
          openedAt: Value<int>(latest.lastRead),
          position: Value<int>(position),
          duration: Value<int>(duration),
          snapshotJson: Value<String>(snapshot),
        ),
      );
    }

    return writeRow ? 1 : 0;
  }

  /// Map the trackers Fushi actually supports (Bangumi). Everything else is
  /// counted and skipped so one unsupported tracker cannot abort the import.
  Future<_TrackingWriteResult> _applyTracking({
    required EpubBookRow row,
    required MihonBackupManga manga,
    required int importNow,
  }) async {
    int imported = 0;
    int merged = 0;
    int skipped = 0;
    int invalidRemoteIds = 0;
    final Map<int, int> skippedByTracker = <int, int>{};

    for (final MihonBackupTracking tracking in manga.tracking) {
      if (tracking.syncId != kMihonBangumiTrackerId) {
        skipped++;
        skippedByTracker.update(
          tracking.syncId,
          (int value) => value + 1,
          ifAbsent: () => 1,
        );
        continue;
      }
      final int? remoteId = tracking.remoteId;
      if (remoteId == null || remoteId <= 0) {
        skipped++;
        invalidRemoteIds++;
        continue;
      }

      final int progress = tracking.lastChapterRead <= 0
          ? 0
          : tracking.lastChapterRead.toInt();
      final bool completed = tracking.status == 2;
      final int at =
          tracking.finishedReadingDate ??
          tracking.startedReadingDate ??
          importNow;
      final String subjectName = tracking.title.trim().isEmpty
          ? row.title
          : tracking.title.trim();
      final String mediaType = TrackingMediaType.book.value;
      final String mediaKey = row.bookKey;

      final MediaTrackingMappingRow? existing =
          await (database.select(database.mediaTrackingMappings)..where(
                (t) =>
                    t.provider.equals(kTrackingProviderBangumi) &
                    t.mediaType.equals(mediaType) &
                    t.mediaKey.equals(mediaKey),
              ))
              .getSingleOrNull();

      if (existing == null) {
        final int mappingId = await database
            .into(database.mediaTrackingMappings)
            .insert(
              MediaTrackingMappingsCompanion.insert(
                provider: const Value<String>(kTrackingProviderBangumi),
                mediaType: mediaType,
                mediaKey: mediaKey,
                mediaTitle: row.title,
                kind: TrackingKind.manga.value,
                subjectId: remoteId,
                subjectName: subjectName,
                progressMode: TrackingProgressMode.chapter.value,
                progressOffset: const Value<int>(0),
                createdAt: tracking.startedReadingDate ?? importNow,
                updatedAt: at,
              ),
            );
        if (progress > 0 || completed) {
          await database
              .into(database.mediaTrackingOutbox)
              .insert(
                MediaTrackingOutboxCompanion.insert(
                  mappingId: mappingId,
                  progress: progress,
                  completed: Value<bool>(completed),
                  updatedAt: at,
                ),
              );
        }
        imported++;
        continue;
      }

      final MediaTrackingOutboxRow? outbox = await (database.select(
        database.mediaTrackingOutbox,
      )..where((t) => t.mappingId.equals(existing.id))).getSingleOrNull();
      final int existingProgress = outbox?.progress ?? 0;
      final bool existingCompleted = outbox?.completed ?? false;
      final bool backupAhead =
          progress > existingProgress || (completed && !existingCompleted);

      if (backupAhead) {
        await (database.update(
          database.mediaTrackingMappings,
        )..where((t) => t.id.equals(existing.id))).write(
          MediaTrackingMappingsCompanion(
            mediaTitle: Value<String>(row.title),
            subjectId: Value<int>(remoteId),
            subjectName: Value<String>(subjectName),
            progressMode: Value<String>(TrackingProgressMode.chapter.value),
            updatedAt: Value<int>(at),
          ),
        );
        if (outbox == null) {
          await database
              .into(database.mediaTrackingOutbox)
              .insert(
                MediaTrackingOutboxCompanion.insert(
                  mappingId: existing.id,
                  progress: progress,
                  completed: Value<bool>(completed),
                  updatedAt: at,
                ),
              );
        } else {
          await (database.update(
            database.mediaTrackingOutbox,
          )..where((t) => t.id.equals(outbox.id))).write(
            MediaTrackingOutboxCompanion(
              progress: Value<int>(progress),
              // Completed is monotonic: a later "reading" backup row must not
              // clear a locally-completed entry.
              completed: Value<bool>(completed || existingCompleted),
              updatedAt: Value<int>(
                at > outbox.updatedAt ? at : outbox.updatedAt,
              ),
            ),
          );
        }
      }
      merged++;
    }

    return _TrackingWriteResult(
      imported: imported,
      merged: merged,
      skipped: skipped,
      invalidRemoteIds: invalidRemoteIds,
      skippedByTracker: skippedByTracker,
    );
  }

  Future<_ExtensionStoreWriteResult> _importExtensionStores(
    List<MihonBackupExtensionStore> stores, {
    required int importNow,
  }) async {
    int imported = 0;
    int merged = 0;
    int skipped = 0;
    int failed = 0;
    final List<MangaExtensionStoreRow> existingRows = await database
        .getMangaExtensionStores(mediaKind: 'manga');
    final Map<String, MangaExtensionStoreRow> existing =
        <String, MangaExtensionStoreRow>{
          for (final MangaExtensionStoreRow row in existingRows)
            row.indexUrl: row,
        };
    int nextSortOrder = existingRows.isEmpty
        ? 0
        : existingRows
                  .map((MangaExtensionStoreRow row) => row.sortOrder)
                  .reduce((int a, int b) => a > b ? a : b) +
              1;

    for (final MihonBackupExtensionStore store in stores) {
      final String indexUrl = store.indexUrl.trim();
      if (indexUrl.isEmpty) {
        skipped++;
        continue;
      }
      final String name = store.name.trim().isEmpty ? indexUrl : store.name;
      final String format = _formatOfExtensionStore(store);
      final String contactJson = jsonEncode(<String, String?>{
        'website': store.contactWebsite.trim().isEmpty
            ? null
            : store.contactWebsite.trim(),
        'discord': store.contactDiscord,
      });
      final MangaExtensionStoreRow? current = existing[indexUrl];
      try {
        if (current == null) {
          await database.upsertMangaExtensionStore(
            MangaExtensionStoresCompanion.insert(
              indexUrl: indexUrl,
              name: name,
              format: format,
              badgeLabel: Value<String?>(store.badgeLabel),
              signingKey: Value<String?>(
                store.signingKey.trim().isEmpty ? null : store.signingKey,
              ),
              contactJson: Value<String?>(contactJson),
              extensionListUrl: Value<String?>(store.extensionListUrl),
              sortOrder: Value<int>(nextSortOrder++),
              mediaKind: const Value<String>('manga'),
            ),
          );
          imported++;
        } else {
          // Merge descriptive metadata without dropping fields the backup
          // omits, and keep local sync state (etag / lastModified /
          // lastSyncAt / enabled / sortOrder) intact.
          final bool hasContact =
              store.contactWebsite.trim().isNotEmpty ||
              store.contactDiscord != null;
          final String mergedFormat = store.isLegacy == true
              ? 'legacy'
              : (current.format == 'legacy' ? format : current.format);
          await (database.update(
            database.mangaExtensionStores,
          )..where((t) => t.indexUrl.equals(indexUrl))).write(
            MangaExtensionStoresCompanion(
              name: Value<String>(name),
              format: Value<String>(mergedFormat),
              badgeLabel: Value<String?>(
                store.badgeLabel ?? current.badgeLabel,
              ),
              signingKey: Value<String?>(
                store.signingKey.trim().isEmpty
                    ? current.signingKey
                    : store.signingKey,
              ),
              contactJson: Value<String?>(
                hasContact ? contactJson : current.contactJson,
              ),
              extensionListUrl: Value<String?>(
                store.extensionListUrl ?? current.extensionListUrl,
              ),
            ),
          );
          merged++;
        }
      } on Object {
        failed++;
      }
    }
    return _ExtensionStoreWriteResult(
      imported: imported,
      merged: merged,
      skipped: skipped,
      failed: failed,
    );
  }

  static String _formatOfExtensionStore(MihonBackupExtensionStore store) {
    if (store.isLegacy == true) return 'legacy';
    final String url = store.indexUrl.toLowerCase();
    if (url.endsWith('.pb')) return 'currentProtobuf';
    if (url.endsWith('.json')) return 'currentJson';
    // Unknown suffix: let the first refresh detect the real format. A row is
    // only consulted for cached 304s, which imported rows never have.
    return 'currentJson';
  }

  Future<_SourcePreferenceWriteResult> _importSourcePreferences(
    List<MihonBackupSourcePreferences> containers, {
    required Map<int, MangaOnlineSourceRow> installedBySourceId,
    required Map<int, String> sourceNames,
    required Map<int, _MissingSourceBuilder> missing,
    required int importNow,
  }) async {
    int imported = 0;
    int forMissingSources = 0;
    int skipped = 0;
    int failed = 0;

    for (final MihonBackupSourcePreferences container in containers) {
      final int? sourceId = _sourceIdFromPreferenceKey(container.sourceKey);
      if (sourceId == null) {
        skipped += container.preferences.length;
        continue;
      }
      final MangaOnlineSourceRow? source = installedBySourceId[sourceId];
      // A disabled installed source keeps its real package identity (same as
      // library entries); only a source with no row at all needs the
      // placeholder. Both cases are reported as "install/enable this source".
      final String extensionPackage =
          source?.extensionPackage ?? kUnavailableMihonExtensionPackage;
      final bool sourceMissing = source == null;
      if (sourceMissing || !source.enabled) {
        missing
                .putIfAbsent(
                  sourceId,
                  () => _MissingSourceBuilder(
                    sourceId: sourceId,
                    sourceName: sourceNames[sourceId] ?? 'Source $sourceId',
                  ),
                )
                .preferenceCount +=
            container.preferences.length;
      }

      bool containerFailed = false;
      for (final MihonBackupPreference preference in container.preferences) {
        final String key = preference.key.trim();
        if (key.isEmpty) {
          skipped++;
          continue;
        }
        try {
          await database.upsertMangaSourcePreference(
            MangaSourcePreferencesCompanion.insert(
              extensionPackage: extensionPackage,
              sourceId: '$sourceId',
              preferenceKey: key,
              preferenceType: _preferenceTypeName(preference.value.type),
              valueJson: jsonEncode(preference.value.value),
              updatedAt: importNow,
            ),
          );
          imported++;
          if (sourceMissing) forMissingSources++;
        } on Object {
          failed++;
          containerFailed = true;
        }
      }
      if (!sourceMissing && !containerFailed) {
        // The source is now installed: drop the placeholder rows kept by an
        // earlier import so the same preference never lives twice.
        await database.clearMangaSourcePreferences(
          kUnavailableMihonExtensionPackage,
          '$sourceId',
        );
      }
    }
    return _SourcePreferenceWriteResult(
      imported: imported,
      forMissingSources: forMissingSources,
      skipped: skipped,
      failed: failed,
    );
  }

  static int? _sourceIdFromPreferenceKey(String sourceKey) {
    const String prefix = 'source_';
    if (!sourceKey.startsWith(prefix)) return null;
    return int.tryParse(sourceKey.substring(prefix.length));
  }

  static String _preferenceTypeName(MihonBackupPreferenceType type) =>
      switch (type) {
        MihonBackupPreferenceType.string => 'text',
        MihonBackupPreferenceType.boolean => 'checkBox',
        MihonBackupPreferenceType.stringSet => 'multiSelect',
        MihonBackupPreferenceType.integer ||
        MihonBackupPreferenceType.long ||
        MihonBackupPreferenceType.float ||
        MihonBackupPreferenceType.unsupported => 'unsupported',
      };

  /// Assign every category order in the backup Manga to its resolved Tag.
  ///
  /// Tag assignments use `bookKey` (the key the manga shelf and tag picker use),
  /// so an imported Manga with any Tag leaves the 书架 tab and appears under
  /// each assigned Tag. Assignments upsert by their composite primary key, so
  /// re-importing the same Backup never duplicates a Tag on a Manga; Tags the
  /// user added locally but the Backup does not mention are preserved.
  Future<void> _applyTags({
    required EpubBookRow row,
    required MihonBackupManga manga,
    required Map<int, int> tagIdByCategoryOrder,
  }) async {
    final Set<int> seen = <int>{};
    for (final int order in manga.categoryOrders) {
      final int? tagId = tagIdByCategoryOrder[order];
      if (tagId == null || !seen.add(tagId)) continue;
      await database.addTagToBook(row.bookKey, tagId);
    }
  }

  OnlineMangaLibraryEntry _entryFromBackup(
    MihonBackupManga manga, {
    required String extensionPackage,
  }) {
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
      for (final MihonBackupChapter chapter in manga.chapters)
        if (chapter.url.trim().isNotEmpty) _onlineChapter(chapter),
    ];
    return OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: extensionPackage,
      sourceId: '${manga.source}',
      series: OnlineMangaSeries(
        key: manga.url.trim(),
        title: manga.title,
        coverUrl: manga.thumbnailUrl,
        author: manga.author,
        artist: manga.artist,
        description: manga.description,
        genre: manga.genres.isEmpty ? null : manga.genres.join(', '),
        raw: <String, Object?>{
          'url': manga.url.trim(),
          'title': manga.title,
          'thumbnail_url': manga.thumbnailUrl,
          'artist': manga.artist,
          'author': manga.author,
          'description': manga.description,
          'genre': manga.genres.isEmpty ? null : manga.genres.join(', '),
          'status': manga.status,
          'initialized': true,
        },
      ),
      chapters: List<OnlineMangaChapter>.unmodifiable(chapters),
      currentChapterIndex: _currentChapterIndex(manga),
    );
  }

  OnlineMangaChapter _onlineChapter(MihonBackupChapter chapter) {
    final int uploadedAt = chapter.dateUpload > 0 ? chapter.dateUpload : 0;
    final String chapterUrl = chapter.url.trim();
    return OnlineMangaChapter(
      key: chapterUrl,
      name: chapter.name,
      scanlator: chapter.scanlator,
      number: chapter.chapterNumber == 0 ? null : chapter.chapterNumber,
      uploadedAt: uploadedAt == 0 ? null : uploadedAt,
      locked: OnlineMangaChapter.isLockedChapterName(chapter.name),
      raw: <String, Object?>{
        'url': chapterUrl,
        'name': chapter.name,
        'date_upload': uploadedAt,
        'chapter_number': chapter.chapterNumber,
        'scanlator': chapter.scanlator,
        // User state has no column in the manga-only schema; keep it on the
        // chapter payload so a later re-export/refresh does not lose it.
        if (chapter.read) 'read': true,
        if (chapter.bookmark) 'bookmark': true,
        if (chapter.lastPageRead > 0) 'last_page_read': chapter.lastPageRead,
        if (chapter.dateFetch > 0) 'date_fetch': chapter.dateFetch,
      },
    );
  }

  /// Merge one backup chapter into the local descriptor. Local values win;
  /// the backup only fills gaps and merges monotonic user state (read,
  /// bookmark, furthest page), matching Mihon's restore semantics.
  OnlineMangaChapter _mergeChapter(
    OnlineMangaChapter local,
    MihonBackupChapter backup,
  ) {
    final Map<String, Object?> raw = Map<String, Object?>.of(local.raw);
    bool changed = false;
    bool put(String key, Object? value, {bool onlyIfAbsent = false}) {
      if (onlyIfAbsent && raw[key] != null && raw[key] != 0) return false;
      if (raw[key] == value) return false;
      raw[key] = value;
      return true;
    }

    if (backup.read && raw['read'] != true) {
      raw['read'] = true;
      changed = true;
    }
    if (backup.bookmark && raw['bookmark'] != true) {
      raw['bookmark'] = true;
      changed = true;
    }
    final int knownPage = (raw['last_page_read'] as num?)?.toInt() ?? 0;
    if (backup.lastPageRead > knownPage) {
      raw['last_page_read'] = backup.lastPageRead;
      changed = true;
    }
    if (backup.dateFetch > 0) {
      changed =
          put('date_fetch', backup.dateFetch, onlyIfAbsent: true) || changed;
    }

    final String? scanlator = local.scanlator ?? backup.scanlator;
    if (scanlator != local.scanlator) changed = true;
    final double? number =
        local.number ??
        (backup.chapterNumber != 0 ? backup.chapterNumber : null);
    if (number != local.number) changed = true;
    final int? uploadedAt =
        local.uploadedAt ?? (backup.dateUpload > 0 ? backup.dateUpload : null);
    if (uploadedAt != local.uploadedAt) {
      changed = true;
      if (uploadedAt != null) raw['date_upload'] = uploadedAt;
    }
    if (scanlator != null) {
      changed = put('scanlator', scanlator, onlyIfAbsent: true) || changed;
    }
    if (number != null) {
      changed = put('chapter_number', number, onlyIfAbsent: true) || changed;
    }
    final String name = local.name.isEmpty ? backup.name : local.name;
    if (name != local.name) {
      changed = true;
      raw['name'] = name;
    }
    if (!changed) return local;

    return OnlineMangaChapter(
      key: local.key,
      name: name,
      raw: raw,
      scanlator: scanlator,
      number: number,
      uploadedAt: uploadedAt,
      locked: local.locked,
    );
  }

  /// Index of the chapter with the newest history entry (Mihon's "last read").
  /// Null lets the reader fall back to its own "oldest chapter" default.
  int? _currentChapterIndex(MihonBackupManga manga) {
    int? bestIndex;
    int bestAt = -1;
    for (int index = 0; index < manga.chapters.length; index++) {
      final String url = manga.chapters[index].url;
      for (final MihonBackupHistory history in manga.history) {
        if (history.url == url && history.lastRead > bestAt) {
          bestAt = history.lastRead;
          bestIndex = index;
        }
      }
    }
    return bestIndex;
  }

  static String? _bylineOf(MihonBackupManga manga) {
    final String? author = manga.author?.trim();
    if (author != null && author.isNotEmpty) return author;
    final String? artist = manga.artist?.trim();
    if (artist != null && artist.isNotEmpty) return artist;
    return null;
  }

  static String _chaptersJson(List<OnlineMangaChapter> chapters) =>
      jsonEncode(<Map<String, Object?>>[
        for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
      ]);
}

class _ExistingEntry {
  const _ExistingEntry({required this.row, required this.entry});

  final EpubBookRow row;
  final OnlineMangaLibraryEntry? entry;
}

/// App settings resolved before the import writes anything.
class _AppPreferencePlan {
  const _AppPreferencePlan({
    required this.values,
    required this.skippedByReason,
  });

  /// `preferences` rows to fill, already encoded with [PrefCodec].
  final Map<String, String> values;
  final Map<MihonBackupAppPreferenceSkipReason, int> skippedByReason;
}

class _MissingSourceBuilder {
  _MissingSourceBuilder({required this.sourceId, required this.sourceName});

  final int sourceId;
  final String sourceName;
  int entryCount = 0;
  int preferenceCount = 0;

  MihonBackupSourceIssue build() => MihonBackupSourceIssue(
    sourceId: sourceId,
    sourceName: sourceName,
    entryCount: entryCount,
    preferenceCount: preferenceCount,
  );
}

class _TrackingWriteResult {
  const _TrackingWriteResult({
    required this.imported,
    required this.merged,
    required this.skipped,
    required this.invalidRemoteIds,
    required this.skippedByTracker,
  });

  final int imported;
  final int merged;
  final int skipped;
  final int invalidRemoteIds;
  final Map<int, int> skippedByTracker;
}

class _ExtensionStoreWriteResult {
  const _ExtensionStoreWriteResult({
    required this.imported,
    required this.merged,
    required this.skipped,
    required this.failed,
  });

  final int imported;
  final int merged;
  final int skipped;
  final int failed;
}

class _SourcePreferenceWriteResult {
  const _SourcePreferenceWriteResult({
    required this.imported,
    required this.forMissingSources,
    required this.skipped,
    required this.failed,
  });

  final int imported;
  final int forMissingSources;
  final int skipped;
  final int failed;
}
