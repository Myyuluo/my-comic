import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_adjacent_chapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

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

  MihonBackupImportService service({
    Directory? downloadsRoot,
    Directory? localComicRoot,
  }) => MihonBackupImportService(
    database: db,
    downloadsRoot: downloadsRoot,
    localComicRoot: localComicRoot,
    bookDirectory: (String bookKey) async {
      final Directory dir = Directory(p.join(tmp.path, 'books', bookKey));
      await dir.create(recursive: true);
      return dir.path;
    },
    now: () => now,
  );

  MangaPagesManifest manifestFor(
    String chapterKey,
    String chapterName, {
    String sourceId = '1',
    String mangaKey = '/manga/x',
    String mangaTitle = 'X',
  }) => MangaPagesManifest(
    sourceRuntime: 'mihon',
    sourceId: sourceId,
    sourceName: 'Example',
    extensionPackage: 'org.example.fixture',
    mangaKey: mangaKey,
    mangaTitle: mangaTitle,
    chapterKey: chapterKey,
    chapterName: chapterName,
    payload: const MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: '001.jpg',
          size: MokuroSize(100, 150),
          blocks: <MokuroBlock>[],
        ),
      ],
    ),
    downloadedAt: DateTime.utc(2026, 11, 7),
  );

  Future<Directory> writeChapter(
    Directory mangaDir,
    String folderName, {
    required String chapterKey,
    String chapterName = 'Chapter',
    String sourceId = '1',
    String mangaKey = '/manga/x',
  }) async {
    final Directory chapterDir = Directory(p.join(mangaDir.path, folderName));
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsString('page');
    await writePagesManifestAtomically(
      chapterDir,
      manifestFor(
        chapterKey,
        chapterName,
        sourceId: sourceId,
        mangaKey: mangaKey,
      ),
    );
    return chapterDir;
  }

  test('imports library entries, categories as tags and progress', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      categories: const <FixtureCategory>[
        FixtureCategory(name: 'Action', order: 0, id: 10),
        FixtureCategory(name: 'Drama', order: 1, id: 20),
        // Blank category names cannot become Tags and are reported as skipped.
        FixtureCategory(name: '   ', order: 9, id: 30),
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
    expect(report.nonLibraryEntriesImported, 1);
    expect(report.mergedEntries, 0);
    expect(report.skippedEntries, 0);
    expect(report.failedEntries, 0);
    expect(report.categoriesCreated, 2);
    expect(report.categoriesSkipped, 1);
    expect(report.chapterStatesWritten, 4);
    expect(
      report.missingSources.map((MihonBackupSourceIssue s) => s.sourceId),
      <int>{123, 456},
    );

    final List<EpubBookRow> books = <EpubBookRow>[
      for (final EpubBookMeta meta in await db.getEpubBookMetas())
        (await db.getEpubBook(meta.bookKey))!,
    ];
    expect(books, hasLength(3));
    expect(books.map((EpubBookRow b) => b.format), everyElement('manga'));
    // Only favorite=true entries belong to the shelf.
    expect(
      books
          .where((EpubBookRow b) => b.inLibrary)
          .map((EpubBookRow b) => b.title)
          .toSet(),
      <String>{'Alpha', 'Beta'},
    );

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
    'fills missing MyComic app settings without overwriting local values',
    () async {
      await db.setPrefs(<String, String>{
        'shelf_sort_mode': PrefCodec.encode('author'),
      });

      final File backup = await writeFixtureBackup(
        tmp,
        mangas: const <FixtureManga>[],
        preferences: <FixturePreference>[
          // Locally present: the backup must not overwrite it.
          const FixturePreference(
            key: 'shelf_sort_mode',
            type: FixturePreferenceType.stringValue,
            value: 'title',
          ),
          const FixturePreference(
            key: 'auto_search',
            type: FixturePreferenceType.booleanValue,
            value: false,
          ),
          const FixturePreference(
            key: 'popup_dictionary_columns',
            type: FixturePreferenceType.intValue,
            value: 3,
          ),
          const FixturePreference(
            key: 'srs_mining_deck_id',
            type: FixturePreferenceType.longValue,
            value: 1700000000123,
          ),
          const FixturePreference(
            key: 'floating_lyric_font_size',
            type: FixturePreferenceType.floatValue,
            value: 20.5,
          ),
          const FixturePreference(
            key: 'audio_sources',
            type: FixturePreferenceType.stringSetValue,
            value: <String>['https://a.test', 'https://b.test'],
          ),
          // Known dynamic key family: per-book audiobook position.
          const FixturePreference(
            key: 'audiobook_pos_book-1',
            type: FixturePreferenceType.intValue,
            value: 1234,
          ),
          // Known but device-local (AI provider config): belongs to the
          // exporting machine and must not be adopted here.
          const FixturePreference(
            key: 'ai_providers',
            type: FixturePreferenceType.stringValue,
            value: '[]',
          ),
          // Mihon's own key: MyComic must never write it into its settings.
          const FixturePreference(
            key: 'theme_mode',
            type: FixturePreferenceType.stringValue,
            value: 'dark',
          ),
        ],
      );

      final MihonBackupImportReport report = await service().importFile(backup);

      expect(report.appPreferencesImported, 6);
      expect(
        report.appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
            .alreadyPresent],
        1,
      );
      expect(
        report.appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
            .notMyComicKey],
        1,
      );
      expect(
        report.appPreferencesSkippedByReason[MihonBackupAppPreferenceSkipReason
            .deviceLocal],
        1,
      );

      final Map<String, String> prefs = await db.getAllPrefs();
      expect(
        PrefCodec.decode<String>(prefs['shelf_sort_mode']!, ''),
        'author',
        reason: 'an existing local value wins over the backup',
      );
      expect(PrefCodec.decode<bool>(prefs['auto_search']!, true), isFalse);
      expect(PrefCodec.decode<int>(prefs['popup_dictionary_columns']!, 0), 3);
      expect(
        PrefCodec.decode<int>(prefs['srs_mining_deck_id']!, 0),
        1700000000123,
      );
      expect(
        PrefCodec.decode<double>(prefs['floating_lyric_font_size']!, 0.0),
        closeTo(20.5, 1e-9),
      );
      expect(
        PrefCodec.decode<List<String>>(prefs['audio_sources']!, <String>[]),
        <String>['https://a.test', 'https://b.test'],
      );
      expect(PrefCodec.decode<int>(prefs['audiobook_pos_book-1']!, 0), 1234);
      expect(prefs.containsKey('theme_mode'), isFalse);
      expect(prefs.containsKey('ai_providers'), isFalse);
    },
  );

  test(
    'rejects an unknown app preference value type without writing data',
    () async {
      final File backup = await writeFixtureBackup(
        tmp,
        mangas: const <FixtureManga>[
          FixtureManga(source: 123, url: '/manga/alpha', title: 'Alpha'),
        ],
        preferences: const <FixturePreference>[
          FixturePreference(
            key: 'shelf_sort_mode',
            type: FixturePreferenceType.unsupportedValue,
            value: 'title',
          ),
        ],
      );

      await expectLater(
        service().importFile(backup),
        throwsA(isA<MihonBackupFormatException>()),
      );

      expect(await db.getEpubBookMetas(), isEmpty);
      expect(await db.getAllPrefs(), isEmpty);
    },
  );

  test(
    'rejects an unsupported app preference value type even on an unknown key, before any write',
    () async {
      final File backup = await writeFixtureBackup(
        tmp,
        categories: const <FixtureCategory>[
          FixtureCategory(name: 'Action', order: 0, id: 10),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(source: 123, url: '/manga/alpha', title: 'Alpha'),
        ],
        preferences: const <FixturePreference>[
          // Mihon's own key: previously skipped as not-MyComic without looking
          // at the value type, so an unsupported type slipped through.
          FixturePreference(
            key: 'theme_mode',
            type: FixturePreferenceType.unsupportedValue,
            value: 'dark',
          ),
        ],
      );

      await expectLater(
        service().importFile(backup),
        throwsA(isA<MihonBackupFormatException>()),
      );

      expect(
        await db.getAllTags(),
        isEmpty,
        reason: 'validation runs before Tag writes',
      );
      expect(await db.getEpubBookMetas(), isEmpty);
      expect(await db.getAllPrefs(), isEmpty);
    },
  );

  test(
    'rejects an unsupported source preference value type before any write',
    () async {
      final File backup = await writeFixtureBackup(
        tmp,
        categories: const <FixtureCategory>[
          FixtureCategory(name: 'Action', order: 0, id: 10),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(source: 123, url: '/manga/alpha', title: 'Alpha'),
        ],
        sourcePreferences: const <FixtureSourcePreferences>[
          FixtureSourcePreferences(
            sourceKey: 'source_123',
            prefs: <FixturePreference>[
              FixturePreference(
                key: 'unknown_shape',
                type: FixturePreferenceType.unsupportedValue,
                value: 'value',
              ),
            ],
          ),
        ],
      );

      await expectLater(
        service().importFile(backup),
        throwsA(isA<MihonBackupFormatException>()),
      );

      expect(
        await db.getAllTags(),
        isEmpty,
        reason: 'validation runs before Tag writes',
      );
      expect(await db.getEpubBookMetas(), isEmpty);
      expect(
        await db.select(db.mangaSourcePreferences).get(),
        isEmpty,
        reason: 'no source preference rows are written',
      );
    },
  );

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
      expect(second.nonLibraryEntriesImported, 0);
      expect(second.nonLibraryEntriesMerged, 1);
      expect(second.skippedEntries, 0);
      expect(second.failedEntries, 0);
      expect(second.categoriesCreated, 0);
      expect(second.categoriesMatched, 2);

      expect(await db.getAllEpubBooks(), hasLength(3));
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

  test('imports favorite=false entries as non-library rows', () async {
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
              dateFetch: 1700000001000,
            ),
          ],
          history: <FixtureHistory>[
            FixtureHistory(url: '/c/1', lastRead: 1700000002000),
          ],
        ),
      ],
    );
    final MihonBackupImportReport first = await service().importFile(onlyRead);

    expect(first.totalEntries, 1);
    expect(first.importedEntries, 0);
    expect(first.nonLibraryEntriesImported, 1);
    expect(first.skippedEntries, 0);
    expect(first.failedEntries, 0);
    // Non-library rows never enter the shelf.
    expect(await db.getLibraryEpubBooks(), isEmpty);
    expect(await db.getEpubBookMetas(), hasLength(1));

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.inLibrary, isFalse);
    expect(row.format, 'manga');
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    )!;
    expect(entry.series.key, '/manga/x');
    expect(entry.chapters, hasLength(1));

    // Chapters, read marks and progress belong to the non-library row.
    final Map<String, MangaChapterStateRow> states = await db
        .getMangaChapterStates(row.uid);
    expect(states, hasLength(1));
    expect(states['/c/1']!.lastPage, 3);
    expect(states['/c/1']!.readAt, 1700000002000);
    final ReaderPositionRow? position = await db.getReaderPosition(row.uid);
    expect(position, isNotNull);
    expect(position!.updatedAt, 1700000002000);

    // Re-import merges into the same non-library row.
    final MihonBackupImportReport second = await service().importFile(onlyRead);
    expect(second.nonLibraryEntriesImported, 0);
    expect(second.nonLibraryEntriesMerged, 1);
    expect(second.failedEntries, 0);
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.inLibrary, isFalse);
  });

  test(
    'auto-relinks matching downloads after import and reports the result',
    () async {
      final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
      final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
      final Directory mangaDir = Directory(
        p.join(downloadsRoot.path, 'Example', 'X'),
      );
      await writeChapter(mangaDir, 'Ch 1', chapterKey: '/c/1');
      await writeChapter(mangaDir, 'Ch 2', chapterKey: '/c/2');

      final File backup = await writeFixtureBackup(
        tmp,
        name: 'downloads-match.tachibk',
        sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 1,
            url: '/manga/x',
            title: 'X',
            favorite: false,
            chapters: <FixtureChapter>[
              FixtureChapter(url: '/c/1', name: 'C1'),
              FixtureChapter(url: '/c/2', name: 'C2'),
            ],
          ),
        ],
      );
      final MihonBackupImportReport report = await service(
        downloadsRoot: downloadsRoot,
        localComicRoot: localComicRoot,
      ).importFile(backup);

      expect(report.nonLibraryEntriesImported, 1);
      expect(report.downloadMangaMatched, 1);
      expect(report.downloadMangaSkipped, 0);
      expect(report.downloadChaptersRelinked, 2);

      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(p.equals(row.extractDir, mangaDir.path), isTrue);
      final Map<String, MangaChapterDirRow> mappings = await db
          .getMangaChapterDirRowsForBook(row.bookKey);
      expect(mappings.keys, <String>{'/c/1', '/c/2'});
      expect(mappings['/c/1']!.folderName, 'Ch 1');
      expect(mappings['/c/2']!.folderName, 'Ch 2');
      // The existing folder is reused: no `(2)` copy is created.
      expect(
        [
          for (final FileSystemEntity entity in await Directory(
            p.join(downloadsRoot.path, 'Example'),
          ).list().toList())
            p.basename(entity.path),
        ],
        <String>['X'],
      );
      // Auto re-link never creates a Library/shelf entry.
      expect(await db.getLibraryEpubBooks(), isEmpty);
    },
  );

  test('re-import keeps auto-linked downloads idempotent', () async {
    final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
    final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example', 'X'),
    );
    await writeChapter(mangaDir, 'Ch 1', chapterKey: '/c/1');
    await writeChapter(mangaDir, 'Ch 2', chapterKey: '/c/2');

    final File backup = await writeFixtureBackup(
      tmp,
      name: 'downloads-idempotent.tachibk',
      sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 1,
          url: '/manga/x',
          title: 'X',
          favorite: false,
          chapters: <FixtureChapter>[
            FixtureChapter(url: '/c/1', name: 'C1'),
            FixtureChapter(url: '/c/2', name: 'C2'),
          ],
        ),
      ],
    );
    final MihonBackupImportService importService = service(
      downloadsRoot: downloadsRoot,
      localComicRoot: localComicRoot,
    );

    final MihonBackupImportReport first = await importService.importFile(
      backup,
    );
    expect(first.downloadChaptersRelinked, 2);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    final Map<String, MangaChapterDirRow> firstMappings = await db
        .getMangaChapterDirRowsForBook(row.bookKey);

    final MihonBackupImportReport second = await importService.importFile(
      backup,
    );
    expect(second.nonLibraryEntriesImported, 0);
    expect(second.nonLibraryEntriesMerged, 1);
    expect(second.downloadMangaMatched, 1);
    expect(second.downloadChaptersRelinked, 0, reason: '已有相同映射时重复导入不应重写');

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    final Map<String, MangaChapterDirRow> secondMappings = await db
        .getMangaChapterDirRowsForBook(row.bookKey);
    expect(secondMappings.length, firstMappings.length);
    for (final String chapterKey in <String>['/c/1', '/c/2']) {
      expect(
        secondMappings[chapterKey]!.folderName,
        firstMappings[chapterKey]!.folderName,
      );
      expect(
        secondMappings[chapterKey]!.containerKind,
        firstMappings[chapterKey]!.containerKind,
      );
    }
  });

  test(
    'auto-relinks a local folder whose pages.json proves the identity',
    () async {
      final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
      final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
      final Directory mangaDir = Directory(p.join(localComicRoot.path, 'Y'));
      await writeChapter(
        mangaDir,
        'Ch 1',
        chapterKey: '/c/1',
        mangaKey: '/manga/y',
      );
      await writeChapter(
        mangaDir,
        'Ch 2',
        chapterKey: '/c/2',
        mangaKey: '/manga/y',
      );

      final File backup = await writeFixtureBackup(
        tmp,
        name: 'local-match.tachibk',
        sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 1,
            url: '/manga/y',
            title: 'Y',
            favorite: false,
            chapters: <FixtureChapter>[
              FixtureChapter(url: '/c/1', name: 'C1'),
              FixtureChapter(url: '/c/2', name: 'C2'),
            ],
          ),
        ],
      );
      final MihonBackupImportReport report = await service(
        downloadsRoot: downloadsRoot,
        localComicRoot: localComicRoot,
      ).importFile(backup);

      expect(report.downloadMangaMatched, 1);
      expect(report.downloadMangaSkipped, 0);
      expect(report.downloadChaptersRelinked, 2);

      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(p.equals(row.extractDir, mangaDir.path), isTrue);
      final Map<String, MangaChapterDirRow> mappings = await db
          .getMangaChapterDirRowsForBook(row.bookKey);
      expect(mappings.keys, <String>{'/c/1', '/c/2'});
      expect(mappings['/c/1']!.folderName, 'Ch 1');
      expect(mappings['/c/2']!.folderName, 'Ch 2');
      expect(await db.getLibraryEpubBooks(), isEmpty);
    },
  );

  test('does not match local folders without a manifest by title', () async {
    final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
    final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
    // Same title as the backup entry, but no pages.json proves the identity.
    final Directory chapterDir = Directory(
      p.join(localComicRoot.path, 'X', 'Ch 1'),
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsString('page');

    final File backup = await writeFixtureBackup(
      tmp,
      name: 'local-no-manifest.tachibk',
      sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 1,
          url: '/manga/x',
          title: 'X',
          favorite: false,
          chapters: <FixtureChapter>[FixtureChapter(url: '/c/1', name: 'C1')],
        ),
      ],
    );
    final MihonBackupImportReport report = await service(
      downloadsRoot: downloadsRoot,
      localComicRoot: localComicRoot,
    ).importFile(backup);

    expect(report.downloadMangaMatched, 0);
    expect(report.downloadMangaSkipped, 0);
    expect(report.downloadChaptersRelinked, 0);

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(p.isWithin(localComicRoot.path, row.extractDir), isFalse);
    expect(
      await db.getMangaChapterDirRowsForBook(row.bookKey),
      isEmpty,
      reason: '没有 manifest 的本地目录不按标题猜测关联',
    );
  });

  test(
    'auto-relinks a single-chapter local folder with root pages.json without a fake mapping',
    () async {
      final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
      final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
      final Directory mangaDir = Directory(
        p.join(localComicRoot.path, 'Single chapter'),
      );
      await mangaDir.create(recursive: true);
      await File(p.join(mangaDir.path, '001.jpg')).writeAsString('page');
      // Single-chapter local works keep pages.json at the manga folder root.
      await writePagesManifestAtomically(
        mangaDir,
        manifestFor('/c/1', 'C1', mangaKey: '/manga/x'),
      );

      final File backup = await writeFixtureBackup(
        tmp,
        name: 'local-root-manifest.tachibk',
        sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 1,
            url: '/manga/x',
            title: 'X',
            favorite: false,
            chapters: <FixtureChapter>[FixtureChapter(url: '/c/1', name: 'C1')],
          ),
        ],
      );
      final MihonBackupImportReport report = await service(
        downloadsRoot: downloadsRoot,
        localComicRoot: localComicRoot,
      ).importFile(backup);

      expect(report.downloadMangaMatched, 1, reason: '根 manifest 证明身份即算匹配');
      expect(
        report.downloadChaptersRelinked,
        0,
        reason: '根 manifest 不是章容器，不能计为已写入映射',
      );
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(p.equals(row.extractDir, mangaDir.path), isTrue);
      expect(
        await db.getMangaChapterDirRowsForBook(row.bookKey),
        isEmpty,
        reason: '不能写 <manga>/<manga> 这种不可用的章映射',
      );
    },
  );

  test(
    'skips when downloads and local each prove the same identity (no silent preference)',
    () async {
      final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
      final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
      await writeChapter(
        Directory(p.join(downloadsRoot.path, 'Example', 'X')),
        'Ch 1',
        chapterKey: '/c/1',
      );
      await writeChapter(
        Directory(p.join(localComicRoot.path, 'Y')),
        'Ch 1',
        chapterKey: '/c/1',
      );

      final File backup = await writeFixtureBackup(
        tmp,
        name: 'ambiguous-two-roots.tachibk',
        sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 1,
            url: '/manga/x',
            title: 'X',
            favorite: false,
            chapters: <FixtureChapter>[FixtureChapter(url: '/c/1', name: 'C1')],
          ),
        ],
      );
      final MihonBackupImportReport report = await service(
        downloadsRoot: downloadsRoot,
        localComicRoot: localComicRoot,
      ).importFile(backup);

      expect(report.downloadMangaMatched, 0);
      expect(
        report.downloadMangaSkipped,
        1,
        reason: '两个根各有一个匹配目录 = 歧义，必须跳过而不是偏向 downloads',
      );
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(
        await db.getMangaChapterDirRowsForBook(row.bookKey),
        isEmpty,
        reason: '歧义时不写任何映射',
      );
      expect(
        p.isWithin(downloadsRoot.path, row.extractDir),
        isFalse,
        reason: '歧义时不改指 extractDir',
      );
      expect(p.isWithin(localComicRoot.path, row.extractDir), isFalse);
    },
  );

  test('skips when several folders prove the same download identity', () async {
    final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
    final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
    final Directory first = Directory(
      p.join(downloadsRoot.path, 'Example', 'X'),
    );
    final Directory second = Directory(
      p.join(downloadsRoot.path, 'Example', 'X (2)'),
    );
    await writeChapter(first, 'Ch 1', chapterKey: '/c/1');
    await writeChapter(second, 'Ch 1', chapterKey: '/c/1');

    final File backup = await writeFixtureBackup(
      tmp,
      name: 'ambiguous-downloads.tachibk',
      sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 1,
          url: '/manga/x',
          title: 'X',
          favorite: false,
          chapters: <FixtureChapter>[FixtureChapter(url: '/c/1', name: 'C1')],
        ),
      ],
    );
    final MihonBackupImportReport report = await service(
      downloadsRoot: downloadsRoot,
      localComicRoot: localComicRoot,
    ).importFile(backup);

    expect(report.downloadMangaMatched, 0);
    expect(report.downloadMangaSkipped, 1);
    expect(report.downloadChaptersRelinked, 0);

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(
      await db.getMangaChapterDirRowsForBook(row.bookKey),
      isEmpty,
      reason: '多个候选目录时不得猜一个',
    );
  });

  test('relinks library entries as well, without adding extra rows', () async {
    final Directory downloadsRoot = Directory(p.join(tmp.path, 'downloads'));
    final Directory localComicRoot = Directory(p.join(tmp.path, 'local'));
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example', 'X'),
    );
    await writeChapter(mangaDir, 'Ch 1', chapterKey: '/c/1');

    final File backup = await writeFixtureBackup(
      tmp,
      name: 'library-downloads-match.tachibk',
      sources: const <FixtureSource>[FixtureSource(id: 1, name: 'Example')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 1,
          url: '/manga/x',
          title: 'X',
          chapters: <FixtureChapter>[FixtureChapter(url: '/c/1', name: 'C1')],
        ),
      ],
    );
    final MihonBackupImportReport report = await service(
      downloadsRoot: downloadsRoot,
      localComicRoot: localComicRoot,
    ).importFile(backup);

    expect(report.importedEntries, 1);
    expect(report.downloadMangaMatched, 1);
    expect(report.downloadChaptersRelinked, 1);
    // Exactly the imported Library row; auto-matching never inserts another.
    expect(await db.getLibraryEpubBooks(), hasLength(1));
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
  });

  test('accepts an empty backup', () async {
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

  test(
    'persists Mihon sourceOrder on imported chapters and chapter JSON',
    () async {
      final File backup = await writeFixtureBackup(
        tmp,
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            // 备份的章数组顺序不保证是「最新在前」；顺序只信 sourceOrder。
            chapters: <FixtureChapter>[
              FixtureChapter(
                url: '/chapter/a1',
                name: 'Chapter 1',
                chapterNumber: 1,
                sourceOrder: 2,
              ),
              FixtureChapter(
                url: '/chapter/a2',
                name: 'Chapter 2',
                chapterNumber: 2,
                sourceOrder: 1,
              ),
              FixtureChapter(
                url: '/chapter/a3',
                name: 'Chapter 3',
                chapterNumber: 3,
                sourceOrder: 0,
              ),
            ],
          ),
        ],
      );

      final MihonBackupImportReport report = await service().importFile(backup);
      expect(report.importedEntries, 1);

      final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
      final EpubBookRow book = (await db.getEpubBook(meta.bookKey))!;
      final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
        book.sourceMetadata,
      )!;
      expect(
        <String, int?>{
          for (final OnlineMangaChapter chapter in entry.chapters)
            chapter.key: chapter.sourceOrder,
        },
        <String, int?>{'/chapter/a1': 2, '/chapter/a2': 1, '/chapter/a3': 0},
      );
      expect(entry.chapters.map((OnlineMangaChapter c) => c.key), <String>[
        '/chapter/a1',
        '/chapter/a2',
        '/chapter/a3',
      ], reason: '导入保留备份数组顺序，排序由阅读/显示各自按 sourceOrder 做');

      final List<Object?> chapterJson =
          jsonDecode(book.chaptersJson) as List<Object?>;
      expect(
        chapterJson.map(
          (Object? item) => (item! as Map<String, Object?>)['sourceOrder'],
        ),
        <Object?>[2, 1, 0],
        reason: 'chaptersJson 与 sourceMetadata 必须同时带上 sourceOrder',
      );
    },
  );

  test('imported chapter order drives 1 → 2 → 3 reader switching', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[FixtureSource(id: 123, name: 'Source A')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 123,
          url: '/manga/alpha',
          title: 'Alpha',
          // 旧→新存储，sourceOrder 反着给（0 = 最新一话）。
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/a1',
              name: 'Chapter 1',
              chapterNumber: 1,
              sourceOrder: 2,
            ),
            FixtureChapter(
              url: '/chapter/a2',
              name: 'Chapter 2',
              chapterNumber: 2,
              sourceOrder: 1,
            ),
            FixtureChapter(
              url: '/chapter/a3',
              name: 'Chapter 3',
              chapterNumber: 3,
              sourceOrder: 0,
            ),
          ],
        ),
      ],
    );

    await service().importFile(backup);
    final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      (await db.getEpubBook(meta.bookKey))!.sourceMetadata,
    )!;
    final int a1 = entry.indexOfChapterKey('/chapter/a1');
    final int a2 = entry.indexOfChapterKey('/chapter/a2');
    final int a3 = entry.indexOfChapterKey('/chapter/a3');

    expect(
      resolveAdjacentMangaChapter(
        chapters: entry.chapters,
        currentIndex: a1,
        forward: true,
      ),
      a2,
      reason: '读完第 1 话进入第 2 话',
    );
    expect(
      resolveAdjacentMangaChapter(
        chapters: entry.chapters,
        currentIndex: a2,
        forward: true,
      ),
      a3,
      reason: '第 2 话进入第 3 话',
    );
    expect(
      resolveAdjacentMangaChapter(
        chapters: entry.chapters,
        currentIndex: a3,
        forward: true,
      ),
      isNull,
      reason: '只有真正最后一话才提示「已经是最新一章」',
    );
    expect(
      resolveAdjacentMangaChapter(
        chapters: entry.chapters,
        currentIndex: a2,
        forward: false,
      ),
      a1,
      reason: '往回翻进入上一话',
    );
  });

  test(
    're-import fills sourceOrder on existing chapters idempotently',
    () async {
      // 旧版本导入留下的描述符：章节没有 sourceOrder 字段。
      final OnlineMangaLibraryEntry legacy = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: kUnavailableMihonExtensionPackage,
        sourceId: '123',
        series: const OnlineMangaSeries(
          key: '/manga/alpha',
          title: 'Alpha',
          raw: <String, Object?>{'url': '/manga/alpha'},
        ),
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/a1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{'url': '/chapter/a1'},
          ),
        ],
      );
      final String bookKey = onlineMangaBookKeyFor(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: kUnavailableMihonExtensionPackage,
        sourceId: '123',
        seriesKey: '/manga/alpha',
      );
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Alpha',
          epubPath: 'manga.json',
          extractDir: p.join(tmp.path, 'books', bookKey),
          chapterCount: 1,
          chaptersJson: jsonEncode(<Map<String, Object?>>[
            for (final OnlineMangaChapter chapter in legacy.chapters)
              chapter.toJson(),
          ]),
          sourceMetadata: Value<String>(legacy.encode()),
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );

      final File backup = await writeFixtureBackup(
        tmp,
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            chapters: <FixtureChapter>[
              FixtureChapter(
                url: '/chapter/a1',
                name: 'Chapter 1',
                chapterNumber: 1,
                sourceOrder: 1,
              ),
              FixtureChapter(
                url: '/chapter/a2',
                name: 'Chapter 2',
                chapterNumber: 2,
                sourceOrder: 0,
              ),
            ],
          ),
        ],
      );

      final MihonBackupImportReport first = await service().importFile(backup);
      expect(first.importedEntries, 0);
      expect(first.mergedEntries, 1);
      expect(await db.getAllEpubBooks(), hasLength(1));

      Future<OnlineMangaLibraryEntry> stored() async =>
          OnlineMangaLibraryEntry.tryParse(
            ((await db.getEpubBook(bookKey))!).sourceMetadata,
          )!;
      expect(
        <String, int?>{
          for (final OnlineMangaChapter chapter in (await stored()).chapters)
            chapter.key: chapter.sourceOrder,
        },
        <String, int?>{'/chapter/a1': 1, '/chapter/a2': 0},
        reason: '已有章节补齐 sourceOrder，备份新增章节也带上',
      );
      final String chapterJsonAfterFirst = (await db.getEpubBook(
        bookKey,
      ))!.chaptersJson;
      expect(chapterJsonAfterFirst, contains('"sourceOrder":1'));
      expect(chapterJsonAfterFirst, contains('"sourceOrder":0'));

      final MihonBackupImportReport second = await service().importFile(backup);
      expect(second.importedEntries, 0);
      expect(second.mergedEntries, 1);
      expect(await db.getAllEpubBooks(), hasLength(1));
      expect((await stored()).chapters, hasLength(2));
      expect(
        <String, int?>{
          for (final OnlineMangaChapter chapter in (await stored()).chapters)
            chapter.key: chapter.sourceOrder,
        },
        <String, int?>{'/chapter/a1': 1, '/chapter/a2': 0},
        reason: '重复导入不重复建行、不改变已补齐的顺序',
      );
    },
  );

  test(
    'imports history with the canonical online identity and snapshot',
    () async {
      final File backup = await writeFixtureBackup(
        tmp,
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            author: 'Author A',
            thumbnailUrl: 'https://example.test/alpha.jpg',
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
      final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
        book.sourceMetadata,
      )!;
      final List<MediaOpenHistoryRow> history = await db
          .getAllMediaOpenHistory();
      expect(history, hasLength(1));
      final MediaOpenHistoryRow row = history.single;
      expect(row.mediaType, 'reader_media_type');
      // History identity is the same stable online identity the reader writes:
      // it survives leaving/rejoining the shelf and extension-package changes.
      expect(row.mediaSource, mangaHistoryOnlineSourceKey(entry));
      expect(row.mediaId, '/manga/alpha');
      expect(row.openedAt, 1700000009000);
      expect(row.duration, 2);
      expect(row.position, 1);
      final Map<String, Object?> snapshot =
          (jsonDecode(row.snapshotJson) as Map<Object?, Object?>)
              .cast<String, Object?>();
      expect(snapshot['title'], 'Alpha');
      expect(snapshot['author'], 'Author A');
      expect(snapshot['imageUrl'], 'https://example.test/alpha.jpg');
      final Map<String, Object?> marker =
          (snapshot['mangaHistory'] as Map<Object?, Object?>)
              .cast<String, Object?>();
      expect(marker['kind'], 'manga-history');
      expect(marker['bookKey'], book.bookKey);
      final Map<String, Object?> online =
          (marker['online'] as Map<Object?, Object?>).cast<String, Object?>();
      expect(online['runtime'], 'mihon');
      expect(online['sourceId'], '123');
      expect(online['seriesKey'], '/manga/alpha');
      expect(online['coverUrl'], 'https://example.test/alpha.jpg');
      final Map<String, Object?> mihonHistory =
          (snapshot['mihon_history'] as Map<Object?, Object?>)
              .cast<String, Object?>();
      expect(mihonHistory['chapter_url'], '/chapter/a2');
      expect(mihonHistory['read_duration'], 5000);

      // Re-import refreshes the same recent-history row instead of duplicating it.
      await service().importFile(backup);
      expect(await db.getAllMediaOpenHistory(), hasLength(1));
    },
  );

  test('restores read-only works as non-library rows with History', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[FixtureSource(id: 456, name: 'Source B')],
      mangas: const <FixtureManga>[
        FixtureManga(
          source: 456,
          url: '/manga/beta',
          title: 'Beta',
          author: 'Author B',
          thumbnailUrl: 'https://example.test/beta.jpg',
          favorite: false,
          chapters: <FixtureChapter>[
            FixtureChapter(
              url: '/chapter/b1',
              name: 'Chapter 1',
              read: true,
              lastPageRead: 4,
            ),
          ],
          history: <FixtureHistory>[
            FixtureHistory(
              url: '/chapter/b1',
              lastRead: 1700000099000,
              readDuration: 12000,
            ),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);

    expect(report.importedEntries, 0);
    expect(report.nonLibraryEntriesImported, 1);
    expect(report.skippedEntries, 0);
    expect(report.nonLibraryHistoryImported, 1);
    expect(await db.getLibraryEpubBooks(), isEmpty);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.inLibrary, isFalse);

    // The restored row is visible on the History page and keeps the metadata
    // needed to reopen the work's source page.
    final List<MangaHistoryEntry> entries = await loadMangaHistory(db);
    expect(entries, hasLength(1));
    final MangaHistoryEntry entry = entries.single;
    expect(entry.title, 'Beta');
    expect(entry.openedAt, 1700000099000);
    expect(entry.bookKey, row.bookKey);
    expect(entry.mediaId, '/manga/beta');
    expect(entry.coverUrl, 'https://example.test/beta.jpg');
    expect(entry.snapshot!.author, 'Author B');
    expect(entry.online, isNotNull);
    expect(entry.online!.runtime, OnlineMangaRuntimeKind.mihon);
    expect(entry.online!.sourceId, '456');
    expect(entry.online!.seriesKey, '/manga/beta');
    expect(
      entry.mediaSource,
      mangaHistoryOnlineSourceKey(
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!,
      ),
    );

    final MediaOpenHistoryRow historyRow =
        (await db.getAllMediaOpenHistory()).single;
    final Map<String, Object?> snapshot =
        (jsonDecode(historyRow.snapshotJson) as Map<Object?, Object?>)
            .cast<String, Object?>();
    final Map<String, Object?> marker =
        (snapshot['mangaHistory'] as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(marker['kind'], 'manga-history');
    expect(marker['bookKey'], row.bookKey);
    final Map<String, Object?> mihonHistory =
        (snapshot['mihon_history'] as Map<Object?, Object?>)
            .cast<String, Object?>();
    expect(mihonHistory['chapter_url'], '/chapter/b1');
    expect(mihonHistory['read_at'], 1700000099000);
    expect(mihonHistory['read_duration'], 12000);

    // Merge semantics: importing the same backup again keeps one row.
    final MihonBackupImportReport second = await service().importFile(backup);
    expect(second.nonLibraryEntriesImported, 0);
    expect(second.nonLibraryEntriesMerged, 1);
    expect(second.nonLibraryHistoryImported, 0);
    expect(
      second.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
          .alreadyNewer],
      1,
    );
    expect(await db.getAllMediaOpenHistory(), hasLength(1));
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('reports why read-only works restore no History', () async {
    final File backup = await writeFixtureBackup(
      tmp,
      sources: const <FixtureSource>[FixtureSource(id: 456, name: 'Source B')],
      mangas: const <FixtureManga>[
        // Read state without a History row: no read timestamp to restore.
        FixtureManga(
          source: 456,
          url: '/manga/no-history',
          title: 'No History',
          favorite: false,
          chapters: <FixtureChapter>[
            FixtureChapter(url: '/chapter/n1', name: 'Chapter 1', read: true),
          ],
        ),
        // History without a manga URL: nothing to attach it to.
        FixtureManga(
          source: 456,
          url: '   ',
          title: 'No URL',
          favorite: false,
          history: <FixtureHistory>[
            FixtureHistory(url: '/chapter/u1', lastRead: 1700000088000),
          ],
        ),
      ],
    );

    final MihonBackupImportReport report = await service().importFile(backup);

    expect(report.nonLibraryHistoryImported, 0);
    expect(report.nonLibraryEntriesImported, 1);
    expect(report.failedEntries, 1);
    expect(report.failedByReason[MihonBackupFailureReason.missingUrl], 1);
    expect(
      report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
          .noHistory],
      1,
    );
    expect(
      report.nonLibraryHistorySkippedByReason[MihonBackupHistorySkipReason
          .missingUrl],
      1,
    );
    expect(await db.getAllMediaOpenHistory(), isEmpty);
    // The readable entry still becomes a non-library row; only the URL-less
    // entry has no stable identity to persist.
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.inLibrary, isFalse);
    expect(row.title, 'No History');
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
