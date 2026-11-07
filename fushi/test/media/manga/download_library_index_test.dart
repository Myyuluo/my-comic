import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_download_state.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

/// Download library 的映射解析（票 04）：阅读/删除按数据库映射定位章目录，
/// 不再用章 key 的标题/摘要推导新布局路径；旧哈希布局仍可只读回退。
void main() {
  late Directory root;
  late FushiDatabase db;
  late String bookKey;
  late String mangaDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download_library_index_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    bookKey = 'mihon-fixture';
    mangaDir = p.join(
      root.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Fixture series',
        epubPath: 'pages.json',
        extractDir: mangaDir,
        chapterCount: 2,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  MangaPagesManifest manifestFor(String chapterKey) => MangaPagesManifest(
    sourceRuntime: 'mihon',
    sourceId: '1',
    sourceName: 'Example Source',
    extensionPackage: 'org.example.fixture',
    mangaKey: '/series/fixture',
    mangaTitle: 'Fixture series',
    chapterKey: chapterKey,
    chapterName: 'Chapter 1',
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

  Future<Directory> writeNewLayoutChapter(String folderName) async {
    final Directory chapterDir = downloadChapterDirectory(mangaDir, folderName);
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(chapterDir, manifestFor('/c/1'));
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: folderName,
      updatedAt: 1,
    );
    return chapterDir;
  }

  test('映射存在时解析到 downloads/{source}/{manga}/{chapter}，页图根是章目录', () async {
    final Directory chapterDir = await writeNewLayoutChapter('Chapter 1');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull);
    expect(container!.legacyLayout, isFalse);
    expect(container.directory.path, chapterDir.path);
    expect(
      container.manifestFile.path,
      downloadPagesManifestFile(chapterDir).path,
    );
    expect(container.imagesDirectory.path, chapterDir.path);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1'},
    );
  });

  test('半成品 / 缺页不算已下载', () async {
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    // 有映射、目录里有页图，但 pages.json 还没写（staging 被误 rename 的形态）。
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      'Chapter 1',
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isFalse,
    );
    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNotNull,
      reason: '容器目录存在就应能定位，完整性由 isChapterDownloaded 判',
    );
  });

  test('没有映射时只读回退旧哈希布局（manga.json + images/）', () async {
    final Directory legacyChapter = mangaChapterDirectory(
      await MangaStorage.bookPath(bookKey),
      '/c/1',
    );
    await mangaChapterImagesDirectory(legacyChapter).create(recursive: true);
    await File(
      p.join(legacyChapter.path, 'images', 'page-000001.jpg'),
    ).writeAsBytes(<int>[1]);
    await mangaChapterJsonFile(legacyChapter).writeAsString(
      jsonEncode(<String, Object?>{
        'pages': <Map<String, Object?>>[
          <String, Object?>{
            'url': 'images/page-000001.jpg',
            'width': 100,
            'height': 150,
            'blocks': <Object?>[],
          },
        ],
      }),
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull);
    expect(container!.legacyLayout, isTrue);
    expect(
      container.imagesDirectory.path,
      mangaChapterImagesDirectory(legacyChapter).path,
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
  });

  test('切换 Content root 后旧根下的下载不再被读取，状态为 Missing', () async {
    // 当前 Content root 的 Download library 是 `<root>/downloads`（见 setUp）。
    // 旧根是切换前的 Content root：库里的 extract_dir 仍指向它（switch 不重基）。
    final Directory oldRoot = Directory(p.join(root.path, 'OldContent'));
    final String oldMangaDir = p.join(
      oldRoot.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    final Directory oldChapterDir = downloadChapterDirectory(
      oldMangaDir,
      'Chapter 1',
    );
    await oldChapterDir.create(recursive: true);
    final File oldPage = File(p.join(oldChapterDir.path, '001.jpg'));
    await oldPage.writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(oldChapterDir, manifestFor('/c/1'));
    await db.customStatement(
      'UPDATE epub_books SET extract_dir = ? WHERE book_key = ?',
      <Object?>[oldMangaDir, bookKey],
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNull,
      reason: '旧 Content root 下的章容器不得再被定位',
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isFalse,
      reason: '磁盘判据只看当前 Content root',
    );
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1']),
      isEmpty,
    );
    // 旧文件原地保留——切换既不搬移也不删除。
    expect(oldPage.existsSync(), isTrue);

    final MangaDownloadJobRow doneJob = MangaDownloadJobRow(
      jobId: 'job-1',
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/c/1',
      runtime: 'mihon',
      title: 'Fixture series',
      chapterTitle: 'Chapter 1',
      status: MangaDownloadJobStatus.done,
      pagesDone: 1,
      pagesTotal: 1,
      attemptCount: 1,
      lastError: null,
      autoOcr: false,
      createdAt: 1,
      updatedAt: 1,
      completedAt: 1,
    );
    expect(
      mangaChapterDownloadState(downloaded: false, job: doneJob),
      MangaChapterDownloadState.missing,
      reason: 'done 任务 + 当前根下找不到文件 = Missing',
    );
  });

  test('删章走映射：删实际目录并清映射；不存在时静默', () async {
    final Directory chapterDir = await writeNewLayoutChapter('Chapter 1');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');
    expect(chapterDir.existsSync(), isFalse);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);

    await expectLater(
      index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1'),
      completes,
    );
  });
}
