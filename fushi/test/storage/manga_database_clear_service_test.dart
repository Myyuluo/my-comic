import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi_core/fushi_core.dart';

/// Ticket 13：设置 →「存储与下载」的「清除数据库」。
///
/// 服务层测试用真实 37 表内存库：删除全部 History、未入书架的 Library 记录
/// （记录级级联，不碰磁盘）与无法归属任何作品的阅读记录；保留 Library 作品
/// 及其 Reading progress、章节 readAt、完成标记、Download index 与其它数据。
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

  Future<EpubBookRow> insertBook({
    required String bookKey,
    bool inLibrary = true,
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
        format: const Value<String>('manga'),
        inLibrary: Value<bool>(inLibrary),
        completedAt: Value<DateTime?>(completedAt),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  Future<void> insertHistory(String mediaSource, String mediaId) =>
      db.upsertMediaOpenHistory(
        MediaOpenHistoryCompanion(
          mediaType: const Value<String>('reader_media_type'),
          mediaSource: Value<String>(mediaSource),
          mediaId: Value<String>(mediaId),
          openedAt: const Value<int>(1),
          position: const Value<int>(0),
          duration: const Value<int>(0),
          snapshotJson: const Value<String>('{}'),
        ),
      );

  Future<void> seedBookOwnedRows(EpubBookRow book) async {
    await db
        .into(db.readerPositions)
        .insert(
          ReaderPositionsCompanion.insert(
            bookUid: book.uid,
            sectionIndex: 3,
            normCharOffset: 0,
            updatedAt: 10,
          ),
        );
    await db
        .into(db.mangaChapterStates)
        .insert(
          MangaChapterStatesCompanion.insert(
            bookUid: book.uid,
            chapterKey: 'c1',
            updatedAt: 10,
            readAt: const Value<int?>(99),
          ),
        );
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

  MangaDatabaseClearService service({
    Future<void> Function(MangaDatabaseClearStep step)? beforeStep,
  }) => MangaDatabaseClearService(database: db, debugBeforeStep: beforeStep);

  test('统计将删除的作品、历史与阅读记录', () async {
    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      completedAt: DateTime.fromMillisecondsSinceEpoch(500),
    );
    final EpubBookRow hidden = await insertBook(
      bookKey: 'hidden',
      inLibrary: false,
    );
    await seedBookOwnedRows(library);
    await seedBookOwnedRows(hidden);
    await insertHistory('reader_manga', 'library-history');
    await insertHistory('reader_manga', 'hidden-history');
    await insertOrphanReadingRecords();

    final MangaDatabaseClearCounts counts = await service().measure();

    expect(counts.works, 1, reason: '只有不在 Library 中的 epub_books 行');
    expect(counts.historyEntries, 2, reason: '全部 media_open_history 行');
    expect(
      counts.readingStateRows,
      4,
      reason: '非 Library 作品名下的 2 条 + 无归属作品的 2 条孤儿行',
    );
  });

  test('删除对象与保留对象：历史、未入书架作品级联、孤儿阅读记录', () async {
    final EpubBookRow library = await insertBook(
      bookKey: 'library',
      completedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );
    final DateTime? completedAt = library.completedAt;
    final EpubBookRow hidden = await insertBook(
      bookKey: 'hidden',
      inLibrary: false,
    );
    await seedBookOwnedRows(library);
    await seedBookOwnedRows(hidden);
    await insertHistory('reader_manga', 'library-history');
    await insertHistory('reader_manga', 'hidden-history');
    await insertOrphanReadingRecords();

    // 必须保留的其它数据。
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
            mediaKey: library.bookKey,
            mediaTitle: library.title,
            kind: 'manga',
            subjectId: 42,
            subjectName: 'Kept tracking',
            progressMode: 'chapter',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
    final File downloadFile = File(
      p.join(tmp.path, 'downloads', 'Source', 'Series', 'ch1.cbz'),
    )..createSync(recursive: true);
    downloadFile.writeAsBytesSync(const <int>[1, 2, 3]);
    final File localPage = File(
      p.join(tmp.path, 'local', 'Series', 'ch1', '001.jpg'),
    )..createSync(recursive: true);
    localPage.writeAsBytesSync(const <int>[4, 5, 6]);

    final List<MangaDatabaseClearStep> progressSteps =
        <MangaDatabaseClearStep>[];
    final MangaDatabaseClearCounts report = await service().run(
      onProgress: (MangaDatabaseClearProgress progress) =>
          progressSteps.add(progress.step),
    );

    expect(report.works, 1);
    expect(report.historyEntries, 2);
    expect(report.readingStateRows, 4);
    expect(progressSteps, <MangaDatabaseClearStep>[
      MangaDatabaseClearStep.works,
      MangaDatabaseClearStep.history,
      MangaDatabaseClearStep.readingState,
    ]);

    // 删除对象。
    expect(await db.getAllMediaOpenHistory(), isEmpty);
    expect(await db.getEpubBook(hidden.bookKey), isNull);
    final List<ReaderPositionRow> positions = await db
        .select(db.readerPositions)
        .get();
    expect(positions.map((ReaderPositionRow row) => row.bookUid), <String>[
      library.uid,
    ]);
    final List<MangaChapterStateRow> states = await db
        .select(db.mangaChapterStates)
        .get();
    expect(states.map((MangaChapterStateRow row) => row.bookUid), <String>[
      library.uid,
    ]);
    expect(
      await (db.select(
        db.mangaReaderOverrides,
      )..where((t) => t.bookUid.equals(hidden.uid))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.mangaDownloadJobs,
      )..where((t) => t.bookKey.equals(hidden.bookKey))).get(),
      isEmpty,
    );
    expect(
      await (db.select(
        db.mangaChapterDirs,
      )..where((t) => t.bookKey.equals(hidden.bookKey))).get(),
      isEmpty,
    );

    // 保留对象：Library 作品及其进度 / 已读 / 完成标记。
    final EpubBookRow preserved = (await db.getEpubBook(library.bookKey))!;
    expect(preserved.completedAt, completedAt);
    expect(positions.single.sectionIndex, 3);
    expect(positions.single.updatedAt, 10);
    expect(states.single.chapterKey, 'c1');
    expect(states.single.readAt, 99);
    expect(
      await (db.select(
        db.mangaReaderOverrides,
      )..where((t) => t.bookUid.equals(library.uid))).get(),
      hasLength(1),
    );
    expect(
      await (db.select(
        db.mangaDownloadJobs,
      )..where((t) => t.bookKey.equals(library.bookKey))).get(),
      hasLength(1),
    );
    expect(
      await (db.select(
        db.mangaChapterDirs,
      )..where((t) => t.bookKey.equals(library.bookKey))).get(),
      hasLength(1),
    );

    // 保留对象：设置、源、扩展、搜索历史、Tracking 与磁盘文件。
    expect(
      await db.select(db.searchHistoryItems).get(),
      hasLength(1),
      reason: '搜索历史必须保留',
    );
    expect(
      await db.select(db.mediaSources).get(),
      hasLength(1),
      reason: '源必须保留',
    );
    expect(
      await db.select(db.mediaTrackingMappings).get(),
      hasLength(1),
      reason: 'Tracking 数据必须保留',
    );
    expect(downloadFile.existsSync(), isTrue, reason: '不删除下载库文件');
    expect(localPage.existsSync(), isTrue, reason: '不删除本地图源文件');
  });

  test('单个事务：中途失败时删除全部回滚', () async {
    final EpubBookRow library = await insertBook(bookKey: 'library');
    final EpubBookRow hidden = await insertBook(
      bookKey: 'hidden',
      inLibrary: false,
    );
    await seedBookOwnedRows(library);
    await seedBookOwnedRows(hidden);
    await insertHistory('reader_manga', 'a');
    await insertHistory('reader_manga', 'b');
    await insertOrphanReadingRecords();

    final MangaDatabaseClearService failing = service(
      beforeStep: (MangaDatabaseClearStep step) async {
        if (step == MangaDatabaseClearStep.history) {
          throw StateError('fixture failure');
        }
      },
    );

    await expectLater(failing.run(), throwsStateError);

    expect(
      await db.getAllMediaOpenHistory(),
      hasLength(2),
      reason: '历史删除必须随事务回滚',
    );
    expect(await db.getEpubBook(hidden.bookKey), isNotNull);
    expect(await db.select(db.readerPositions).get(), hasLength(3));
    expect(await db.select(db.mangaChapterStates).get(), hasLength(3));
  });

  test('没有可删除内容时统计为零且删除成功', () async {
    final EpubBookRow library = await insertBook(bookKey: 'library');
    await seedBookOwnedRows(library);
    await insertHistory('reader_manga', 'library-history');

    final MangaDatabaseClearCounts counts = await service().measure();
    expect(counts.works, 0);
    expect(counts.historyEntries, 1);
    expect(counts.readingStateRows, 0);

    final MangaDatabaseClearCounts report = await service().run();
    expect(report.works, 0);
    expect(report.historyEntries, 1);
    expect(report.readingStateRows, 0);
    expect(await db.getAllMediaOpenHistory(), isEmpty);
    expect(await db.getEpubBook(library.bookKey), isNotNull);
    expect(await db.select(db.readerPositions).get(), hasLength(1));
    expect(await db.select(db.mangaChapterStates).get(), hasLength(1));
  });
}
