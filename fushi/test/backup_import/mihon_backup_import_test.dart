import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

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

  test('imports library entries, categories and reading progress', () async {
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

    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections.map((MediaCollectionRow c) => c.name).toSet(), <String>{
      'Action',
      'Drama',
    });
    final MediaCollectionRow action = collections.singleWhere(
      (MediaCollectionRow c) => c.name == 'Action',
    );
    final List<MediaCollectionItemRow> members = await db.getCollectionItems(
      action.id,
    );
    expect(members, hasLength(1));
    expect(members.single.mediaType, MediaKind.epub.dbValue);
    expect(members.single.entryKey, alpha.uid);
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
                      read: true,
                      lastPageRead: 8,
                      dateFetch: 1700000000500,
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

      final MihonBackupImportReport second = await service().importFile(
        await fixture(changed: true),
      );

      expect(second.totalEntries, 3);
      expect(second.importedEntries, 0);
      expect(second.mergedEntries, 2);
      expect(second.skippedEntries, 1);
      expect(second.failedEntries, 0);

      expect(await db.getEpubBookMetas(), hasLength(2));
      final String alphaKey = (await db.getEpubBookMetas())
          .singleWhere((EpubBookMeta meta) => meta.title == 'Alpha')
          .bookKey;
      final EpubBookRow alphaRow = (await db.getEpubBook(alphaKey))!;
      expect(alphaRow.title, 'Alpha', reason: 'local metadata wins on merge');

      final OnlineMangaLibraryEntry alphaEntry =
          OnlineMangaLibraryEntry.tryParse(alphaRow.sourceMetadata)!;
      expect(alphaEntry.chapters, hasLength(3));

      final Map<String, MangaChapterStateRow> states = await db
          .getMangaChapterStates(alphaRow.uid);
      expect(states['/chapter/a1']!.lastPage, 8);
      expect(states['/chapter/a2']!.lastPage, 6);
      expect(states['/chapter/a2']!.readAt, 1700000009000);
      expect(states['/chapter/a3']!.lastPage, 2);

      final MediaCollectionRow action = (await db.getAllMediaCollections())
          .singleWhere((MediaCollectionRow c) => c.name == 'Action');
      expect(await db.getCollectionItems(action.id), hasLength(1));
    },
  );

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
