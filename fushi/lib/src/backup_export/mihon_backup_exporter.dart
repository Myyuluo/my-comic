import 'dart:io';

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/backup_export/mihon_backup_writer.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// Which Mihon backup sections the user asked for.
///
/// Ticket 07 ships Library + Chapters; later tickets add History, categories,
/// tracking, app settings, extension stores and source settings. The page owns
/// the dependency rules; the exporter only honours the resolved options.
class MihonBackupExportOptions {
  const MihonBackupExportOptions({
    this.includeLibrary = true,
    this.includeChapters = true,
  });

  /// 「书架中的作品」: export Library manga as `favorite=true`.
  final bool includeLibrary;

  /// 「章节」: export each manga's chapter list (read state, progress, dates).
  final bool includeChapters;

  /// Whether the resolved selection produces a non-empty backup. Later tickets
  /// add the standalone categories / settings sections here.
  bool get hasExportableContent => includeLibrary;
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
          tracking: const <MihonBackupTracking>[],
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
