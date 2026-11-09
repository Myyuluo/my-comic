import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart'
    show kTrackingProviderBangumi;
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_export/mihon_backup_exporter.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// Seams:
/// - [MihonBackupExporter.exportToFile] (database + options in, `.tachibk` out);
/// - [MihonBackupParser.parseFile] / [MihonBackupImportService.importFile] to
///   prove the generated file is parseable and restorable.
///
/// Files are synthetic, written into a temp directory, and deleted with it —
/// no real `.tachibk` is committed.
void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-backup-export-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test(
    'exports library manga + chapters and the importer restores them',
    () async {
      await _seedSource(db, sourceId: '123', name: 'Source A');
      await _seedSource(db, sourceId: '456', name: 'Source B');

      final EpubBookRow alpha = await _seedManga(
        db,
        sourceId: '123',
        url: '/manga/alpha',
        title: 'Alpha',
        importedAt: 1700000000000,
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/a1',
            name: 'Chapter 1',
            scanlator: 'Scan A',
            number: 1,
            uploadedAt: 1690000000100,
            raw: <String, Object?>{
              'url': '/chapter/a1',
              'bookmark': true,
              'date_fetch': 1700000000100,
            },
          ),
          OnlineMangaChapter(
            key: '/chapter/a2',
            name: 'Chapter 2',
            number: 2,
            raw: <String, Object?>{'url': '/chapter/a2'},
          ),
        ],
      );
      await db.importMangaChapterState(
        bookUid: alpha.uid,
        chapterKey: '/chapter/a1',
        lastPage: 7,
        readAt: 1700000001000,
        updatedAt: 1700000001000,
      );
      await db.importMangaChapterState(
        bookUid: alpha.uid,
        chapterKey: '/chapter/a2',
        lastPage: 3,
        updatedAt: 1700000002000,
      );

      await _seedManga(
        db,
        sourceId: '456',
        url: '/manga/beta',
        title: 'Beta',
        importedAt: 1700000005000,
        chapters: const <OnlineMangaChapter>[],
      );

      // Not a Mihon-runtime entry: local/manga rows without a source descriptor
      // cannot be represented in a Mihon backup and must be skipped.
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'unrepresentable',
          title: 'Local volume',
          epubPath: 'manga.json',
          extractDir: p.join(tmp.path, 'local'),
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );

      final File target = File(p.join(tmp.path, 'my-comic_test.tachibk'));
      final List<MihonBackupExportProgress> progress =
          <MihonBackupExportProgress>[];
      final MihonBackupExportReport report =
          await MihonBackupExporter(database: db).exportToFile(
            target: target,
            options: const MihonBackupExportOptions(
              includeLibrary: true,
              includeChapters: true,
            ),
            onProgress: progress.add,
          );

      expect(report.mangaCount, 2);
      expect(report.chapterCount, 2);
      expect(target.existsSync(), isTrue);
      expect(target.readAsBytesSync().take(2).toList(), <int>[
        0x1f,
        0x8b,
      ], reason: 'backup files are gzip-compressed');
      expect(progress, isNotEmpty);
      expect(progress.last.processed, 2);
      expect(progress.last.total, 2);

      final MihonBackupData parsed = MihonBackupParser.parseFile(target);
      expect(parsed.mangas, hasLength(2));
      final MihonBackupManga exported = parsed.mangas.singleWhere(
        (MihonBackupManga manga) => manga.url == '/manga/alpha',
      );
      expect(exported.source, 123);
      expect(exported.title, 'Alpha');
      expect(exported.favorite, isTrue);
      expect(exported.dateAdded, 1700000000000);
      expect(exported.author, 'Author');
      expect(exported.artist, 'Artist');
      expect(exported.description, 'Description');
      expect(exported.genres, <String>['Action', 'Drama']);
      expect(exported.status, 2);
      expect(exported.thumbnailUrl, 'https://example.test/alpha.jpg');
      expect(exported.chapters, hasLength(2));

      final MihonBackupChapter chapter1 = exported.chapters.singleWhere(
        (MihonBackupChapter chapter) => chapter.url == '/chapter/a1',
      );
      expect(chapter1.name, 'Chapter 1');
      expect(chapter1.scanlator, 'Scan A');
      expect(chapter1.read, isTrue);
      expect(chapter1.bookmark, isTrue);
      expect(chapter1.lastPageRead, 7);
      expect(chapter1.dateFetch, 1700000000100);
      expect(chapter1.dateUpload, 1690000000100);
      expect(chapter1.chapterNumber, closeTo(1, 1e-6));
      expect(chapter1.sourceOrder, 0);
      final MihonBackupChapter chapter2 = exported.chapters.singleWhere(
        (MihonBackupChapter chapter) => chapter.url == '/chapter/a2',
      );
      expect(chapter2.read, isFalse);
      expect(chapter2.lastPageRead, 3);
      expect(chapter2.sourceOrder, 1);

      expect(parsed.sourceNames, <int, String>{
        123: 'Source A',
        456: 'Source B',
      });

      // Round trip through the real import service: the file is not just
      // parseable, it restores Library + chapter progress.
      final FushiDatabase restored = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(restored.close);
      final MihonBackupImportReport imported = await MihonBackupImportService(
        database: restored,
        bookDirectory: (String bookKey) async => p.join(tmp.path, bookKey),
      ).importFile(target);
      expect(imported.importedEntries, 2);
      expect(imported.failedEntries, 0);
      expect(await restored.getEpubBookMetas(), hasLength(2));

      final EpubBookMeta restoredAlphaMeta = (await restored.getEpubBookMetas())
          .singleWhere((EpubBookMeta meta) => meta.title == 'Alpha');
      final EpubBookRow restoredAlpha = (await restored.getEpubBook(
        restoredAlphaMeta.bookKey,
      ))!;
      final Map<String, MangaChapterStateRow> states = await restored
          .getMangaChapterStates(restoredAlpha.uid);
      expect(states['/chapter/a1']!.lastPage, 7);
      expect(states['/chapter/a1']!.readAt, isNotNull);
      expect(states['/chapter/a2']!.lastPage, 3);
    },
  );

  test('includeChapters=false writes no chapter entries', () async {
    await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/chapter/a1',
          name: 'Chapter 1',
          raw: <String, Object?>{'url': '/chapter/a1'},
        ),
      ],
    );
    final File target = File(p.join(tmp.path, 'no-chapters.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: false,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(parsed.mangas.single.chapters, isEmpty);
  });

  test('exported Bangumi tracking round-trips through the importer', () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(
      db,
      book: alpha,
      subjectId: 4242,
      subjectName: 'Remote Alpha',
      progress: 12,
      completed: true,
    );
    final File target = File(p.join(tmp.path, 'tracking-roundtrip.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(includeChapters: false),
    );

    final FushiDatabase restored = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(restored.close);
    final MihonBackupImportReport report = await MihonBackupImportService(
      database: restored,
      bookDirectory: (String bookKey) async => p.join(tmp.path, bookKey),
    ).importFile(target);

    expect(report.failedEntries, 0);
    expect(report.trackingMappingsImported, 1);
    final EpubBookMeta restoredMeta = (await restored.getEpubBookMetas())
        .singleWhere((EpubBookMeta meta) => meta.title == 'Alpha');
    final EpubBookRow restoredAlpha = (await restored.getEpubBook(
      restoredMeta.bookKey,
    ))!;
    final mapping = await (restored.select(restored.mediaTrackingMappings)
          ..where((t) => t.mediaKey.equals(restoredAlpha.bookKey)))
        .getSingle();
    expect(mapping.provider, 'bangumi');
    expect(mapping.mediaType, 'book');
    expect(mapping.subjectId, 4242);
    expect(mapping.subjectName, 'Remote Alpha');
    expect(mapping.createdAt, 1700000001000);
    expect(mapping.updatedAt, 1700000002000);
    final outbox = await (restored.select(restored.mediaTrackingOutbox)
          ..where((t) => t.mappingId.equals(mapping.id)))
        .getSingle();
    expect(outbox.progress, 12);
    expect(outbox.completed, isTrue);
  });

  test('exports the Bangumi tracking record stored for a Library manga',
      () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(
      db,
      book: alpha,
      subjectId: 4242,
      subjectName: 'Remote Alpha',
      progress: 12,
      completed: true,
    );
    final File target = File(p.join(tmp.path, 'tracking.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeChapters: false,
        includeTracking: true,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    final MihonBackupManga exported = parsed.mangas.single;
    final MihonBackupTracking tracking = exported.tracking.single;
    expect(tracking.syncId, 5, reason: 'Mihon tracker id for Bangumi');
    expect(tracking.remoteId, 4242);
    expect(tracking.title, 'Remote Alpha');
    expect(tracking.lastChapterRead, closeTo(12, 1e-6));
    expect(tracking.status, 2, reason: 'completed');
    expect(tracking.startedReadingDate, 1700000001000);
    expect(tracking.finishedReadingDate, 1700000002000);
    expect(tracking.score, 0, reason: 'score is not stored locally');
    expect(tracking.totalChapters, 0, reason: 'total is not stored locally');
    expect(tracking.libraryId, isNull);
    expect(tracking.mediaIdInt, isNull);
    expect(tracking.private, isFalse);
  });

  test('does not write an empty tracking record for manga without Bangumi data',
      () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedManga(
      db,
      sourceId: '456',
      url: '/manga/beta',
      title: 'Beta',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(db, book: alpha, progress: 5, completed: false);

    final File target = File(p.join(tmp.path, 'some-tracking.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(includeChapters: false),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    final MihonBackupManga exportedAlpha = parsed.mangas.singleWhere(
      (MihonBackupManga manga) => manga.url == '/manga/alpha',
    );
    final MihonBackupManga exportedBeta = parsed.mangas.singleWhere(
      (MihonBackupManga manga) => manga.url == '/manga/beta',
    );
    expect(exportedAlpha.tracking, hasLength(1));
    expect(exportedBeta.tracking, isEmpty,
        reason: 'no tracking record means no empty BackupTracking entry');
  });

  test('exports an in-progress Bangumi record as reading without a finish date',
      () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(
      db,
      book: alpha,
      progress: 3,
      completed: false,
      updatedAt: 1700000003000,
    );

    final File target = File(p.join(tmp.path, 'reading.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(includeChapters: false),
    );

    final MihonBackupTracking tracking =
        MihonBackupParser.parseFile(target).mangas.single.tracking.single;
    expect(tracking.lastChapterRead, closeTo(3, 1e-6));
    expect(tracking.status, 3, reason: 'reading');
    expect(tracking.startedReadingDate, 1700000001000);
    expect(tracking.finishedReadingDate, isNull);
  });

  test('exports a linked-but-unread Bangumi record as a wish entry', () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(db, book: alpha);

    final File target = File(p.join(tmp.path, 'wish.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(includeChapters: false),
    );

    final MihonBackupTracking tracking =
        MihonBackupParser.parseFile(target).mangas.single.tracking.single;
    expect(tracking.lastChapterRead, 0);
    expect(tracking.status, 1, reason: 'wish');
    expect(tracking.startedReadingDate, 1700000001000);
    expect(tracking.finishedReadingDate, isNull);
  });

  test('includeTracking=false writes no tracking entries', () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(db, book: alpha, progress: 5, completed: true);

    final File target = File(p.join(tmp.path, 'no-tracking.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeChapters: false,
        includeTracking: false,
      ),
    );

    expect(
      MihonBackupParser.parseFile(target).mangas.single.tracking,
      isEmpty,
    );
  });

  test('does not export tracking records from unsupported providers', () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    await _seedTracking(
      db,
      book: alpha,
      provider: 'anilist',
      progress: 5,
      completed: false,
    );

    final File target = File(p.join(tmp.path, 'unsupported.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(includeChapters: false),
    );

    expect(
      MihonBackupParser.parseFile(target).mangas.single.tracking,
      isEmpty,
      reason: 'only Bangumi is supported; other trackers are not stored',
    );
  });

  test(
    'exports Tags as Mihon categories and each manga category orders',
    () async {
      final EpubBookRow alpha = await _seedManga(
        db,
        sourceId: '123',
        url: '/manga/alpha',
        title: 'Alpha',
        chapters: const <OnlineMangaChapter>[],
      );
      final EpubBookRow beta = await _seedManga(
        db,
        sourceId: '456',
        url: '/manga/beta',
        title: 'Beta',
        chapters: const <OnlineMangaChapter>[],
      );
      final int action = await _seedTag(db, name: 'Action', sortOrder: 1);
      final int drama = await _seedTag(db, name: 'Drama', sortOrder: 3);
      await db.addTagToBook(alpha.bookKey, action);
      await db.addTagToBook(alpha.bookKey, drama);
      await db.addTagToBook(beta.bookKey, drama);

      final File target = File(p.join(tmp.path, 'categories.tachibk'));
      await MihonBackupExporter(database: db).exportToFile(
        target: target,
        options: const MihonBackupExportOptions(
          includeLibrary: true,
          includeChapters: false,
        ),
      );

      final MihonBackupData parsed = MihonBackupParser.parseFile(target);
      expect(
        parsed.categories.map((MihonBackupCategory category) => category.name),
        <String>['Action', 'Drama'],
      );
      expect(
        parsed.categories.map((MihonBackupCategory category) => category.order),
        <int>[1, 3],
        reason: 'category order comes from the Tag sort order',
      );
      expect(
        parsed.categories.map((MihonBackupCategory category) => category.id),
        <int>[action, drama],
        reason: 'Mihon category ids must be unique and non-zero',
      );

      final MihonBackupManga exportedAlpha = parsed.mangas.singleWhere(
        (MihonBackupManga manga) => manga.url == '/manga/alpha',
      );
      final MihonBackupManga exportedBeta = parsed.mangas.singleWhere(
        (MihonBackupManga manga) => manga.url == '/manga/beta',
      );
      expect(exportedAlpha.categoryOrders, <int>[
        1,
        3,
      ], reason: 'multi-Tag manga writes every Tag category order');
      expect(exportedBeta.categoryOrders, <int>[3]);
    },
  );

  test('categories export on their own when 书架中的作品 is unchecked', () async {
    final int action = await _seedTag(db, name: 'Action', sortOrder: 0);
    final File target = File(p.join(tmp.path, 'categories-only.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: false,
        includeCategories: true,
        includeAppSettings: false,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(parsed.mangas, isEmpty);
    final MihonBackupCategory category = parsed.categories.single;
    expect(category.name, 'Action');
    expect(category.order, 0, reason: 'Mihon order 0 is the proto default');
    expect(category.id, action);
    expect(
      const MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: false,
        includeCategories: true,
        includeAppSettings: false,
      ).hasExportableContent,
      isTrue,
      reason: '分类 alone is exportable',
    );
    expect(
      const MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: false,
        includeCategories: false,
        includeAppSettings: false,
        includeExtensionStores: false,
        includeSourceSettings: false,
      ).hasExportableContent,
      isFalse,
    );
  });

  test(
    'includeCategories=false writes no categories or per-manga orders',
    () async {
      final EpubBookRow alpha = await _seedManga(
        db,
        sourceId: '123',
        url: '/manga/alpha',
        title: 'Alpha',
        chapters: const <OnlineMangaChapter>[],
      );
      final int action = await _seedTag(db, name: 'Action', sortOrder: 1);
      await db.addTagToBook(alpha.bookKey, action);

      final File target = File(p.join(tmp.path, 'no-categories.tachibk'));
      await MihonBackupExporter(database: db).exportToFile(
        target: target,
        options: const MihonBackupExportOptions(
          includeLibrary: true,
          includeChapters: false,
          includeCategories: false,
        ),
      );

      final MihonBackupData parsed = MihonBackupParser.parseFile(target);
      expect(parsed.categories, isEmpty);
      expect(parsed.mangas.single.categoryOrders, isEmpty);
    },
  );

  test('category orders stay unique when Tags share a sort order', () async {
    final EpubBookRow alpha = await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    // Display order: Charlie (1), Alpha (2), Bravo (2). Alpha and Bravo
    // collide, so Bravo's exported order moves to the next free integer.
    final int alphaTag = await _seedTag(
      db,
      name: 'AlphaTag',
      sortOrder: 2,
      createdAt: 1,
    );
    final int bravoTag = await _seedTag(
      db,
      name: 'BravoTag',
      sortOrder: 2,
      createdAt: 2,
    );
    await _seedTag(db, name: 'CharlieTag', sortOrder: 1, createdAt: 3);
    await db.addTagToBook(alpha.bookKey, alphaTag);
    await db.addTagToBook(alpha.bookKey, bravoTag);

    final File target = File(p.join(tmp.path, 'unique-orders.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: false,
        includeCategories: true,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(
      parsed.categories.map((MihonBackupCategory category) => category.name),
      <String>['CharlieTag', 'AlphaTag', 'BravoTag'],
      reason: 'categories follow Tag sort order, then creation order',
    );
    expect(
      parsed.categories.map((MihonBackupCategory category) => category.order),
      <int>[1, 2, 3],
    );
    expect(
      parsed.categories
          .map((MihonBackupCategory category) => category.order)
          .toSet(),
      hasLength(3),
      reason: 'orders are the reference key and must be unique',
    );
    expect(parsed.mangas.single.categoryOrders, <int>[2, 3]);
  });

  test(
    'exported categories round-trip back into Tags and assignments',
    () async {
      final EpubBookRow alpha = await _seedManga(
        db,
        sourceId: '123',
        url: '/manga/alpha',
        title: 'Alpha',
        chapters: const <OnlineMangaChapter>[],
      );
      final int action = await _seedTag(
        db,
        name: 'Action',
        sortOrder: 1,
        createdAt: 1,
      );
      final int drama = await _seedTag(
        db,
        name: 'Drama',
        sortOrder: 3,
        createdAt: 2,
      );
      await db.addTagToBook(alpha.bookKey, action);
      await db.addTagToBook(alpha.bookKey, drama);

      final File target = File(p.join(tmp.path, 'category-roundtrip.tachibk'));
      await MihonBackupExporter(database: db).exportToFile(
        target: target,
        options: const MihonBackupExportOptions(
          includeLibrary: true,
          includeChapters: false,
          includeCategories: true,
        ),
      );

      final FushiDatabase restored = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(restored.close);
      await MihonBackupImportService(
        database: restored,
        bookDirectory: (String bookKey) async => p.join(tmp.path, bookKey),
      ).importFile(target);

      final List<BookTagRow> tags = await restored.getAllTags();
      expect(
        <String, int>{
          for (final BookTagRow tag in tags) tag.name: tag.sortOrder,
        },
        <String, int>{'Action': 1, 'Drama': 3},
        reason:
            'Tag names and category-order-based sorting survive the round trip',
      );

      final EpubBookMeta meta = (await restored.getEpubBookMetas()).singleWhere(
        (EpubBookMeta meta) => meta.title == 'Alpha',
      );
      final EpubBookRow restoredAlpha = (await restored.getEpubBook(
        meta.bookKey,
      ))!;
      final List<BookTagRow> alphaTags = await restored.getTagsForBook(
        restoredAlpha.bookKey,
      );
      expect(alphaTags.map((BookTagRow tag) => tag.name).toSet(), <String>{
        'Action',
        'Drama',
      }, reason: 'multi-Tag manga gets an assignment for every category order');
    },
  );

  test('default filename uses my-comic_YYYY-MM-DD_HH-mm.tachibk', () {
    expect(
      mihonBackupDefaultFileName(DateTime(2026, 11, 9, 20, 5)),
      'my-comic_2026-11-09_20-05.tachibk',
    );
    expect(
      mihonBackupDefaultFileName(DateTime(2026, 1, 2, 3, 4)),
      'my-comic_2026-01-02_03-04.tachibk',
    );
  });

  test('failed write leaves no half-written file behind', () async {
    await _seedManga(
      db,
      sourceId: '123',
      url: '/manga/alpha',
      title: 'Alpha',
      chapters: const <OnlineMangaChapter>[],
    );
    // A directory at the target path makes the final move fail after the temp
    // file was written.
    final Directory targetAsDirectory = Directory(
      p.join(tmp.path, 'blocked.tachibk'),
    )..createSync(recursive: true);

    await expectLater(
      MihonBackupExporter(database: db).exportToFile(
        target: File(targetAsDirectory.path),
        options: const MihonBackupExportOptions(
          includeLibrary: true,
          includeChapters: true,
        ),
      ),
      throwsA(isA<FileSystemException>()),
    );

    final List<String> leftovers = tmp
        .listSync()
        .map((FileSystemEntity entity) => p.basename(entity.path))
        .where((String name) => name != 'blocked.tachibk')
        .toList();
    expect(leftovers, isEmpty, reason: 'temp file must be deleted on failure');
  });

  test('empty database writes an empty but valid backup', () async {
    final File target = File(p.join(tmp.path, 'empty.tachibk'));
    final MihonBackupExportReport report =
        await MihonBackupExporter(database: db).exportToFile(
          target: target,
          options: const MihonBackupExportOptions(
            includeLibrary: true,
            includeChapters: true,
          ),
        );
    expect(report.mangaCount, 0);
    expect(target.existsSync(), isTrue);
    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(parsed.mangas, isEmpty);
  });
}

Future<int> _seedTag(
  FushiDatabase db, {
  required String name,
  required int sortOrder,
  int createdAt = 0,
}) {
  return db
      .into(db.bookTags)
      .insert(
        BookTagsCompanion.insert(
          name: name,
          colorValue: const Value<int>(0xFF123456),
          sortOrder: Value<int>(sortOrder),
          createdAt: createdAt,
        ),
      );
}

Future<void> _seedTracking(
  FushiDatabase db, {
  required EpubBookRow book,
  String provider = kTrackingProviderBangumi,
  int subjectId = 4242,
  String subjectName = 'Remote Alpha',
  int createdAt = 1700000001000,
  int updatedAt = 1700000002000,
  int progress = 0,
  bool completed = false,
}) async {
  final int mappingId = await db
      .into(db.mediaTrackingMappings)
      .insert(
        MediaTrackingMappingsCompanion.insert(
          provider: Value<String>(provider),
          mediaType: 'book',
          mediaKey: book.bookKey,
          mediaTitle: book.title,
          kind: 'manga',
          subjectId: subjectId,
          subjectName: subjectName,
          progressMode: 'chapter',
          progressOffset: const Value<int>(0),
          createdAt: createdAt,
          updatedAt: updatedAt,
        ),
      );
  if (progress > 0 || completed) {
    await db
        .into(db.mediaTrackingOutbox)
        .insert(
          MediaTrackingOutboxCompanion.insert(
            mappingId: mappingId,
            progress: progress,
            completed: Value<bool>(completed),
            updatedAt: updatedAt,
          ),
        );
  }
}

Future<void> _seedSource(
  FushiDatabase db, {
  required String sourceId,
  required String name,
}) async {
  await db
      .into(db.mangaOnlineSources)
      .insert(
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.ext',
          sourceId: sourceId,
          name: name,
          language: 'en',
        ),
      );
}

Future<EpubBookRow> _seedManga(
  FushiDatabase db, {
  required String sourceId,
  required String url,
  required String title,
  int importedAt = 1700000000000,
  List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
}) async {
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.ext',
    sourceId: sourceId,
    series: OnlineMangaSeries(
      key: url,
      title: title,
      coverUrl: 'https://example.test/${title.toLowerCase()}.jpg',
      author: 'Author',
      artist: 'Artist',
      description: 'Description',
      genre: 'Action, Drama',
      raw: <String, Object?>{
        'url': url,
        'title': title,
        'status': 2,
        'initialized': true,
      },
    ),
    chapters: chapters,
    currentChapterIndex: chapters.isEmpty ? null : 0,
  );
  final String bookKey = onlineMangaBookKeyFor(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.ext',
    sourceId: sourceId,
    seriesKey: url,
  );
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      author: const Value<String>('Author'),
      epubPath: 'manga.json',
      extractDir: p.join('books', bookKey),
      chapterCount: chapters.length,
      chaptersJson: jsonEncode(<Map<String, Object?>>[
        for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
      ]),
      sourceMetadata: Value<String>(entry.encode()),
      importedAt: importedAt,
      format: const Value<String>('manga'),
    ),
  );
  return (await db.getEpubBook(bookKey))!;
}
