part of 'mihon_backup_exporter.dart';

/// 「所有已读作品」: read online works that are not in the Library, exported
/// as `favorite=false` so Mihon keeps their reading history without adding
/// them to the shelf.
class _ReadOnlyExportSection {
  const _ReadOnlyExportSection();

  /// Library works are excluded by history identity and by (Source, URL): the
  /// Library row and its History row can carry different identities after a
  /// backup import or an extension-package change. Snapshot data without a
  /// chapter URL exports metadata only — no chapters or history links are
  /// invented.
  List<MihonBackupManga> mangas({
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
      final String historyKey = MangaHistoryIdentity(
        row.mediaSource,
        row.mediaId,
      ).key;
      if (library.historyKeys.contains(historyKey)) continue;

      final Map<String, Object?>? rawSnapshot = _snapshotJson(row.snapshotJson);
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
      final String title = _firstNonEmpty(<String?>[
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
      final MangaHistoryMihonEntry? mihonHistory =
          snapshot?.mihonHistory ??
          mangaHistoryMihonEntryFromJson(row.snapshotJson);
      final String? chapterUrl = mihonHistory?.chapterUrl;

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
                    readDuration: mihonHistory?.readDuration ?? 0,
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
        MangaHistoryIdentity(
          MangaMyComicSource.kUniqueKey,
          readerBookMediaIdentifierFor(row.bookKey),
        ).key,
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
