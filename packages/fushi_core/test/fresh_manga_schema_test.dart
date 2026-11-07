import 'dart:io';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';

/// my-comic v1 的全新漫画-only schema。
///
/// 验收口径（ticket 05）：
///  - 首次运行只创建漫画域需要的表；Fushi 的旧表一张都不出现；
///  - `user_version` 从 1 开始，没有 Fushi 的 v1–v118 迁移阶梯；
///  - 目录里已有的 `fushi.db`（Fushi 旧库）不被读取、不被迁移、不被改写；
///  - Library / Category / History / Reading progress / Download / Local source
///    的数据在关库重开后仍然存在。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mycomic-schema-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  Future<FushiDatabase> open() async {
    final FushiDatabase db = FushiDatabase(tmp.path);
    // Force the lazy open so onCreate runs.
    await db.customSelect('SELECT 1').get();
    return db;
  }

  Future<Set<String>> userTables(FushiDatabase db) async {
    final List<QueryRow> rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name NOT LIKE 'sqlite_%'",
        )
        .get();
    return <String>{for (final QueryRow row in rows) row.read<String>('name')};
  }

  test(
    'fresh DB creates exactly the manga-only table set at schema v2',
    () async {
      final FushiDatabase db = await open();
      addTearDown(db.close);

      expect(db.schemaVersion, 2);
      final QueryRow version = await db
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.data['user_version'], 2);

      final Set<String> tables = await userTables(db);
      expect(
        tables,
        kMyComicSchemaTableNames,
        reason:
            'schema 只允许 my-comic 保留表；多一张即旧表回流，少一张即'
            '漫画功能缺表',
      );

      // 旧 Fushi 域的代表表一张都不能出现。
      for (final String legacy in <String>[
        'video_books',
        'video_download_jobs',
        'dictionary_metadata',
        'srs_entities',
        'galgames',
        'audiobooks',
        'audio_cues',
        'srt_books',
        'anki_mappings',
        'favorite_words',
        'mined_sentences',
        'study_segments_sync',
        'sync_baselines',
        'fushi_paired_peers',
        'book_custom_css',
        'bookmarks',
        'reading_statistics',
        'video_metadata_works',
      ]) {
        expect(tables, isNot(contains(legacy)), reason: '旧表 $legacy 不得被创建');
      }
    },
  );

  test(
    'v1 my-comic 库升级到 v2：补建 manga_chapter_dirs，旧数据保留',
    () async {
      final FushiDatabase db = await open();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'old-book',
          title: 'Old Manga',
          epubPath: 'manga.json',
          extractDir: p.join(tmp.path, 'books', 'old-book'),
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1700000000000,
          format: const Value('manga'),
        ),
      );
      // 模拟票 04 之前创建的 v1 库：没有 mapping 表。
      await db.customStatement('DROP TABLE manga_chapter_dirs');
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 2);
      expect((await upgraded.getEpubBook('old-book'))?.title, 'Old Manga');
      await upgraded.upsertMangaChapterDir(
        bookKey: 'old-book',
        chapterKey: 'chapter-1',
        folderName: 'Chapter 1',
        updatedAt: 1700000001000,
      );
      expect(
        (await upgraded.getMangaChapterDir('old-book', 'chapter-1'))?.folderName,
        'Chapter 1',
      );
    },
  );

  test(
    'an existing Fushi fushi.db is neither read nor migrated nor modified',
    () async {
      final File oldDb = File(p.join(tmp.path, fushiDatabaseFileName_legacy));
      final sqlite3.Database raw = sqlite3.sqlite3.open(oldDb.path);
      raw.execute('CREATE TABLE video_books (book_uid TEXT PRIMARY KEY)');
      raw.execute("INSERT INTO video_books VALUES ('legacy-video')");
      raw.execute('PRAGMA user_version = 118');
      raw.dispose();
      final List<int> before = await oldDb.readAsBytes();

      final FushiDatabase db = await open();
      addTearDown(db.close);

      final Set<String> tables = await userTables(db);
      expect(tables, isNot(contains('video_books')));
      expect(await oldDb.readAsBytes(), before, reason: '旧库必须原样保留，不读取、不迁移、不重写');
      expect(
        File(p.join(tmp.path, kMyComicDatabaseFileName)).existsSync(),
        isTrue,
        reason: 'my-comic 必须使用自己的库文件，不能落在 fushi.db 上',
      );
    },
  );

  test(
    'library, category, history, progress, download and local source persist',
    () async {
      final FushiDatabase db = await open();

      const String bookKey = 'manga:schema:test';
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Schema Test Manga',
          epubPath: 'manga.json',
          extractDir: p.join(tmp.path, 'books', bookKey),
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1700000000000,
          format: const Value('manga'),
        ),
      );
      final EpubBookRow book = (await db.getEpubBook(bookKey))!;

      // Category（Mihon Category 在本库对应合集；合集成员值域里漫画归 'epub'）
      final int collectionId = await db.createMediaCollection(
        'Schema Category',
      );
      await db.addToCollection(collectionId, MediaKind.epub, bookKey);

      // History
      await db.upsertMediaOpenHistory(
        MediaOpenHistoryCompanion.insert(
          mediaType: 'reader',
          mediaSource: 'reader_fushi',
          mediaId: bookKey,
          openedAt: const Value<int>(1700000001000),
        ),
      );

      // Reading progress
      await db.saveMangaChapterState(
        bookUid: book.uid,
        chapterKey: 'chapter-1',
        lastPage: 7,
        pageCount: 20,
        readAt: 1700000002000,
      );
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: book.uid,
          sectionIndex: 7,
          normCharOffset: 0,
          updatedAt: 1700000002000,
        ),
      );

      // Download
      await db.upsertMangaDownloadJob(
        MangaDownloadJobsCompanion.insert(
          jobId: 'job-1',
          kind: 'chapter',
          bookKey: bookKey,
          chapterKey: 'chapter-1',
          runtime: 'mihon',
          title: 'Schema Test Manga',
          chapterTitle: 'Chapter 1',
          status: const Value<String>('queued'),
          createdAt: 1700000003000,
          updatedAt: 1700000003000,
        ),
      );

      // Local source（EpubBooks 即本地漫画行；source_id 指向来源库）
      final int sourceId = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'Local Manga',
          mediaKind: 'manga',
          rootPath: p.join(tmp.path, 'local'),
          createdAt: 1700000004000,
        ),
      );

      await db.close();

      // Reopen: everything must still be there.
      final FushiDatabase reopened = await open();
      addTearDown(reopened.close);

      expect((await reopened.getEpubBook(bookKey))?.title, 'Schema Test Manga');
      expect(
        (await reopened.getMediaCollectionById(collectionId))?.name,
        'Schema Category',
      );
      expect(await reopened.getCollectionItems(collectionId), hasLength(1));
      expect(await reopened.getAllMediaOpenHistory(), hasLength(1));
      final MangaChapterStateRow? chapter = await reopened.getMangaChapterState(
        bookUid: book.uid,
        chapterKey: 'chapter-1',
      );
      expect(chapter?.lastPage, 7);
      expect((await reopened.getMangaDownloadJob('job-1'))?.status, 'queued');
      expect(
        (await reopened.getMediaSourceById(sourceId))?.label,
        'Local Manga',
      );
      expect(await reopened.getReaderPosition(book.uid), isNot(null));
    },
  );
}

/// Fushi 旧库文件名：只允许出现在“不被读取”的测试里。
const String fushiDatabaseFileName_legacy = 'fushi.db';
