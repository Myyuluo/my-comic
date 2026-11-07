import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// Download library 的 `bookKey + chapterKey → folderName` 映射（票 04）。
///
/// 目录名不是身份：标题/源改名不自动重命名磁盘目录，阅读/删除通过映射定位。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<void> insertBook(String bookKey) => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Manga $bookKey',
          epubPath: 'pages.json',
          extractDir: '/downloads/src/manga',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );

  test('upsert / get / delete 按 (bookKey, chapterKey) 定位', () async {
    expect(await db.getMangaChapterDir('book-1', 'ch-1'), isNull);

    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1',
      updatedAt: 10,
    );
    final MangaChapterDirRow? row = await db.getMangaChapterDir(
      'book-1',
      'ch-1',
    );
    expect(row, isNotNull);
    expect(row!.folderName, 'Chapter 1');

    // 同键再写 = 更新实际目录名（冲突后缀 / 重建 re-link 用）。
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1 (2)',
      updatedAt: 20,
    );
    expect(
      (await db.getMangaChapterDir('book-1', 'ch-1'))!.folderName,
      'Chapter 1 (2)',
    );

    // 不同章互不影响。
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-2',
      folderName: 'Chapter 2',
      updatedAt: 20,
    );
    expect(await db.getMangaChapterDir('book-1', 'ch-2'), isNotNull);

    await db.deleteMangaChapterDir('book-1', 'ch-1');
    expect(await db.getMangaChapterDir('book-1', 'ch-1'), isNull);
    expect(await db.getMangaChapterDir('book-1', 'ch-2'), isNotNull);
  });

  test('删书级联删掉该书全部章目录映射，不碰别的书', () async {
    await insertBook('book-1');
    await insertBook('book-2');
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );
    await db.upsertMangaChapterDir(
      bookKey: 'book-2',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );

    await db.deleteEpubBook('book-1');

    expect(await db.getMangaChapterDir('book-1', 'ch-1'), isNull);
    expect(await db.getMangaChapterDir('book-2', 'ch-1'), isNotNull);
  });

  test('可一次取整本书的映射表', () async {
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-2',
      folderName: 'Chapter 2',
      updatedAt: 1,
    );
    expect(await db.getMangaChapterDirNamesForBook('book-1'), <String, String>{
      'ch-1': 'Chapter 1',
      'ch-2': 'Chapter 2',
    });
  });

  test('容器类型：默认 folder，可记录 archive；整本映射带出类型', () async {
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );
    expect(
      (await db.getMangaChapterDir('book-1', 'ch-1'))!.containerKindEnum,
      MangaChapterContainerKind.folder,
      reason: '不传容器类型时的默认值必须保持既有 folder 语义',
    );

    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-2',
      folderName: 'Chapter 2.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );
    final MangaChapterDirRow archive = (await db.getMangaChapterDir(
      'book-1',
      'ch-2',
    ))!;
    expect(archive.containerKindEnum, MangaChapterContainerKind.archive);
    expect(archive.folderName, 'Chapter 2.cbz');

    // 同键改类型 / 改名 = 更新（重建 re-link 与切换下载格式后可能发生）。
    await db.upsertMangaChapterDir(
      bookKey: 'book-1',
      chapterKey: 'ch-1',
      folderName: 'Chapter 1 (2)',
      containerKind: MangaChapterContainerKind.folder,
      updatedAt: 2,
    );
    expect(
      (await db.getMangaChapterDir('book-1', 'ch-1'))!.folderName,
      'Chapter 1 (2)',
    );

    final Map<String, MangaChapterDirRow> rows = await db
        .getMangaChapterDirRowsForBook('book-1');
    expect(rows['ch-1']!.containerKindEnum, MangaChapterContainerKind.folder);
    expect(rows['ch-2']!.containerKindEnum, MangaChapterContainerKind.archive);
  });
}
