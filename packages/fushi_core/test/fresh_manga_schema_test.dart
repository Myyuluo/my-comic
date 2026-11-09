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
    'fresh DB creates exactly the manga-only table set at current schema',
    () async {
      final FushiDatabase db = await open();
      addTearDown(db.close);

      expect(db.schemaVersion, 5);
      final QueryRow version = await db
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.data['user_version'], 5);

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
    'v1 my-comic 库升级到当前 schema：补建 manga_chapter_dirs（含容器类型），旧数据保留',
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
      // 模拟票 04 之前创建的 v1 库：没有 mapping 表，也还没有 Library
      // membership 列（v5 才加入）。
      await db.customStatement('DROP TABLE manga_chapter_dirs');
      await dropLibraryMembershipColumn(db);
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 5);
      expect((await upgraded.getEpubBook('old-book'))?.title, 'Old Manga');
      expect(
        (await upgraded.getEpubBook('old-book'))?.inLibrary,
        isTrue,
        reason: '升级前已存在的行迁移为在书架',
      );
      await upgraded.upsertMangaChapterDir(
        bookKey: 'old-book',
        chapterKey: 'chapter-1',
        folderName: 'Chapter 1',
        updatedAt: 1700000001000,
      );
      final MangaChapterDirRow? row = await upgraded.getMangaChapterDir(
        'old-book',
        'chapter-1',
      );
      expect(row?.folderName, 'Chapter 1');
      expect(row?.containerKindEnum, MangaChapterContainerKind.folder);
    },
  );

  test(
    'v2 my-comic 库升级到 v3：manga_chapter_dirs 增加 container_kind，已有行 = folder',
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
      // 模拟票 04 的 v2 库：manga_chapter_dirs 没有 container_kind 列，
      // 且已经有一条线上用户的目录映射。
      await db.customStatement('DROP TABLE manga_chapter_dirs');
      await db.customStatement(
        'CREATE TABLE manga_chapter_dirs ('
        'book_key TEXT NOT NULL, '
        'chapter_key TEXT NOT NULL, '
        'folder_name TEXT NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (book_key, chapter_key), '
        "CHECK (book_key != '' AND chapter_key != '' AND folder_name != ''), "
        'CHECK (updated_at >= 0))',
      );
      await db.customStatement(
        'INSERT INTO manga_chapter_dirs '
        '(book_key, chapter_key, folder_name, updated_at) '
        "VALUES ('old-book', 'chapter-1', 'Chapter 1', 1700000001000)",
      );
      await dropLibraryMembershipColumn(db);
      await db.customStatement('PRAGMA user_version = 2');
      await db.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 5);
      expect(
        (await upgraded.getEpubBook('old-book'))?.inLibrary,
        isTrue,
        reason: '升级前已存在的行迁移为在书架',
      );
      final MangaChapterDirRow? migrated = await upgraded.getMangaChapterDir(
        'old-book',
        'chapter-1',
      );
      expect(migrated?.folderName, 'Chapter 1');
      expect(
        migrated?.containerKindEnum,
        MangaChapterContainerKind.folder,
        reason: '升级前已存在的映射都是章节目录，迁移为 folder',
      );

      // 升级后可以记录压缩包容器。
      await upgraded.upsertMangaChapterDir(
        bookKey: 'old-book',
        chapterKey: 'chapter-2',
        folderName: 'Chapter 2.cbz',
        containerKind: MangaChapterContainerKind.archive,
        updatedAt: 1700000002000,
      );
      expect(
        (await upgraded.getMangaChapterDir(
          'old-book',
          'chapter-2',
        ))?.containerKindEnum,
        MangaChapterContainerKind.archive,
      );
    },
  );

  test(
    'v3 升级到当前：下载任务 status CHECK 放宽、membership 列补上，已有行保留',
    () async {
      final FushiDatabase db = await open();
      addTearDown(db.close);
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

      // 取 fresh 表的建表 SQL，去掉 status CHECK 里的 'paused'，还原成 v3 表。
      final String freshSql = (await db
              .customSelect(
                "SELECT sql FROM sqlite_master "
                "WHERE type = 'table' AND name = 'manga_download_jobs'",
              )
              .getSingle())
          .read<String>('sql');
      expect(freshSql, contains("'paused'"));
      final String v3Sql = freshSql.replaceFirst(", 'paused'", '');
      expect(v3Sql, isNot(contains("'paused'")));
      await db.customStatement('DROP TABLE manga_download_jobs');
      await db.customStatement(v3Sql);
      await db.customStatement(
        'INSERT INTO manga_download_jobs '
        '(job_id, kind, book_key, chapter_key, runtime, title, chapter_title, '
        'status, pages_done, pages_total, attempt_count, last_error, auto_ocr, '
        'created_at, updated_at, completed_at) '
        "VALUES ('legacy-job', 'chapter', 'book', 'chapter-1', 'mihon', "
        "'Manga', 'Chapter 1', 'failed', 1, 3, 3, 'boom', 0, "
        '1700000000000, 1700000000000, NULL)',
      );
      await dropLibraryMembershipColumn(db);
      await db.customStatement('PRAGMA user_version = 3');
      await db.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 5);
      expect(
        (await upgraded.getAllEpubBooks()).every(
          (EpubBookRow row) => row.inLibrary,
        ),
        isTrue,
        reason: '升级前已存在的行迁移为在书架',
      );
      final MangaDownloadJobRow? kept = await upgraded.getMangaDownloadJob(
        'legacy-job',
      );
      expect(kept?.status, MangaDownloadJobStatus.failed);
      expect(kept?.chapterTitle, 'Chapter 1');
      expect(kept?.pagesDone, 1);
      expect(kept?.attemptCount, 3);
      expect(kept?.lastError, 'boom');

      // 新增的 paused 值可以写入（v3 的 CHECK 会拒绝）。
      await upgraded.updateMangaDownloadJobStatus(
        'legacy-job',
        status: MangaDownloadJobStatus.paused,
        updatedAt: 1700000001000,
      );
      expect(
        (await upgraded.getMangaDownloadJob('legacy-job'))?.status,
        MangaDownloadJobStatus.paused,
      );
      expect(await upgraded.hasPausedMangaDownloadJobs(), isTrue);
      // 重建表后索引由迁移步补回。
      final List<QueryRow> indexes = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'index' "
            "AND tbl_name = 'manga_download_jobs'",
          )
          .get();
      expect(
        indexes.map((QueryRow row) => row.read<String>('name')),
        containsAll(<String>[
          'idx_manga_download_jobs_identity',
          'idx_manga_download_jobs_status_created',
        ]),
      );
    },
  );

  test(
    'v4 升级到 v5：epub_books 增加 Library membership，已有行迁移为在书架',
    () async {
      final FushiDatabase db = await open();
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'old-book',
          title: 'Old Manga',
          epubPath: 'manga.json',
          extractDir: p.join(tmp.path, 'books', 'old-book'),
          chapterCount: 2,
          chaptersJson: '[]',
          importedAt: 1700000000000,
          format: const Value('manga'),
        ),
      );
      // v4 库还没有 membership 列。
      await dropLibraryMembershipColumn(db);
      await db.customStatement('PRAGMA user_version = 4');
      await db.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);

      expect(upgraded.schemaVersion, 5);
      final EpubBookRow? migrated = await upgraded.getEpubBook('old-book');
      expect(migrated?.title, 'Old Manga');
      expect(
        migrated?.inLibrary,
        isTrue,
        reason: '升级前已存在的 Manga 行迁移为在书架',
      );

      // 新列可写：非书架行（membership=false）也能持久化。
      await (upgraded.update(upgraded.epubBooks)
            ..where((t) => t.bookKey.equals('old-book')))
          .write(const EpubBooksCompanion(inLibrary: Value<bool>(false)));
      expect(
        (await upgraded.getEpubBook('old-book'))?.inLibrary,
        isFalse,
      );
    },
  );

  test(
    'fresh 与 v2→当前 升级后的 manga_chapter_dirs 有效 schema 一致',
    () async {
      // fresh：drift 按当前表定义建表。
      final FushiDatabase fresh = await open();
      final Map<String, String> freshColumns = await _columnShape(fresh);
      final Set<String> freshChecks = await _tableChecks(fresh);

      // 同一文件降级成票 04 的 v2 表（没有 container_kind，也没有它的 CHECK），
      // 再重新打开走真实的 v2 → v3 迁移。
      await fresh.customStatement('DROP TABLE manga_chapter_dirs');
      await fresh.customStatement(
        'CREATE TABLE manga_chapter_dirs ('
        'book_key TEXT NOT NULL, '
        'chapter_key TEXT NOT NULL, '
        'folder_name TEXT NOT NULL, '
        'updated_at INTEGER NOT NULL, '
        'PRIMARY KEY (book_key, chapter_key), '
        "CHECK (book_key != '' AND chapter_key != '' AND folder_name != ''), "
        'CHECK (updated_at >= 0))',
      );
      await dropLibraryMembershipColumn(fresh);
      await fresh.customStatement('PRAGMA user_version = 2');
      await fresh.close();

      final FushiDatabase upgraded = await open();
      addTearDown(upgraded.close);
      final Map<String, String> upgradedColumns = await _columnShape(upgraded);
      final Set<String> upgradedChecks = await _tableChecks(upgraded);

      expect(
        upgradedColumns,
        freshColumns,
        reason: '列名 / 类型 / NOT NULL / 默认值 / 主键必须一致（列序可不同）',
      );
      expect(
        upgradedChecks,
        freshChecks,
        reason: '表级 CHECK 必须一致：ALTER TABLE ADD COLUMN 不会补上 fresh 表的 CHECK',
      );
      expect(
        freshChecks.any((String check) => check.contains('container_kind')),
        isFalse,
        reason: '容器类型由 Dart enum 在数据库边界约束，不能只写在 fresh 表上',
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

/// 把 fresh schema 的 `epub_books` 还原成 v4（没有 `in_library` 列）。
///
/// SQLite 3.35+ 支持 `DROP COLUMN`；表上没有依赖该列的索引 / CHECK，可直接删。
Future<void> dropLibraryMembershipColumn(FushiDatabase db) =>
    db.customStatement('ALTER TABLE epub_books DROP COLUMN in_library');

/// `manga_chapter_dirs` 的列形状（顺序不敏感）：name → type / notnull / 默认值 / pk。
Future<Map<String, String>> _columnShape(FushiDatabase db) async {
  final List<QueryRow> rows = await db
      .customSelect('PRAGMA table_info(manga_chapter_dirs)')
      .get();
  return <String, String>{
    for (final QueryRow row in rows)
      row.read<String>('name'): <String>[
        row.read<String>('type'),
        row.read<int>('notnull').toString(),
        row.data['dflt_value']?.toString() ?? '',
        row.read<int>('pk').toString(),
      ].join('|'),
  };
}

/// 表级 CHECK 约束集合（按括号配对提取，空白归一化）。
Future<Set<String>> _tableChecks(FushiDatabase db) async {
  final QueryRow row = await db
      .customSelect(
        "SELECT sql FROM sqlite_master WHERE type = 'table' "
        "AND name = 'manga_chapter_dirs'",
      )
      .getSingle();
  final String sql = row.read<String>('sql');
  final Set<String> checks = <String>{};
  int index = 0;
  while (true) {
    final int start = sql.indexOf('CHECK', index);
    if (start < 0) break;
    final int open = sql.indexOf('(', start);
    if (open < 0) break;
    int depth = 0;
    int end = open;
    for (; end < sql.length; end++) {
      final String char = sql[end];
      if (char == '(') {
        depth++;
      } else if (char == ')') {
        depth--;
        if (depth == 0) break;
      }
    }
    checks.add(
      sql.substring(start, end + 1).replaceAll(RegExp(r'\s+'), ' ').trim(),
    );
    index = end + 1;
  }
  return checks;
}
