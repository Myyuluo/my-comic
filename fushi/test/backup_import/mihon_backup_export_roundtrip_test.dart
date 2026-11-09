import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/backup_export/mihon_backup_exporter.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_service.dart';
import 'package:fushi/src/backup_import/mihon_backup_parser.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
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

  test('exports library manga + chapters and the importer restores them',
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
    final MihonBackupExportReport report = await MihonBackupExporter(
      database: db,
    ).exportToFile(
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
    expect(
      target.readAsBytesSync().take(2).toList(),
      <int>[0x1f, 0x8b],
      reason: 'backup files are gzip-compressed',
    );
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

    expect(
      parsed.sourceNames,
      <int, String>{123: 'Source A', 456: 'Source B'},
    );

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
  });

  test('includeHistory exports one recent history per library manga', () async {
    await _seedSource(db, sourceId: '123', name: 'Source A');
    final EpubBookRow alpha = await _seedManga(
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
        OnlineMangaChapter(
          key: '/chapter/a2',
          name: 'Chapter 2',
          raw: <String, Object?>{'url': '/chapter/a2'},
        ),
      ],
    );
    await db.importMangaChapterState(
      bookUid: alpha.uid,
      chapterKey: '/chapter/a1',
      lastPage: 3,
      readAt: 1700000001000,
      updatedAt: 1700000001000,
    );
    await db.importMangaChapterState(
      bookUid: alpha.uid,
      chapterKey: '/chapter/a2',
      lastPage: 9,
      updatedAt: 1700000009000,
    );
    final OnlineMangaLibraryEntry entry = _entryOf(alpha);
    await _insertHistory(
      db,
      mediaSource: mangaHistoryOnlineSourceKey(entry),
      mediaId: '/manga/alpha',
      openedAt: 1700000050000,
      snapshotJson: jsonEncode(<String, Object?>{'title': 'Alpha'}),
    );

    final File target = File(p.join(tmp.path, 'with-history.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: false,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    final MihonBackupManga exported = parsed.mangas.single;
    expect(exported.favorite, isTrue);
    expect(exported.history, hasLength(1));
    expect(exported.history.single.url, '/chapter/a2');
    expect(exported.history.single.lastRead, 1700000050000);
    expect(exported.history.single.readDuration, 0);
  });

  test('includeHistory=false writes no library history', () async {
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
    await _insertHistory(
      db,
      mediaSource:
          'manga_online:["mihon","org.example.ext","123"]',
      mediaId: '/manga/alpha',
      openedAt: 1700000050000,
      snapshotJson: jsonEncode(<String, Object?>{'title': 'Alpha'}),
    );

    final File target = File(p.join(tmp.path, 'no-history.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: false,
        includeAllRead: false,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(parsed.mangas.single.history, isEmpty);
  });

  test('includeAllRead exports non-library read works as favorite=false', () async {
    await _seedSource(db, sourceId: '456', name: 'Source B');
    await _insertHistory(
      db,
      mediaSource: 'manga_online:["mihon","org.example.ext","456"]',
      mediaId: '/manga/beta',
      openedAt: 1700000099000,
      snapshotJson: jsonEncode(<String, Object?>{
        'title': 'Beta',
        'author': 'Author B',
        'imageUrl': 'https://example.test/beta.jpg',
        'mangaHistory': <String, Object?>{
          'kind': 'manga-history',
          'online': <String, Object?>{
            'runtime': 'mihon',
            'extensionPackage': 'org.example.ext',
            'sourceId': '456',
            'seriesKey': '/manga/beta',
            'coverUrl': 'https://example.test/beta.jpg',
            'raw': <String, Object?>{
              'url': '/manga/beta',
              'title': 'Beta',
              'author': 'Author B',
              'artist': 'Artist B',
              'genre': 'Action, Drama',
              'status': 2,
            },
          },
        },
        'mihon_history': <String, Object?>{
          'chapter_url': '/chapter/b1',
          'read_at': 1700000099000,
          'read_duration': 12000,
        },
      }),
    );

    final File target = File(p.join(tmp.path, 'all-read.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: true,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    final MihonBackupManga beta = parsed.mangas.single;
    expect(beta.favorite, isFalse);
    expect(beta.source, 456);
    expect(beta.url, '/manga/beta');
    expect(beta.title, 'Beta');
    expect(beta.author, 'Author B');
    expect(beta.artist, 'Artist B');
    expect(beta.genres, <String>['Action', 'Drama']);
    expect(beta.status, 2);
    expect(beta.thumbnailUrl, 'https://example.test/beta.jpg');
    expect(beta.chapters, isEmpty);
    expect(beta.history, hasLength(1));
    expect(beta.history.single.url, '/chapter/b1');
    expect(beta.history.single.lastRead, 1700000099000);
    expect(beta.history.single.readDuration, 12000);
    expect(parsed.sourceNames, <int, String>{456: 'Source B'});
  });

  test('includeAllRead without a chapter URL exports metadata only', () async {
    await _insertHistory(
      db,
      mediaSource: 'manga_online:["mihon","org.example.ext","456"]',
      mediaId: '/manga/beta',
      openedAt: 1700000099000,
      snapshotJson: jsonEncode(<String, Object?>{
        'title': 'Beta',
        'author': 'Author B',
        'imageUrl': 'https://example.test/beta.jpg',
        'mangaHistory': <String, Object?>{
          'kind': 'manga-history',
          'online': <String, Object?>{
            'runtime': 'mihon',
            'extensionPackage': 'org.example.ext',
            'sourceId': '456',
            'seriesKey': '/manga/beta',
            'coverUrl': 'https://example.test/beta.jpg',
            'raw': <String, Object?>{'url': '/manga/beta'},
          },
        },
      }),
    );

    final File target = File(p.join(tmp.path, 'all-read-metadata.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: true,
      ),
    );

    final MihonBackupManga beta = MihonBackupParser.parseFile(
      target,
    ).mangas.single;
    expect(beta.favorite, isFalse);
    expect(beta.url, '/manga/beta');
    expect(beta.title, 'Beta');
    expect(beta.chapters, isEmpty);
    expect(
      beta.history,
      isEmpty,
      reason: 'no chapter URL means no honest history link',
    );
  });

  test('includeAllRead=false writes no read-only works', () async {
    await _insertHistory(
      db,
      mediaSource: 'manga_online:["mihon","org.example.ext","456"]',
      mediaId: '/manga/beta',
      openedAt: 1700000099000,
      snapshotJson: jsonEncode(<String, Object?>{
        'title': 'Beta',
        'mangaHistory': <String, Object?>{
          'kind': 'manga-history',
          'online': <String, Object?>{
            'runtime': 'mihon',
            'extensionPackage': 'org.example.ext',
            'sourceId': '456',
            'seriesKey': '/manga/beta',
            'raw': <String, Object?>{'url': '/manga/beta'},
          },
        },
      }),
    );

    final File target = File(p.join(tmp.path, 'no-read-only.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: false,
      ),
    );

    expect(MihonBackupParser.parseFile(target).mangas, isEmpty);
  });

  test('includeAllRead does not duplicate a library work', () async {
    final EpubBookRow alpha = await _seedManga(
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
    await _insertHistory(
      db,
      mediaSource: mangaHistoryOnlineSourceKey(_entryOf(alpha)),
      mediaId: '/manga/alpha',
      openedAt: 1700000050000,
      snapshotJson: jsonEncode(<String, Object?>{'title': 'Alpha'}),
    );

    final File target = File(p.join(tmp.path, 'no-duplicate.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: true,
      ),
    );

    final MihonBackupData parsed = MihonBackupParser.parseFile(target);
    expect(parsed.mangas, hasLength(1));
    expect(parsed.mangas.single.favorite, isTrue);
    expect(parsed.mangas.single.url, '/manga/alpha');
  });

  test('history and all-read are not exported without the library section',
      () async {
    final EpubBookRow alpha = await _seedManga(
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
    await _insertHistory(
      db,
      mediaSource: mangaHistoryOnlineSourceKey(_entryOf(alpha)),
      mediaId: '/manga/alpha',
      openedAt: 1700000050000,
      snapshotJson: jsonEncode(<String, Object?>{'title': 'Alpha'}),
    );

    final File target = File(p.join(tmp.path, 'dependent.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: false,
        includeChapters: true,
        includeHistory: true,
        includeAllRead: true,
      ),
    );

    expect(MihonBackupParser.parseFile(target).mangas, isEmpty);
  });

  test('includeChapters=false writes no chapters but keeps history', () async {
    final EpubBookRow alpha = await _seedManga(
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
    await db.importMangaChapterState(
      bookUid: alpha.uid,
      chapterKey: '/chapter/a1',
      lastPage: 4,
      updatedAt: 1700000001000,
    );
    await _insertHistory(
      db,
      mediaSource: mangaHistoryOnlineSourceKey(_entryOf(alpha)),
      mediaId: '/manga/alpha',
      openedAt: 1700000050000,
      snapshotJson: jsonEncode(<String, Object?>{'title': 'Alpha'}),
    );
    final File target = File(p.join(tmp.path, 'no-chapters.tachibk'));
    await MihonBackupExporter(database: db).exportToFile(
      target: target,
      options: const MihonBackupExportOptions(
        includeLibrary: true,
        includeChapters: false,
        includeHistory: true,
        includeAllRead: false,
      ),
    );

    final MihonBackupManga exported = MihonBackupParser.parseFile(
      target,
    ).mangas.single;
    expect(exported.chapters, isEmpty);
    expect(exported.history.single.url, '/chapter/a1');
  });

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
    final MihonBackupExportReport report = await MihonBackupExporter(
      database: db,
    ).exportToFile(
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

OnlineMangaLibraryEntry _entryOf(EpubBookRow row) =>
    OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;

Future<void> _insertHistory(
  FushiDatabase db, {
  required String mediaSource,
  required String mediaId,
  required int openedAt,
  required String snapshotJson,
}) async {
  await db.into(db.mediaOpenHistory).insert(
    MediaOpenHistoryCompanion.insert(
      mediaType: 'reader_media_type',
      mediaSource: mediaSource,
      mediaId: mediaId,
      openedAt: Value<int>(openedAt),
      snapshotJson: Value<String>(snapshotJson),
    ),
  );
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
