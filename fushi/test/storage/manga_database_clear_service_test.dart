import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

/// Ticket 13：「清理数据库」的服务层。
///
/// 用真实内存库覆盖：按 Source 列出非书架作品、多选删除、默认保留有阅读记录的
/// 作品、只删除被清理作品的 History、保留书架作品/History/设置/源/磁盘文件，
/// 以及孤儿阅读记录的次要清理。
void main() {
  late FushiDatabase db;
  late Directory tmp;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('manga_database_clear_');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String onlineMetadata({
    String extensionPackage = 'org.example.a',
    String sourceId = '101',
    required String seriesKey,
    String title = 'Series',
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: extensionPackage,
    sourceId: sourceId,
    series: OnlineMangaSeries(
      key: seriesKey,
      title: title,
      raw: const <String, Object?>{},
    ),
    chapters: const <OnlineMangaChapter>[],
  ).encode();

  Future<EpubBookRow> insertBook({
    required String bookKey,
    bool inLibrary = true,
    String format = 'manga',
    String? sourceMetadata,
    DateTime? completedAt,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: bookKey,
        epubPath: '',
        extractDir: p.join(tmp.path, bookKey),
        chapterCount: 2,
        chaptersJson: '[]',
        importedAt: 1,
        format: Value<String>(format),
        inLibrary: Value<bool>(inLibrary),
        sourceMetadata: Value<String?>(sourceMetadata),
        completedAt: Value<DateTime?>(completedAt),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  Future<void> insertHistory(
    String mediaSource,
    String mediaId, {
    String snapshotJson = '{}',
  }) => db.upsertMediaOpenHistory(
    MediaOpenHistoryCompanion(
      mediaType: const Value<String>('reader_media_type'),
      mediaSource: Value<String>(mediaSource),
      mediaId: Value<String>(mediaId),
      openedAt: const Value<int>(1),
      position: const Value<int>(0),
      duration: const Value<int>(0),
      snapshotJson: Value<String>(snapshotJson),
    ),
  );

  Future<void> insertOnlineHistory(EpubBookRow book) async {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      book.sourceMetadata,
    )!;
    final MangaHistoryIdentity identity = mangaHistoryIdentityForOnline(entry);
    await insertHistory(identity.mediaSource, identity.mediaId);
  }

  Future<void> insertLegacyHistory(EpubBookRow book) =>
      insertHistory('reader_manga', 'fushi://book/${book.bookKey}');

  String onlineHistoryKey(EpubBookRow book) {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      book.sourceMetadata,
    )!;
    return mangaHistoryIdentityForOnline(entry).key;
  }

  Future<void> seedChapterState(
    EpubBookRow book, {
    bool read = false,
    int lastPage = 0,
  }) => db
      .into(db.mangaChapterStates)
      .insert(
        MangaChapterStatesCompanion.insert(
          bookUid: book.uid,
          chapterKey: 'c1',
          updatedAt: 10,
          readAt: Value<int?>(read ? 99 : null),
          lastPage: Value<int>(lastPage),
        ),
      );

  Future<void> seedPosition(EpubBookRow book, {int sectionIndex = 0}) => db
      .into(db.readerPositions)
      .insert(
        ReaderPositionsCompanion.insert(
          bookUid: book.uid,
          sectionIndex: sectionIndex,
          normCharOffset: 0,
          updatedAt: 10,
        ),
      );

  Future<void> insertSource({
    required String extensionPackage,
    required String sourceId,
    required String name,
  }) => db
      .into(db.mangaOnlineSources)
      .insert(
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: extensionPackage,
          sourceId: sourceId,
          name: name,
          language: 'zh',
        ),
      );

  MangaDatabaseClearService service() =>
      MangaDatabaseClearService(database: db);

  test('按 Source 列出非书架作品数与有阅读记录的作品数', () async {
    await insertSource(
      extensionPackage: 'org.example.a',
      sourceId: '101',
      name: 'Source A',
    );
    await insertSource(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      name: 'Source B',
    );

    final String metaB = onlineMetadata(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      seriesKey: '/b',
    );
    final String metaLocal = const LocalSourceMetadata(
      relativePath: 'Local/Series',
    ).encode();

    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      sourceMetadata: onlineMetadata(seriesKey: '/library'),
    );
    final EpubBookRow aRead = await insertBook(
      bookKey: 'a-read',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-read'),
    );
    final EpubBookRow aProgress = await insertBook(
      bookKey: 'a-progress',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-progress'),
    );
    final EpubBookRow aUnread = await insertBook(
      bookKey: 'a-unread',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-unread'),
    );
    final EpubBookRow bUnread = await insertBook(
      bookKey: 'b-unread',
      inLibrary: false,
      sourceMetadata: metaB,
    );
    await insertBook(
      bookKey: 'local',
      inLibrary: false,
      sourceMetadata: metaLocal,
    );
    final EpubBookRow imported = await insertBook(
      bookKey: 'imported',
      inLibrary: false,
    );
    await insertBook(bookKey: 'epub-hidden', inLibrary: false, format: 'epub');

    await seedChapterState(aRead, read: true);
    await seedPosition(aProgress, sectionIndex: 3);
    await seedChapterState(library, read: true);

    await insertOnlineHistory(aRead);
    await insertOnlineHistory(aProgress);
    await insertOnlineHistory(aUnread);
    await insertLegacyHistory(aUnread);
    await insertOnlineHistory(bUnread);
    await insertHistory(kMangaHistoryLocalSource, 'Local/Series');
    await insertLegacyHistory(imported);
    await insertOnlineHistory(library);

    final List<MangaDatabaseClearSource> sources = await service()
        .measureSources();

    expect(sources, hasLength(4), reason: 'epub 行与书架行都不是清理对象');

    final MangaDatabaseClearSource sourceA = sources.singleWhere(
      (MangaDatabaseClearSource source) => source.name == 'Source A',
    );
    expect(sourceA.kind, MangaDatabaseClearSourceKind.online);
    expect(sourceA.nonLibraryWorks, 3);
    expect(sourceA.readWorks, 2, reason: '已读章节与阅读进度都算有阅读记录');
    expect(
      sourceA.historyEntries,
      4,
      reason: 'a-read / a-progress / a-unread 的 canonical 历史 + a-unread 的旧身份',
    );
    expect(sourceA.readHistoryEntries, 2);
    expect(sourceA.worksToDelete(keepRead: true), 1);
    expect(sourceA.worksToDelete(keepRead: false), 3);
    expect(sourceA.historyToDelete(keepRead: true), 2);
    expect(sourceA.historyToDelete(keepRead: false), 4);

    final MangaDatabaseClearSource sourceB = sources.singleWhere(
      (MangaDatabaseClearSource source) => source.name == 'Source B',
    );
    expect(sourceB.nonLibraryWorks, 1);
    expect(sourceB.readWorks, 0);
    expect(sourceB.historyEntries, 1);

    final MangaDatabaseClearSource localSource = sources.singleWhere(
      (MangaDatabaseClearSource source) =>
          source.kind == MangaDatabaseClearSourceKind.localSource,
    );
    expect(localSource.nonLibraryWorks, 1);
    expect(localSource.readWorks, 0);
    expect(localSource.historyEntries, 1);

    final MangaDatabaseClearSource importedSource = sources.singleWhere(
      (MangaDatabaseClearSource source) =>
          source.kind == MangaDatabaseClearSourceKind.imported,
    );
    expect(importedSource.nonLibraryWorks, 1);
    expect(importedSource.historyEntries, 1);

    // 书架作品与其它非书架作品的计数互不串源。
    expect(
      sources.fold<int>(
        0,
        (int total, MangaDatabaseClearSource source) =>
            total + source.nonLibraryWorks,
      ),
      6,
    );
  });

  test('没有非书架漫画时返回空列表', () async {
    await insertBook(bookKey: 'library');
    expect(await service().measureSources(), isEmpty);
  });

  /// 作品名下的记录级联目标：阅读覆盖、下载任务、章节容器映射。
  Future<void> seedOwnedRows(EpubBookRow book) async {
    await db
        .into(db.mangaReaderOverrides)
        .insert(
          MangaReaderOverridesCompanion.insert(
            bookUid: book.uid,
            updatedAt: 10,
            overridesJson: const Value<String>('{"readingMode":"spread"}'),
          ),
        );
    await db
        .into(db.mangaDownloadJobs)
        .insert(
          MangaDownloadJobsCompanion.insert(
            jobId: 'job-${book.bookKey}',
            kind: 'chapter',
            bookKey: book.bookKey,
            chapterKey: 'c1',
            runtime: 'mihon',
            title: book.title,
            chapterTitle: 'Chapter 1',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    await db
        .into(db.mangaChapterDirs)
        .insert(
          MangaChapterDirsCompanion.insert(
            bookKey: book.bookKey,
            chapterKey: 'c1',
            folderName: 'c1',
            updatedAt: 1,
          ),
        );
  }

  Future<void> insertOrphanReadingRecords() async {
    await db
        .into(db.readerPositions)
        .insert(
          ReaderPositionsCompanion.insert(
            bookUid: 'ghost-uid',
            sectionIndex: 1,
            normCharOffset: 0,
            updatedAt: 10,
          ),
        );
    await db
        .into(db.mangaChapterStates)
        .insert(
          MangaChapterStatesCompanion.insert(
            bookUid: 'ghost-uid',
            chapterKey: 'ghost-chapter',
            updatedAt: 10,
          ),
        );
  }

  Future<void> seedPreservedOtherData() async {
    await db
        .into(db.searchHistoryItems)
        .insert(
          SearchHistoryItemsCompanion.insert(
            historyKey: 'manga',
            searchTerm: 'kept search',
            uniqueKey: 'manga\u0000kept search',
          ),
        );
    await db
        .into(db.mediaSources)
        .insert(
          MediaSourcesCompanion.insert(
            label: 'Kept source',
            mediaKind: 'book',
            rootPath: p.join(tmp.path, 'source-root'),
            createdAt: 1,
          ),
        );
    await db
        .into(db.mediaTrackingMappings)
        .insert(
          MediaTrackingMappingsCompanion.insert(
            mediaType: 'manga',
            mediaKey: 'library',
            mediaTitle: 'library',
            kind: 'manga',
            subjectId: 42,
            subjectName: 'Kept tracking',
            progressMode: 'chapter',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
  }

  test('默认保留有阅读记录的作品；只删所选 Source 的未读作品与其 History', () async {
    await insertSource(
      extensionPackage: 'org.example.a',
      sourceId: '101',
      name: 'Source A',
    );
    await insertSource(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      name: 'Source B',
    );
    final String metaB = onlineMetadata(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      seriesKey: '/b',
    );

    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      sourceMetadata: onlineMetadata(seriesKey: '/library'),
    );
    final EpubBookRow aRead = await insertBook(
      bookKey: 'a-read',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-read'),
    );
    final EpubBookRow aProgress = await insertBook(
      bookKey: 'a-progress',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-progress'),
    );
    final EpubBookRow aUnread = await insertBook(
      bookKey: 'a-unread',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-unread'),
    );
    final EpubBookRow bUnread = await insertBook(
      bookKey: 'b-unread',
      inLibrary: false,
      sourceMetadata: metaB,
    );
    final EpubBookRow local = await insertBook(
      bookKey: 'local',
      inLibrary: false,
      sourceMetadata: const LocalSourceMetadata(
        relativePath: 'Local/Series',
      ).encode(),
    );
    final EpubBookRow imported = await insertBook(
      bookKey: 'imported',
      inLibrary: false,
    );

    await seedChapterState(aRead, read: true);
    await seedPosition(aProgress, sectionIndex: 3);
    await seedChapterState(aUnread);
    await seedChapterState(library, read: true);
    await seedOwnedRows(aRead);
    await seedOwnedRows(aUnread);
    await seedOwnedRows(library);

    await insertOnlineHistory(aRead);
    await insertOnlineHistory(aProgress);
    await insertOnlineHistory(aUnread);
    await insertLegacyHistory(aUnread);
    await insertOnlineHistory(bUnread);
    await insertHistory(kMangaHistoryLocalSource, 'Local/Series');
    await insertLegacyHistory(imported);
    await insertOnlineHistory(library);
    await insertOrphanReadingRecords();
    await seedPreservedOtherData();

    final File downloadFile = File(
      p.join(tmp.path, 'downloads', 'Source', 'Series', 'ch1.cbz'),
    )..createSync(recursive: true);
    downloadFile.writeAsBytesSync(const <int>[1, 2, 3]);
    final File localPage = File(
      p.join(tmp.path, 'local', 'Series', 'ch1', '001.jpg'),
    )..createSync(recursive: true);
    localPage.writeAsBytesSync(const <int>[4, 5, 6]);

    final List<MangaDatabaseClearSource> sources = await service()
        .measureSources();
    final String sourceAKey = sources
        .singleWhere(
          (MangaDatabaseClearSource source) => source.name == 'Source A',
        )
        .key;

    final List<MangaDatabaseClearStep> steps = <MangaDatabaseClearStep>[];
    final MangaDatabaseClearCounts report = await service().run(
      sourceKeys: <String>{sourceAKey},
      onProgress: (MangaDatabaseClearProgress progress) =>
          steps.add(progress.step),
    );

    expect(report.works, 1);
    expect(report.historyEntries, 2, reason: 'canonical + 旧 reader_manga 身份');
    expect(report.readingStateRows, 2, reason: '只统计清理后仍无归属的孤儿行');
    expect(steps, <MangaDatabaseClearStep>[
      MangaDatabaseClearStep.works,
      MangaDatabaseClearStep.history,
      MangaDatabaseClearStep.readingState,
    ]);

    // 所选 Source 中：未读作品删除，读过的作品与阅读进度保留。
    expect(await db.getEpubBook(aUnread.bookKey), isNull);
    for (final EpubBookRow kept in <EpubBookRow>[
      aRead,
      aProgress,
      bUnread,
      local,
      imported,
      library,
    ]) {
      expect(await db.getEpubBook(kept.bookKey), isNotNull);
    }

    // 实读作品的阅读状态与下载索引保留；删除作品的级联记录消失。
    final List<MangaChapterStateRow> states = await db
        .select(db.mangaChapterStates)
        .get();
    expect(
      states.map((MangaChapterStateRow row) => row.bookUid),
      containsAll(<String>[aRead.uid, library.uid]),
    );
    expect(
      states.map((MangaChapterStateRow row) => row.bookUid),
      isNot(contains('ghost-uid')),
    );
    expect(
      await db.select(db.readerPositions).get(),
      hasLength(1),
      reason: 'aProgress 的阅读位置保留，孤儿位置清掉',
    );
    expect(
      await (db.select(
        db.mangaReaderOverrides,
      )..where((t) => t.bookUid.equals(aUnread.uid))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.mangaDownloadJobs,
      )..where((t) => t.bookKey.equals(aUnread.bookKey))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.mangaChapterDirs,
      )..where((t) => t.bookKey.equals(aUnread.bookKey))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.mangaDownloadJobs,
      )..where((t) => t.bookKey.equals(aRead.bookKey))).get(),
      hasLength(1),
    );
    expect(
      await (db.select(
        db.mangaChapterDirs,
      )..where((t) => t.bookKey.equals(aRead.bookKey))).get(),
      hasLength(1),
    );

    // 只删被清理作品的 History：书架 / 保留的非书架作品 / 其它 Source 都在。
    final List<MediaOpenHistoryRow> history = await db
        .select(db.mediaOpenHistory)
        .get();
    final Set<String> historyKeys = <String>{
      for (final MediaOpenHistoryRow row in history)
        '${row.mediaSource}\u0000${row.mediaId}',
    };
    expect(historyKeys, contains(onlineHistoryKey(aRead)));
    expect(historyKeys, isNot(contains(onlineHistoryKey(aUnread))));
    expect(historyKeys, contains(onlineHistoryKey(library)));
    expect(
      history,
      hasLength(6),
      reason: 'aRead/aProgress/b/local/imported/library',
    );

    // 设置、源、扩展、Tracking 与磁盘文件全部保留。
    expect(await db.select(db.searchHistoryItems).get(), hasLength(1));
    expect(await db.select(db.mediaSources).get(), hasLength(1));
    expect(await db.select(db.mediaTrackingMappings).get(), hasLength(1));
    expect(downloadFile.existsSync(), isTrue, reason: '不删除下载库文件');
    expect(localPage.existsSync(), isTrue, reason: '不删除本地图源文件');
  });

  test(
    '按快照 bookKey 解析到被清理作品的 History 也删除，书架作品的快照行保留',
    () async {
      await insertSource(
        extensionPackage: 'org.example.a',
        sourceId: '101',
        name: 'Source A',
      );
      final EpubBookRow removed = await insertBook(
        bookKey: 'removed-snapshot',
        inLibrary: false,
        sourceMetadata: onlineMetadata(seriesKey: '/removed'),
      );
      final EpubBookRow library = await insertBook(
        bookKey: 'kept-snapshot',
        sourceMetadata: onlineMetadata(seriesKey: '/kept'),
      );
      // 旧导入 / 旧扩展包身份无法命中 canonical，但快照 bookKey 能解析到
      // 对应作品（loadMangaHistory 的同一条回退规则）。
      final String removedKey = 'manga_online:["mihon","org.old","101"]'
          '\u0000/removed';
      final String keptKey = 'manga_online:["mihon","org.old","101"]'
          '\u0000/kept';
      await insertHistory(
        'manga_online:["mihon","org.old","101"]',
        '/removed',
        snapshotJson: jsonEncode(
          MangaHistorySnapshot(
            title: 'Removed',
            bookKey: removed.bookKey,
          ).toJson(),
        ),
      );
      await insertHistory(
        'manga_online:["mihon","org.old","101"]',
        '/kept',
        snapshotJson: jsonEncode(
          MangaHistorySnapshot(
            title: 'Kept',
            bookKey: library.bookKey,
          ).toJson(),
        ),
      );

      final List<MangaDatabaseClearSource> sources = await service()
          .measureSources();
      expect(
        sources.single.historyEntries,
        1,
        reason: '快照 bookKey 命中的被清理作品 History 计入数量',
      );

      final MangaDatabaseClearCounts report = await service().run(
        sourceKeys: <String>{sources.single.key},
        keepRead: false,
      );
      expect(report.works, 1);
      expect(report.historyEntries, 1, reason: '只删除被清理作品的快照 History');

      final Set<String> remaining = <String>{
        for (final MediaOpenHistoryRow row
            in await db.select(db.mediaOpenHistory).get())
          '${row.mediaSource}\u0000${row.mediaId}',
      };
      expect(remaining, isNot(contains(removedKey)));
      expect(remaining, contains(keptKey), reason: '书架作品的 History 保留');
    },
  );

  test('关闭保留开关时删除所选 Source 的全部非书架作品与 History', () async {
    await insertSource(
      extensionPackage: 'org.example.a',
      sourceId: '101',
      name: 'Source A',
    );
    await insertSource(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      name: 'Source B',
    );
    final String metaB = onlineMetadata(
      extensionPackage: 'org.example.b',
      sourceId: '102',
      seriesKey: '/b',
    );

    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      sourceMetadata: onlineMetadata(seriesKey: '/library'),
    );
    final EpubBookRow aRead = await insertBook(
      bookKey: 'a-read',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-read'),
    );
    final EpubBookRow aProgress = await insertBook(
      bookKey: 'a-progress',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-progress'),
    );
    final EpubBookRow aUnread = await insertBook(
      bookKey: 'a-unread',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/a-unread'),
    );
    final EpubBookRow bUnread = await insertBook(
      bookKey: 'b-unread',
      inLibrary: false,
      sourceMetadata: metaB,
    );
    final EpubBookRow local = await insertBook(
      bookKey: 'local',
      inLibrary: false,
      sourceMetadata: const LocalSourceMetadata(
        relativePath: 'Local/Series',
      ).encode(),
    );

    await seedChapterState(aRead, read: true);
    await seedPosition(aProgress, sectionIndex: 3);
    await seedChapterState(aUnread);
    await seedChapterState(library, read: true);

    await insertOnlineHistory(aRead);
    await insertOnlineHistory(aProgress);
    await insertOnlineHistory(aUnread);
    await insertLegacyHistory(aUnread);
    await insertOnlineHistory(bUnread);
    await insertHistory(kMangaHistoryLocalSource, 'Local/Series');
    await insertOnlineHistory(library);
    await insertOrphanReadingRecords();
    await seedPreservedOtherData();

    final List<MangaDatabaseClearSource> sources = await service()
        .measureSources();
    final Set<String> selectedKeys = <String>{
      for (final MangaDatabaseClearSource source in sources)
        if (source.name == 'Source A' || source.name == 'Source B') source.key,
    };

    final MangaDatabaseClearCounts report = await service().run(
      sourceKeys: selectedKeys,
      keepRead: false,
    );

    expect(report.works, 4);
    expect(report.historyEntries, 5);
    expect(report.readingStateRows, 2);

    for (final EpubBookRow removed in <EpubBookRow>[
      aRead,
      aProgress,
      aUnread,
      bUnread,
    ]) {
      expect(await db.getEpubBook(removed.bookKey), isNull);
    }
    expect(await db.getEpubBook(library.bookKey), isNotNull);
    expect(await db.getEpubBook(local.bookKey), isNotNull);

    final Set<String> historyKeys = <String>{
      for (final MediaOpenHistoryRow row
          in await db.select(db.mediaOpenHistory).get())
        '${row.mediaSource}\u0000${row.mediaId}',
    };
    expect(historyKeys, <String>{
      onlineHistoryKey(library),
      '$kMangaHistoryLocalSource\u0000Local/Series',
    }, reason: '书架与未选来源的历史保留，被清理作品的历史全删');

    expect(await db.select(db.readerPositions).get(), isEmpty);
    expect(
      await db.select(db.mangaChapterStates).get(),
      hasLength(1),
      reason: '只剩书架作品的已读状态',
    );
    final MangaChapterStateRow onlyState = (await db
        .select(db.mangaChapterStates)
        .getSingle());
    expect(onlyState.bookUid, library.uid);
    expect(onlyState.readAt, 99);
  });

  test('Local source 与本地导入作品可分别选择；文件与其它数据保留', () async {
    final EpubBookRow local = await insertBook(
      bookKey: 'local',
      inLibrary: false,
      sourceMetadata: const LocalSourceMetadata(
        relativePath: 'Local/Series',
      ).encode(),
    );
    final EpubBookRow imported = await insertBook(
      bookKey: 'imported',
      inLibrary: false,
    );
    await insertHistory(kMangaHistoryLocalSource, 'Local/Series');
    await insertLegacyHistory(imported);
    await seedPreservedOtherData();

    final List<MangaDatabaseClearSource> sources = await service()
        .measureSources();
    final String localKey = sources
        .singleWhere(
          (MangaDatabaseClearSource source) =>
              source.kind == MangaDatabaseClearSourceKind.localSource,
        )
        .key;
    final String importedKey = sources
        .singleWhere(
          (MangaDatabaseClearSource source) =>
              source.kind == MangaDatabaseClearSourceKind.imported,
        )
        .key;

    final MangaDatabaseClearCounts report = await service().run(
      sourceKeys: <String>{localKey, importedKey},
    );

    expect(report.works, 2);
    expect(report.historyEntries, 2);
    expect(await db.getEpubBook(local.bookKey), isNull);
    expect(await db.getEpubBook(imported.bookKey), isNull);
    expect(await db.select(db.mediaOpenHistory).get(), isEmpty);
    expect(await db.select(db.mediaSources).get(), hasLength(1));
    expect(await db.select(db.mediaTrackingMappings).get(), hasLength(1));
  });

  test('未选择任何 Source 时不删除作品/历史/阅读记录', () async {
    final EpubBookRow hidden = await insertBook(
      bookKey: 'hidden',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/hidden'),
    );
    await insertOnlineHistory(hidden);
    await insertOrphanReadingRecords();

    final MangaDatabaseClearCounts report = await service().run();

    expect(report.works, 0);
    expect(report.historyEntries, 0);
    expect(report.readingStateRows, 0);
    expect(await db.getEpubBook(hidden.bookKey), isNotNull);
    expect(await db.select(db.mediaOpenHistory).get(), hasLength(1));
    expect(await db.select(db.readerPositions).get(), hasLength(1));
    expect(await db.select(db.mangaChapterStates).get(), hasLength(1));
  });

  test('单个事务：中途失败时作品、History 与阅读记录全部回滚', () async {
    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      sourceMetadata: onlineMetadata(seriesKey: '/library'),
    );
    final EpubBookRow hidden = await insertBook(
      bookKey: 'hidden',
      inLibrary: false,
      sourceMetadata: onlineMetadata(seriesKey: '/hidden'),
    );
    await seedChapterState(hidden);
    await seedOwnedRows(hidden);
    await insertOnlineHistory(library);
    await insertOnlineHistory(hidden);
    await insertOrphanReadingRecords();

    final List<MangaDatabaseClearSource> sources = await service()
        .measureSources();
    final String hiddenKey = sources.single.key;

    final MangaDatabaseClearService failing = MangaDatabaseClearService(
      database: db,
      debugBeforeStep: (MangaDatabaseClearStep step) async {
        if (step == MangaDatabaseClearStep.history) {
          throw StateError('fixture failure');
        }
      },
    );

    await expectLater(
      failing.run(sourceKeys: <String>{hiddenKey}),
      throwsStateError,
    );

    expect(await db.getEpubBook(hidden.bookKey), isNotNull);
    expect(await db.select(db.mediaOpenHistory).get(), hasLength(2));
    expect(
      await (db.select(
        db.mangaDownloadJobs,
      )..where((t) => t.bookKey.equals(hidden.bookKey))).get(),
      hasLength(1),
    );
    expect(await db.select(db.readerPositions).get(), hasLength(1));
    expect(await db.select(db.mangaChapterStates).get(), hasLength(2));
  });
}
