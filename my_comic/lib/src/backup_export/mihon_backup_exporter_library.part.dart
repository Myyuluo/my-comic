part of 'mihon_backup_exporter.dart';

/// 「书架中的作品」/「章节」/「历史」/「进度记录」 loaders.
class _LibraryExportSection {
  const _LibraryExportSection(this.database);

  final MyComicDatabase database;

  /// Library rows that a `.tachibk` can represent. Local-source rows and
  /// imported manga volumes have no Mihon Source ID / manga URL.
  List<_ExportableManga> exportableManga(List<EpubBookRow> rows) {
    final List<_ExportableManga> exportable = <_ExportableManga>[];
    for (final EpubBookRow row in rows) {
      if (row.format != BookFormat.manga.dbValue) continue;
      final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      );
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
  loadChapterStates() async {
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

  Future<List<MediaOpenHistoryRow>> loadHistoryRows() =>
      database.select(database.mediaOpenHistory).get();

  /// Every History row keyed by its identity (`source\0id`), keeping the newest
  /// row when both the current online identity and the legacy import identity
  /// describe the same Manga.
  Map<String, MediaOpenHistoryRow> historyRowsByKey(
    List<MediaOpenHistoryRow> rows,
  ) {
    final Map<String, MediaOpenHistoryRow> byKey =
        <String, MediaOpenHistoryRow>{};
    for (final MediaOpenHistoryRow row in rows) {
      final String key = MangaHistoryIdentity(row.mediaSource, row.mediaId).key;
      final MediaOpenHistoryRow? existing = byKey[key];
      if (existing == null || row.openedAt >= existing.openedAt) {
        byKey[key] = row;
      }
    }
    return byKey;
  }

  /// The most recent History row of a Library Manga. Reader sessions write the
  /// current online identity; backups imported by earlier versions wrote the
  /// legacy book-key identity, and both must keep round-tripping.
  MediaOpenHistoryRow? historyRowFor(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
    Map<String, MediaOpenHistoryRow> historyByKey,
  ) {
    final MangaHistoryIdentity identity = mangaHistoryIdentityForOnline(entry);
    final MediaOpenHistoryRow? current = historyByKey[identity.key];
    if (current != null) return current;
    final String legacyKey = MangaHistoryIdentity(
      MangaMyComicSource.kUniqueKey,
      readerBookMediaIdentifierFor(row.bookKey),
    ).key;
    return historyByKey[legacyKey];
  }

  /// Mihon stores History per chapter. A MyComic History row only knows the
  /// Manga and its open time, so the chapter comes from the typed Mihon block
  /// in the snapshot when available and otherwise from the most recently
  /// touched chapter state. If neither exists there is no honest chapter URL.
  MihonBackupHistory? libraryHistory({
    required EpubBookRow row,
    required OnlineMangaLibraryEntry entry,
    required Map<String, MangaChapterStateRow> states,
    required Map<String, MediaOpenHistoryRow> historyByKey,
  }) {
    final MediaOpenHistoryRow? history = historyRowFor(
      row,
      entry,
      historyByKey,
    );
    if (history == null) return null;
    final MangaHistoryMihonEntry? mihonHistory = mangaHistoryMihonEntryFromJson(
      history.snapshotJson,
    );
    final String? chapterUrl =
        mihonHistory?.chapterUrl ?? _recentChapterKey(entry, states);
    if (chapterUrl == null || chapterUrl.isEmpty) return null;
    return MihonBackupHistory(
      url: chapterUrl,
      lastRead: history.openedAt,
      readDuration: mihonHistory?.readDuration ?? 0,
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

  /// Loads the Bangumi Tracking records stored for Library manga, keyed by the
  /// book key that also identifies the Manga row.
  ///
  /// MyComic has no tracker rows other than `provider = bangumi`, and Mihon
  /// trackers it cannot represent are never written here, so nothing is
  /// fabricated for unsupported providers.
  Future<Map<String, MihonBackupTracking>> loadTrackingByBook() async {
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
          for (final MediaTrackingOutboxRow outbox in await (database.select(
            database.mediaTrackingOutbox,
          )..where((t) => t.mappingId.isIn(mappingIds))).get())
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

  Future<Map<int, String>> knownSourceNames() async {
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

  List<MihonBackupChapter> backupChapters(
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
          // 导入时持久化的 Mihon sourceOrder 必须原样导出；在线条目的
          // sourceOrder 就是列表下标，旧数据缺失时同样回退下标。
          sourceOrder: chapter.sourceOrder ?? index,
        ),
      );
    }
    return chapters;
  }

  static int statusOf(OnlineMangaLibraryEntry entry) =>
      (entry.series.raw['status'] as num?)?.toInt() ?? 0;
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
