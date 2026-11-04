import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';

import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 占位 extension package：备份里的 Source 尚未安装时，书架条目仍要有一个稳定
/// 身份，否则每次导入都会因为 package 不同而新建一行。
///
/// 已知限制（后续 ticket 收口）：扩展安装后 `MihonLibraryAdapter` 用真实 package
/// 匹配源，本条目的身份不会自动改写；「安装缺失源后接管备份条目」不在 ticket 06
/// 的最小路径内。
const String kUnavailableMihonExtensionPackage = 'mihon.unavailable';

enum MihonBackupSkipReason { notInLibrary }

enum MihonBackupFailureReason { missingUrl, databaseError }

class MihonBackupSourceIssue {
  const MihonBackupSourceIssue({
    required this.sourceId,
    required this.sourceName,
    required this.entryCount,
  });

  final int sourceId;
  final String sourceName;
  final int entryCount;
}

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
    required this.chapterStatesWritten,
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

  /// Entries intentionally not imported (Mihon "read, not in library" rows).
  final int skippedEntries;

  final int failedEntries;
  final int categoriesCreated;
  final int categoriesMatched;

  /// Chapter progress rows written or merged (read + partially read + history).
  final int chapterStatesWritten;

  final Map<MihonBackupSkipReason, int> skippedByReason;
  final Map<MihonBackupFailureReason, int> failedByReason;

  /// Sources from the backup that are not installed (or disabled) on this
  /// machine. Their entries are still imported and open as "source unavailable"
  /// until the extension is installed.
  final List<MihonBackupSourceIssue> missingSources;

  final Duration elapsed;

  bool get isEmpty => totalEntries == 0;

  int get successfulEntries => importedEntries + mergedEntries;
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

    // Categories are resolved by *order*, matching Mihon's restore behavior:
    // BackupManga.categories stores order values, not category ids.
    final Map<int, MihonBackupCategory> categoriesByOrder =
        <int, MihonBackupCategory>{
          for (final MihonBackupCategory category in data.categories)
            if (category.name.trim().isNotEmpty) category.order: category,
        };

    final Map<String, int> collectionsByName = <String, int>{
      for (final MediaCollectionRow collection
          in await database.getAllMediaCollections())
        collection.name: collection.id,
    };
    int categoriesCreated = 0;
    int categoriesMatched = 0;
    for (final MihonBackupCategory category in data.categories) {
      final String name = category.name.trim();
      if (name.isEmpty) continue;
      final int? existingId = collectionsByName[name];
      if (existingId != null) {
        categoriesMatched++;
        continue;
      }
      final int id = await database.createMediaCollection(name);
      collectionsByName[name] = id;
      categoriesCreated++;
    }

    final Map<String, _ExistingEntry> existing = await _loadExistingEntries();
    final Map<int, _MissingSourceBuilder> missing =
        <int, _MissingSourceBuilder>{};
    final Map<MihonBackupSkipReason, int> skippedByReason =
        <MihonBackupSkipReason, int>{};
    final Map<MihonBackupFailureReason, int> failedByReason =
        <MihonBackupFailureReason, int>{};
    int imported = 0;
    int merged = 0;
    int skipped = 0;
    int failed = 0;
    int chapterStatesWritten = 0;

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
          skippedByReason.update(
            MihonBackupSkipReason.notInLibrary,
            (int value) => value + 1,
            ifAbsent: () => 1,
          );
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
          await _applyCategories(
            row: row,
            manga: manga,
            categoriesByOrder: categoriesByOrder,
            collectionsByName: collectionsByName,
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
      chapterStatesWritten: chapterStatesWritten,
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
    bool added = false;
    for (final MihonBackupChapter chapter in manga.chapters) {
      final String key = chapter.url.trim();
      if (key.isEmpty || byKey.containsKey(key)) continue;
      byKey[key] = _onlineChapter(chapter);
      added = true;
    }
    if (!added) return duplicate.row;

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
    for (final MihonBackupChapter chapter in manga.chapters) {
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
    }
    return written;
  }

  Future<void> _applyCategories({
    required EpubBookRow row,
    required MihonBackupManga manga,
    required Map<int, MihonBackupCategory> categoriesByOrder,
    required Map<String, int> collectionsByName,
  }) async {
    final Set<int> seen = <int>{};
    for (final int order in manga.categoryOrders) {
      final MihonBackupCategory? category = categoriesByOrder[order];
      if (category == null) continue;
      final int? collectionId = collectionsByName[category.name.trim()];
      if (collectionId == null || !seen.add(collectionId)) continue;
      await database.addToCollection(collectionId, MediaKind.epub, row.uid);
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
      number: chapter.chapterNumber,
      uploadedAt: uploadedAt == 0 ? null : uploadedAt,
      locked: OnlineMangaChapter.isLockedChapterName(chapter.name),
      raw: <String, Object?>{
        'url': chapterUrl,
        'name': chapter.name,
        'date_upload': uploadedAt,
        'chapter_number': chapter.chapterNumber,
        'scanlator': chapter.scanlator,
      },
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

class _MissingSourceBuilder {
  _MissingSourceBuilder({required this.sourceId, required this.sourceName});

  final int sourceId;
  final String sourceName;
  int entryCount = 0;

  MihonBackupSourceIssue build() => MihonBackupSourceIssue(
    sourceId: sourceId,
    sourceName: sourceName,
    entryCount: entryCount,
  );
}
