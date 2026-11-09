import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';

import 'mihon_backup_fixture.dart';

/// Seam: [MihonBackupImportService.importFile] (file in, domain report out).
/// Fixtures are synthetic and generated at test time — no real backup content.
void main() {
  late Directory tmp;
  late FushiDatabase db;
  const int now = 1800000000000;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-backup-import-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  MihonBackupImportService service() => MihonBackupImportService(
    database: db,
    bookDirectory: (String bookKey) async {
      final Directory dir = Directory(p.join(tmp.path, 'books', bookKey));
      await dir.create(recursive: true);
      return dir.path;
    },
    now: () => now,
  );

  test('imports library entries, categories as tags and progress', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      categories: const <FixtureCategory>[
        FixtureCategory(name: 'Action', order: 0, id: 10),
        FixtureCategory(name: 'Drama', order: 1, id: 20),
      ],
      sources: const <FixtureSource>[
        FixtureSource(id: 123, name: 'Source A'),
        FixtureSource(id: 456, name: 'Source B'),
      ],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          author: 'Author A',
          genres: <String>['Action', 'Adventure'],
          dateAdded: 1700000000000,
          categoryOrders: <int>[0],
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/a1',
              name: 'Chapter 1',
              read: true,
              lastPageRead: 5,
              dateFetch: 1700000000500,
            ),
            FixtureChapter(
              url: '/chapter/a2',
              name: 'Chapter 2',
              lastPageRead: 3,
              dateFetch: 1700000002000,
            ),
          ],
          history: <FixtureHistory>[
            FixtureHistory(url: '/chapter/a1', lastRead: 1700000001000),
          ],
        ),
        FixtureManga(
          source: 456,
          url: '/manga/beta',
          title: 'Beta',
          categoryOrders: <int>[1],
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/b1',
              name: 'Chapter 1',
              read: true,
              dateFetch: 1700000003000,
            ),
          ],
        ),
        FixtureManga(
          source: 456,
          url: '/manga/read-only',
          title: 'Read Only',
          favorite: false,
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/r1',
              name: 'Chapter 1',
              read: true,
              lastPageRead: 4,
            ),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);

    expect(report.totalEntries, 3);
    expect(report.importedEntries, 2);
    expect(report.mergedEntries, 0);
    expect(report.skippedEntries, 1);
    expect(report.failedEntries, 0);
    expect(report.categoriesCreated, 2);
    expect(report.chapterStatesWritten, 3);
    expect(
      report.missingSources.map((MihonBackupSourceIssue s) => s.sourceId),
      <int>{123, 456},
    );

    final List<EpubBookRow> books = <EpubBookRow>[
      for (final EpubBookMeta meta in await db.getEpubBookMetas())
        (await db.getEpubBook(meta.bookKey))!,
    ];
    expect(books, hasLength(2));
    expect(books.map((EpubBookRow b) => b.format), everyElement('manga'));

    final EpubBookRow alpha = books.singleWhere(
      (EpubBookRow b) => b.title == 'Alpha',
    );
    expect(alpha.chapterCount, 2);
    expect(alpha.author, 'Author A');
    final OnlineMangaLibraryEntry? alphaEntry =
        OnlineMangaLibraryEntry.tryParse(alpha.sourceMetadata);
    expect(alphaEntry, isNotNull);
    expect(alphaEntry!.runtime, OnlineMangaRuntimeKind.mihon);
    expect(alphaEntry.sourceId, '123');
    expect(alphaEntry.series.key, '/manga/alpha');
    expect(alphaEntry.chapters, hasLength(2));
    expect(alphaEntry.chapters.first.key, '/chapter/a1');
    // Mihon source isn't installed in this fresh DB → stable placeholder.
    expect(alphaEntry.extensionPackage, kUnavailableMihonExtensionPackage);
    expect(
      report.missingSources
          .firstWhere((MihonBackupSourceIssue s) => s.sourceId == 123)
          .sourceName,
      'Source A',
    );

    final Map<String, MangaChapterStateRow> alphaStates = await db
        .getMangaChapterStates(alpha.uid);
    expect(alphaStates, hasLength(2));
    expect(alphaStates['/chapter/a1']!.lastPage, 5);
    expect(alphaStates['/chapter/a1']!.readAt, 1700000001000);
    expect(alphaStates['/chapter/a2']!.lastPage, 3);
    expect(alphaStates['/chapter/a2']!.readAt, isNull);

    final EpubBookRow beta = books.singleWhere(
      (EpubBookRow b) => b.title == 'Beta',
    );
    final Map<String, MangaChapterStateRow> betaStates = await db
        .getMangaChapterStates(beta.uid);
    expect(betaStates['/chapter/b1']!.readAt, 1700000003000);

    final List<BookTagRow> tags = await db.getAllTags();
    expect(tags.map((BookTagRow tag) => tag.name).toSet(), <String>{
      'Action',
      'Drama',
    });
    final BookTagRow actionTag = tags.singleWhere(
      (BookTagRow tag) => tag.name == 'Action',
    );
    final BookTagRow dramaTag = tags.singleWhere(
      (BookTagRow tag) => tag.name == 'Drama',
    );
    expect(actionTag.sortOrder, 0);
    expect(dramaTag.sortOrder, 1);
    expect(actionTag.colorValue, 0xFF9E9E9E);
    expect(dramaTag.colorValue, 0xFF9E9E9E);

    final List<BookTagRow> alphaTags = await db.getTagsForBook(alpha.bookKey);
    expect(alphaTags.map((BookTagRow tag) => tag.name), <String>['Action']);
    expect(
      mangaBookBelongsToTab(alphaTags, const MangaShelfTabSelection()),
      isFalse,
      reason: 'a categorised manga leaves the 书架 tab',
    );
    expect(
      mangaBookBelongsToTab(alphaTags, MangaTagTabSelection(actionTag.id)),
      isTrue,
    );
    final List<BookTagRow> betaTags = await db.getTagsForBook(beta.bookKey);
    expect(betaTags.map((BookTagRow tag) => tag.name), <String>['Drama']);

    // Categories no longer become hidden collections.
    expect(await db.getAllMediaCollections(), isEmpty);
    expect(await db.getAllTagAssignments(), hasLength(2));
  });

  test(
    're-import merges by source + manga url without duplicating rows',
    () async {
      Future<File> fixture({required bool changed}) => writeFixtureBackup(
        tmp,
        name: changed ? 'second.tachibk' : 'first.tachibk',
        categories: const <FixtureCategory>[
          FixtureCategory(name: 'Action', order: 0, id: 10),
          FixtureCategory(name: 'Drama', order: 1, id: 20),
        ],
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
          FixtureSource(id: 456, name: 'Source B'),
        ],
        mangas: <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: changed ? 'Alpha Renamed In Backup' : 'Alpha',
            categoryOrders: changed ? const <int>[0, 1] : const <int>[0],
            chapters: changed
                ? const <FixtureChapter>[
                    FixtureChapter(
                      url: '/chapter/a1',
                      name: 'Chapter 1',
                      scanlator: 'Scan New',
                      bookmark: true,
                      read: true,
                      lastPageRead: 8,
                      dateFetch: 1700000000500,
                      dateUpload: 1600000000000,
                      chapterNumber: 1.2,
                    ),
                    FixtureChapter(
                      url: '/chapter/a2',
                      name: 'Chapter 2',
                      read: true,
                      lastPageRead: 6,
                      dateFetch: 1700000002000,
                    ),
                    FixtureChapter(
                      url: '/chapter/a3',
                      name: 'Chapter 3',
                      lastPageRead: 2,
                      dateFetch: 1700000004000,
                    ),
                  ]
                : const <FixtureChapter>[
                    FixtureChapter(
                      url: '/chapter/a1',
                      name: 'Chapter 1',
                      read: true,
                      lastPageRead: 5,
                      dateFetch: 1700000000500,
                    ),
                    FixtureChapter(
                      url: '/chapter/a2',
                      name: 'Chapter 2',
                      lastPageRead: 3,
                      dateFetch: 1700000002000,
                    ),
                  ],
            history: changed
                ? const <FixtureHistory>[
                    FixtureHistory(url: '/chapter/a2', lastRead: 1700000009000),
                  ]
                : const <FixtureHistory>[
                    FixtureHistory(url: '/chapter/a1', lastRead: 1700000001000),
                  ],
          ),
          const FixtureManga(
            source: 456,
            url: '/manga/beta',
            title: 'Beta',
            categoryOrders: <int>[1],
          ),
          const FixtureManga(
            source: 456,
            url: '/manga/read-only',
            title: 'Read Only',
            favorite: false,
          ),
        ],
      );

      final MihonBackupImportReport first = await service().importFile(
        await fixture(changed: false),
      );
      expect(first.importedEntries, 2);
      expect(first.categoriesCreated, 2);
      expect(first.categoriesMatched, 0);

      final MihonBackupImportReport second = await service().importFile(
        await fixture(changed: true),
      );

      expect(second.totalEntries, 3);
      expect(second.importedEntries, 0);
      expect(second.mergedEntries, 2);
      expect(second.skippedEntries, 1);
      expect(second.failedEntries, 0);
      expect(second.categoriesCreated, 0);
      expect(second.categoriesMatched, 2);

      expect(await db.getEpubBookMetas(), hasLength(2));
      final String alphaKey = (await db.getEpubBookMetas())
          .singleWhere((EpubBookMeta meta) => meta.title == 'Alpha')
          .bookKey;
      final EpubBookRow alphaRow = (await db.getEpubBook(alphaKey))!;
      expect(alphaRow.title, 'Alpha', reason: 'local metadata wins on merge');

      final OnlineMangaLibraryEntry alphaEntry =
          OnlineMangaLibraryEntry.tryParse(alphaRow.sourceMetadata)!;
      expect(alphaEntry.chapters, hasLength(3));
      final OnlineMangaChapter mergedA1 = alphaEntry.chapters.singleWhere(
        (OnlineMangaChapter chapter) => chapter.key == '/chapter/a1',
      );
      expect(mergedA1.scanlator, 'Scan New');
      expect(mergedA1.number, closeTo(1.2, 1e-6));
      expect(mergedA1.uploadedAt, 1600000000000);
      expect(mergedA1.raw['bookmark'], isTrue);

      final Map<String, MangaChapterStateRow> states = await db
          .getMangaChapterStates(alphaRow.uid);
      expect(states['/chapter/a1']!.lastPage, 8);
      expect(states['/chapter/a2']!.lastPage, 6);
      expect(states['/chapter/a2']!.readAt, 1700000009000);
      expect(states['/chapter/a3']!.lastPage, 2);

      final List<BookTagRow> alphaTags = await db.getTagsForBook(
        alphaRow.bookKey,
      );
      expect(alphaTags.map((BookTagRow tag) => tag.name).toSet(), <String>{
        'Action',
        'Drama',
      });
      expect(await db.getAllTagAssignments(), hasLength(3));
      expect(await db.getAllMediaCollections(), isEmpty);
    },
  );

  test(
    'reuses existing tags and leaves existing collections untouched',
    () async {
      final int actionTagId = await db.createTag('Action', 0xFF123456);
      final String legacyBookKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'legacy-book',
          title: 'Legacy',
          epubPath: 'manga.json',
          extractDir: 'legacy',
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: 1,
        ),
      );
      final EpubBookRow legacyBook = (await db.getEpubBook(legacyBookKey))!;
      final int legacyCollectionId = await db.createMediaCollection('Action');
      await db.addToCollection(
        legacyCollectionId,
        MediaKind.epub,
        legacyBook.uid,
      );

      final File backup = await writeFixtureBackup(
        tmp,
        categories: const <FixtureCategory>[
          FixtureCategory(name: 'Action', order: 0, id: 10),
          FixtureCategory(name: 'Drama', order: 3, id: 20),
        ],
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            categoryOrders: <int>[0, 3],
          ),
        ],
      );

      final MihonBackupImportReport report = await service().importFile(backup);

      expect(report.categoriesCreated, 1);
      expect(report.categoriesMatched, 1);
      final List<BookTagRow> tags = await db.getAllTags();
      expect(tags, hasLength(2));
      final BookTagRow action = tags.singleWhere(
        (BookTagRow tag) => tag.name == 'Action',
      );
      expect(action.id, actionTagId);
      expect(
        action.sortOrder,
        0,
        reason: 'tag order comes from the backup category order',
      );
      expect(
        action.colorValue,
        0xFF123456,
        reason: 'a reused tag keeps its own color',
      );
      final BookTagRow drama = tags.singleWhere(
        (BookTagRow tag) => tag.name == 'Drama',
      );
      expect(drama.sortOrder, 3);
      expect(drama.colorValue, 0xFF9E9E9E);

      // Old hidden collections survive unchanged; import adds no new ones.
      final List<MediaCollectionRow> collections = await db
          .getAllMediaCollections();
      expect(collections, hasLength(1));
      expect(collections.single.id, legacyCollectionId);
      expect(collections.single.name, 'Action');
      final List<MediaCollectionItemRow> members = await db.getCollectionItems(
        legacyCollectionId,
      );
      expect(members, hasLength(1));
      expect(members.single.mediaType, MediaKind.epub.dbValue);
      expect(members.single.entryKey, legacyBook.uid);

      final String importedBookKey = (await db.getEpubBookMetas())
          .singleWhere((EpubBookMeta meta) => meta.title == 'Alpha')
          .bookKey;
      final List<BookTagRow> importedTags = await db.getTagsForBook(
        importedBookKey,
      );
      expect(importedTags.map((BookTagRow tag) => tag.name).toSet(), <String>{
        'Action',
        'Drama',
      });
      expect(
        mangaBookBelongsToTab(importedTags, const MangaShelfTabSelection()),
        isFalse,
      );
      expect(
        mangaBookBelongsToTab(importedTags, MangaTagTabSelection(action.id)),
        isTrue,
      );
    },
  );

  test('repeated import keeps tag assignments idempotent', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      categories: const <FixtureCategory>[
        FixtureCategory(name: 'Action', order: 0, id: 10),
        FixtureCategory(name: 'Drama', order: 1, id: 20),
      ],
      sources: const <FixtureSource>[FixtureSource(id: 123, name: 'Source A')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          categoryOrders: <int>[0, 1],
        ),
        FixtureManga(
          source: 123,
          url: '/manga/beta',
          title: 'Beta',
          categoryOrders: <int>[1],
        ),
      ],
    );

    final MihonBackupImportReport first = await service().importFile(backup);
    expect(first.categoriesCreated, 2);
    expect(first.categoriesMatched, 0);
    final Set<String> assignmentsAfterFirst = <String>{
      for (final TagAssignmentRow row in await db.getAllTagAssignments())
        '${row.entryKey}:${row.tagId}',
    };
    expect(assignmentsAfterFirst, hasLength(3));

    final MihonBackupImportReport second = await service().importFile(backup);
    expect(second.categoriesCreated, 0);
    expect(second.categoriesMatched, 2);
    expect(await db.getAllTags(), hasLength(2));
    final Set<String> assignmentsAfterSecond = <String>{
      for (final TagAssignmentRow row in await db.getAllTagAssignments())
        '${row.entryKey}:${row.tagId}',
    };
    expect(assignmentsAfterSecond, assignmentsAfterFirst);
  });

  test('skips non-library entries and accepts an empty backup', () async {
    final File onlyRead = await writeFixtureBackup(
      tmp,
      name: 'read-only.tachibk',
      sources: const <FixtureSource>[FixtureSource(id: 1, name: 'S')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 1,
          url: '/manga/x',
          title: 'X',
          favorite: false,
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/c/1',
              name: 'C1',
              read: true,
              lastPageRead: 3,
            ),
          ],
        ),
      ],
    );
    final MihonBackupImportReport skippedReport = await service().importFile(
      onlyRead,
    );
    expect(skippedReport.totalEntries, 1);
    expect(skippedReport.importedEntries, 0);
    expect(skippedReport.skippedEntries, 1);
    expect(
      skippedReport.skippedByReason[MihonBackupSkipReason.notInLibrary],
      1,
    );
    expect(await db.getEpubBookMetas(), isEmpty);

    final File empty = await writeFixtureBackup(
      tmp,
      mangas: const <FixtureManga>[],
    );
    final MihonBackupImportReport emptyReport = await service().importFile(
      empty,
    );
    expect(emptyReport.isEmpty, isTrue);
    expect(emptyReport.importedEntries, 0);
  });

  test('rejects corrupt and non-Mihon files with a typed error', () async {
    Future<File> bytes(String name, List<int> content) async {
      final File file = File(p.join(tmp.path, name));
      await file.writeAsBytes(content, flush: true);
      return file;
    }

    await expectLater(
      service().importFile(await bytes('empty.tachibk', <int>[])),
      throwsA(
        isA<MihonBackupFormatException>().having(
          (MihonBackupFormatException e) => e.error,
          'error',
          MihonBackupFormatError.emptyFile,
        ),
      ),
    );
    await expectLater(
      service().importFile(await bytes('json.tachibk', '{}'.codeUnits)),
      throwsA(
        isA<MihonBackupFormatException>().having(
          (MihonBackupFormatException e) => e.error,
          'error',
          MihonBackupFormatError.unsupportedFormat,
        ),
      ),
    );
    // Gzip-compressed payload whose protobuf message announces 5 bytes but
    // only carries 1 → truncated message inside a valid container.
    await expectLater(
      service().importFile(
        await bytes('truncated.tachibk', gzipEncode(<int>[0x0a, 0x05, 0x01])),
      ),
      throwsA(
        isA<MihonBackupFormatException>().having(
          (MihonBackupFormatException e) => e.error,
          'error',
          MihonBackupFormatError.corrupt,
        ),
      ),
    );
  });

  test('imports complete chapter fields and preserves user flags', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[FixtureSource(id: 123, name: 'Source A')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/a1',
              name: 'Chapter 1',
              scanlator: 'Scan A',
              bookmark: true,
              dateFetch: 1700000000100,
              dateUpload: 1690000000100,
              chapterNumber: 1.5,
            ),
            FixtureChapter(
              url: '/chapter/a2',
              name: 'Chapter 2',
              scanlator: 'Scan B',
              read: true,
              lastPageRead: 7,
              dateFetch: 1700000000200,
              dateUpload: 1690000000200,
              chapterNumber: 2.5,
            ),
          ],
          history: <FixtureHistory>[
            FixtureHistory(
              url: '/chapter/a2',
              lastRead: 1700000009000,
              readDuration: 5000,
            ),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);
    expect(report.chapterStatesWritten, 1);

    final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
    final EpubBookRow book = (await db.getEpubBook(meta.bookKey))!;
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      book.sourceMetadata,
    )!;
    expect(entry.chapters, hasLength(2));

    final OnlineMangaChapter bookmarkOnly = entry.chapters[0];
    expect(bookmarkOnly.key, '/chapter/a1');
    expect(bookmarkOnly.name, 'Chapter 1');
    expect(bookmarkOnly.scanlator, 'Scan A');
    expect(bookmarkOnly.number, 1.5);
    expect(bookmarkOnly.uploadedAt, 1690000000100);
    expect(bookmarkOnly.raw['bookmark'], isTrue);
    expect(bookmarkOnly.raw['date_fetch'], 1700000000100);

    final OnlineMangaChapter read = entry.chapters[1];
    expect(read.key, '/chapter/a2');
    expect(read.scanlator, 'Scan B');
    expect(read.number, 2.5);
    expect(read.uploadedAt, 1690000000200);
    expect(read.raw['read'], isTrue);
    expect(read.raw['last_page_read'], 7);
    expect(read.raw['date_fetch'], 1700000000200);

    final Map<String, MangaChapterStateRow> states = await db
        .getMangaChapterStates(book.uid);
    expect(states, hasLength(1));
    expect(states['/chapter/a2']!.lastPage, 7);
    expect(states['/chapter/a2']!.readAt, 1700000009000);

    final ReaderPositionRow? position = await db.getReaderPosition(book.uid);
    expect(position, isNotNull);
    expect(position!.updatedAt, 1700000009000);
  });

  test('imports history into media_open_history', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[FixtureSource(id: 123, name: 'Source A')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          author: 'Author A',
          chapters: <FixtureChapter>[
            FixtureChapter(url: '/chapter/a1', name: 'Chapter 1'),
            FixtureChapter(url: '/chapter/a2', name: 'Chapter 2'),
          ],
          history: <FixtureHistory>[
            FixtureHistory(
              url: '/chapter/a1',
              lastRead: 1700000001000,
              readDuration: 1000,
            ),
            FixtureHistory(
              url: '/chapter/a2',
              lastRead: 1700000009000,
              readDuration: 5000,
            ),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);
    expect(report.historyRowsWritten, 1);

    final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
    final EpubBookRow book = (await db.getEpubBook(meta.bookKey))!;
    final List<MediaOpenHistoryRow> history = await db.getAllMediaOpenHistory();
    expect(history, hasLength(1));
    final MediaOpenHistoryRow row = history.single;
    expect(row.mediaType, 'reader_media_type');
    expect(row.mediaSource, 'reader_manga');
    expect(row.mediaId, 'fushi://book/${book.bookKey}');
    expect(row.openedAt, 1700000009000);
    expect(row.duration, 2);
    expect(row.position, 1);
    final Map<String, Object?> snapshot =
        (jsonDecode(row.snapshotJson) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(snapshot['title'], 'Alpha');
    expect(snapshot['author'], 'Author A');
    final Map<String, Object?> mihonHistory =
        (snapshot['mihon_history'] as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(mihonHistory['chapter_url'], '/chapter/a2');
    expect(mihonHistory['read_duration'], 5000);

    // Re-import refreshes the same recent-history row instead of duplicating it.
    await service().importFile(backup);
    expect(await db.getAllMediaOpenHistory(), hasLength(1));
  });

  test('imports Bangumi tracking and skips unsupported trackers', () async {
    Future<File> fixture({required double progress, required int status}) =>
        writeFixtureBackup(
          tmp,
          name: 'tracking-${progress.toInt()}-$status.tachibk',
          mangas: <FixtureManga>[
            FixtureManga(
              source: 123,
              url: '/manga/alpha',
              title: 'Alpha',
              tracking: <FixtureTracking>[
                FixtureTracking(
                  syncId: 5,
                  mediaId: 4242,
                  title: 'Remote Alpha',
                  lastChapterRead: progress,
                  totalChapters: 40,
                  status: status,
                  startedReadingDate: 1700000001000,
                  finishedReadingDate: 1700000002000,
                ),
                const FixtureTracking(
                  syncId: 2,
                  mediaId: 99,
                  title: 'Alpha on AniList',
                  lastChapterRead: 3,
                ),
                const FixtureTracking(
                  syncId: 5,
                  mediaId: 0,
                  title: 'Broken Bangumi',
                ),
              ],
            ),
          ],
        );

    final MihonBackupImportReport first = await service().importFile(
      await fixture(progress: 12.5, status: 2),
    );
    expect(first.failedEntries, 0);
    expect(first.trackingMappingsImported, 1);
    expect(first.trackingMappingsMerged, 0);
    expect(first.trackingSkipped, 2);
    expect(first.trackingInvalidRemoteIds, 1);
    expect(first.unsupportedTrackers, hasLength(1));
    expect(first.unsupportedTrackers.single.syncId, 2);
    expect(first.unsupportedTrackers.single.name, 'AniList');
    expect(first.unsupportedTrackers.single.count, 1);

    final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
    final EpubBookRow book = (await db.getEpubBook(meta.bookKey))!;
    final List<MediaTrackingMappingRow> mappings = await db
        .select(db.mediaTrackingMappings)
        .get();
    expect(mappings, hasLength(1));
    final MediaTrackingMappingRow mapping = mappings.single;
    expect(mapping.provider, 'bangumi');
    expect(mapping.mediaType, 'book');
    expect(mapping.mediaKey, book.bookKey);
    expect(mapping.mediaTitle, 'Alpha');
    expect(mapping.kind, 'manga');
    expect(mapping.subjectId, 4242);
    expect(mapping.subjectName, 'Remote Alpha');
    expect(mapping.progressMode, 'chapter');
    expect(mapping.progressOffset, 0);
    expect(mapping.createdAt, 1700000001000);
    expect(mapping.updatedAt, 1700000002000);

    final List<MediaTrackingOutboxRow> outbox = await db
        .select(db.mediaTrackingOutbox)
        .get();
    expect(outbox, hasLength(1));
    expect(outbox.single.mappingId, mapping.id);
    expect(outbox.single.progress, 12);
    expect(outbox.single.completed, isTrue);

    // Re-import: no duplicate rows; progress is monotonic (12 -> 20) and the
    // completed flag never regresses even when the backup says "reading".
    final MihonBackupImportReport second = await service().importFile(
      await fixture(progress: 20, status: 1),
    );
    expect(second.trackingMappingsImported, 0);
    expect(second.trackingMappingsMerged, 1);
    expect(await db.select(db.mediaTrackingMappings).get(), hasLength(1));
    final List<MediaTrackingOutboxRow> mergedOutbox = await db
        .select(db.mediaTrackingOutbox)
        .get();
    expect(mergedOutbox, hasLength(1));
    expect(mergedOutbox.single.progress, 20);
    expect(mergedOutbox.single.completed, isTrue);
  });

  test('imports extension stores and merges repeats', () async {
    Future<File> fixture({required bool changed}) => writeFixtureBackup(
      tmp,
      name: changed ? 'stores-2.tachibk' : 'stores-1.tachibk',
      mangas: const <FixtureManga>[],
      extensionStores: <FixtureExtensionStore>[
        FixtureExtensionStore(
          indexUrl: 'https://example.test/index.pb',
          name: changed ? 'Example Renamed' : 'Example',
          badgeLabel: changed ? null : 'Ex',
          signingKey: changed ? '' : 'key-1',
          contactWebsite: changed ? '' : 'https://example.test',
          contactDiscord: changed ? null : 'discord-1',
          isLegacy: false,
          extensionListUrl: changed ? null : 'https://example.test/list',
        ),
        const FixtureExtensionStore(
          indexUrl: 'https://legacy.test/index.min.json',
          name: 'Legacy',
          isLegacy: true,
        ),
        const FixtureExtensionStore(indexUrl: '   ', name: 'Broken'),
        if (changed)
          const FixtureExtensionStore(
            indexUrl: 'https://third.test/repo.json',
            name: 'Third',
          ),
      ],
    );

    final MihonBackupImportReport first = await service().importFile(
      await fixture(changed: false),
    );
    expect(first.extensionStoresImported, 2);
    expect(first.extensionStoresMerged, 0);
    expect(first.extensionStoresSkipped, 1);

    List<MangaExtensionStoreRow> stores = await db.getMangaExtensionStores(
      mediaKind: 'manga',
    );
    expect(stores, hasLength(2));
    final MangaExtensionStoreRow example = stores.singleWhere(
      (MangaExtensionStoreRow row) =>
          row.indexUrl == 'https://example.test/index.pb',
    );
    expect(example.name, 'Example');
    expect(example.badgeLabel, 'Ex');
    expect(example.signingKey, 'key-1');
    expect(example.format, 'currentProtobuf');
    expect(example.extensionListUrl, 'https://example.test/list');
    expect(example.enabled, isTrue);
    expect(example.mediaKind, 'manga');
    expect(example.sortOrder, 0);
    final Map<String, Object?> contact =
        (jsonDecode(example.contactJson!) as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(contact['website'], 'https://example.test');
    expect(contact['discord'], 'discord-1');
    expect(
      stores
          .singleWhere(
            (MangaExtensionStoreRow row) =>
                row.indexUrl == 'https://legacy.test/index.min.json',
          )
          .format,
      'legacy',
    );

    // Simulate local sync state that a re-import must not wipe.
    await db.customStatement(
      "UPDATE manga_extension_stores SET etag = 'abc', last_sync_at = 7 "
      "WHERE index_url = 'https://example.test/index.pb'",
    );

    final MihonBackupImportReport second = await service().importFile(
      await fixture(changed: true),
    );
    expect(second.extensionStoresImported, 1);
    expect(second.extensionStoresMerged, 2);
    expect(second.extensionStoresSkipped, 1);
    stores = await db.getMangaExtensionStores(mediaKind: 'manga');
    expect(stores, hasLength(3));
    final MangaExtensionStoreRow renamed = stores.singleWhere(
      (MangaExtensionStoreRow row) =>
          row.indexUrl == 'https://example.test/index.pb',
    );
    expect(renamed.name, 'Example Renamed');
    expect(renamed.etag, 'abc', reason: 'local sync state survives merge');
    expect(renamed.lastSyncAt, 7);
    expect(renamed.sortOrder, 0);
    expect(
      renamed.badgeLabel,
      'Ex',
      reason: 'omitted backup fields do not erase',
    );
    expect(renamed.signingKey, 'key-1');
    expect(renamed.extensionListUrl, 'https://example.test/list');
    expect(renamed.contactJson, example.contactJson);
    expect(
      stores.map((MangaExtensionStoreRow row) => row.indexUrl).toSet(),
      <String>{
        'https://example.test/index.pb',
        'https://legacy.test/index.min.json',
        'https://third.test/repo.json',
      },
    );
  });

  test(
    'imports source preferences for installed and missing sources',
    () async {
      await db
          .into(db.mangaOnlineSources)
          .insert(
            MangaOnlineSourcesCompanion.insert(
              extensionPackage: 'com.example.ext',
              sourceId: '123',
              name: 'Installed Source',
              language: 'en',
            ),
          );

      Future<File> fixture({required String username}) => writeFixtureBackup(
        tmp,
        name: 'prefs-$username.tachibk',
        mangas: const <FixtureManga>[],
        sourcePreferences: <FixtureSourcePreferences>[
          FixtureSourcePreferences(
            sourceKey: 'source_123',
            prefs: <FixturePreference>[
              FixturePreference(
                key: 'username',
                type: FixturePreferenceType.stringValue,
                value: username,
              ),
              FixturePreference(
                key: 'enabled',
                type: FixturePreferenceType.booleanValue,
                value: true,
              ),
              FixturePreference(
                key: 'domains',
                type: FixturePreferenceType.stringSetValue,
                value: <String>['a.test', 'b.test'],
              ),
              FixturePreference(
                key: 'retries',
                type: FixturePreferenceType.intValue,
                value: 3,
              ),
              FixturePreference(
                key: 'rate',
                type: FixturePreferenceType.floatValue,
                value: 1.5,
              ),
            ],
          ),
          const FixtureSourcePreferences(
            sourceKey: 'source_456',
            prefs: <FixturePreference>[
              FixturePreference(
                key: 'api_key',
                type: FixturePreferenceType.stringValue,
                value: 'secret',
              ),
            ],
          ),
          const FixtureSourcePreferences(
            sourceKey: 'not_a_source_key',
            prefs: <FixturePreference>[
              FixturePreference(
                key: 'ignored',
                type: FixturePreferenceType.stringValue,
                value: 'x',
              ),
            ],
          ),
        ],
      );

      final MihonBackupImportReport first = await service().importFile(
        await fixture(username: 'reader'),
      );
      expect(first.sourcePreferencesImported, 6);
      expect(first.sourcePreferencesForMissingSources, 1);
      expect(first.sourcePreferencesSkipped, 1);
      expect(first.failedEntries, 0);

      final List<MangaSourcePreferenceRow> prefs = await db
          .select(db.mangaSourcePreferences)
          .get();
      expect(prefs, hasLength(6));
      final Map<String, MangaSourcePreferenceRow> byKey =
          <String, MangaSourcePreferenceRow>{
            for (final MangaSourcePreferenceRow row in prefs)
              '${row.extensionPackage}:${row.sourceId}:${row.preferenceKey}':
                  row,
          };
      expect(byKey['com.example.ext:123:username']!.valueJson, '"reader"');
      expect(byKey['com.example.ext:123:username']!.preferenceType, 'text');
      expect(byKey['com.example.ext:123:enabled']!.preferenceType, 'checkBox');
      expect(byKey['com.example.ext:123:enabled']!.valueJson, 'true');
      expect(
        byKey['com.example.ext:123:domains']!.preferenceType,
        'multiSelect',
      );
      expect(
        jsonDecode(byKey['com.example.ext:123:domains']!.valueJson),
        <String>['a.test', 'b.test'],
      );
      expect(
        byKey['com.example.ext:123:retries']!.preferenceType,
        'unsupported',
      );
      expect(byKey['com.example.ext:123:retries']!.valueJson, '3');
      expect(byKey['com.example.ext:123:rate']!.preferenceType, 'unsupported');
      expect(byKey['com.example.ext:123:rate']!.valueJson, '1.5');
      expect(
        byKey['$kUnavailableMihonExtensionPackage:456:api_key']!.valueJson,
        '"secret"',
      );

      final MihonBackupSourceIssue missing = first.missingSources.singleWhere(
        (MihonBackupSourceIssue issue) => issue.sourceId == 456,
      );
      expect(missing.preferenceCount, 1);
      expect(missing.entryCount, 0);

      // Installing the previously-missing source: re-import moves its
      // preferences to the real package and removes the placeholder rows.
      await db
          .into(db.mangaOnlineSources)
          .insert(
            MangaOnlineSourcesCompanion.insert(
              extensionPackage: 'com.other.ext',
              sourceId: '456',
              name: 'Installed Later',
              language: 'en',
            ),
          );

      final MihonBackupImportReport second = await service().importFile(
        await fixture(username: 'changed'),
      );
      expect(second.sourcePreferencesImported, 6);
      expect(second.sourcePreferencesForMissingSources, 0);
      expect(second.missingSources, isEmpty);
      final List<MangaSourcePreferenceRow> after = await db
          .select(db.mangaSourcePreferences)
          .get();
      expect(after, hasLength(6), reason: 'no duplicate preference rows');
      expect(
        after
            .singleWhere(
              (MangaSourcePreferenceRow row) =>
                  row.extensionPackage == 'com.example.ext' &&
                  row.preferenceKey == 'username',
            )
            .valueJson,
        '"changed"',
      );
      expect(
        after
            .singleWhere(
              (MangaSourcePreferenceRow row) => row.sourceId == '456',
            )
            .extensionPackage,
        'com.other.ext',
      );
      expect(
        after.where(
          (MangaSourcePreferenceRow row) =>
              row.extensionPackage == kUnavailableMihonExtensionPackage,
        ),
        isEmpty,
      );
    },
  );

  test(
    'uses the installed extension package when the source is known',
    () async {
      await db
          .into(db.mangaOnlineSources)
          .insert(
            MangaOnlineSourcesCompanion.insert(
              extensionPackage: 'com.example.ext',
              sourceId: '123',
              name: 'Installed Source',
              language: 'en',
            ),
          );

      final File backup = await writeFixtureBackup(
        tmp,
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(source: 123, url: '/manga/alpha', title: 'Alpha'),
        ],
      );
      final MihonBackupImportReport report = await service().importFile(backup);

      expect(report.importedEntries, 1);
      expect(report.missingSources, isEmpty);
      final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
      final EpubBookRow row = (await db.getEpubBook(meta.bookKey))!;
      expect(
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!.extensionPackage,
        'com.example.ext',
      );
    },
  );
}
