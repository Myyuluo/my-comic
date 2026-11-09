import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_download_state.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

/// Download library 的映射解析（票 04/12）：阅读/删除按数据库映射定位章目录，
/// 不再用章 key / 标题推导路径；旧哈希布局回退已删除。
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
    expect(container!.kind, MangaChapterContainerKind.folder);
    expect(container.directory!.path, chapterDir.path);
    expect(
      container.manifestFile!.path,
      downloadPagesManifestFile(chapterDir).path,
    );
    expect(container.imagesDirectory!.path, chapterDir.path);
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

  test('没有映射时不回退旧哈希布局（ticket 12 删除只读回退）', () async {
    // 旧布局：<content>/fushi_books/<bookKey>/chapters/<digest>/。
    final Directory legacyChapter = Directory(
      p.join(root.path, 'fushi_books', bookKey, 'chapters', 'deadbeef'),
    );
    final File legacyPage = File(
      p.join(legacyChapter.path, 'images', 'page-000001.jpg'),
    );
    await legacyPage.parent.create(recursive: true);
    await legacyPage.writeAsBytes(<int>[1]);
    await File(p.join(legacyChapter.path, 'manga.json')).writeAsString(
      '{"pages":[{"url":"images/page-000001.jpg","width":100,'
      '"height":150,"blocks":[]}]}',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNull,
      reason: '旧哈希布局不再读取',
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isFalse,
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

  // ── CBZ 章节容器（票 06） ────────────────────────────────────────────

  /// 手工制作一个 CBZ 章节：包根平铺 `001.jpg` + `pages.json`。
  Future<File> writeArchiveChapter(
    String containerName, {
    String chapterKey = '/c/1',
    bool writePage = true,
  }) async {
    final Archive archive = Archive();
    if (writePage) {
      final List<int> page = utf8.encode('page');
      archive.addFile(ArchiveFile('001.jpg', page.length, page));
    }
    final List<int> manifest = utf8.encode(
      jsonEncode(manifestFor(chapterKey).toJson()),
    );
    archive.addFile(
      ArchiveFile(kDownloadPagesFileName, manifest.length, manifest),
    );
    await Directory(mangaDir).create(recursive: true);
    final File file = downloadChapterArchiveFile(mangaDir, containerName);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: containerName,
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );
    return file;
  }

  test('archive 映射解析为 CBZ 容器；完整性读包根 pages.json 与页条目', () async {
    final File archiveFile = await writeArchiveChapter('Chapter 1.cbz');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull);
    expect(container!.kind, MangaChapterContainerKind.archive);
    expect(container.archiveFile!.path, archiveFile.path);
    expect(container.directory, isNull);
    expect(container.manifestFile, isNull);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1'},
    );
  });

  test('archive 半成品：容器可定位但缺页不算已下载', () async {
    final File archiveFile = await writeArchiveChapter(
      'Chapter 1.cbz',
      writePage: false,
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNotNull,
      reason: '容器文件存在就应能定位；完整性由 isChapterDownloaded 判',
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isFalse,
    );
    expect(archiveFile.existsSync(), isTrue);
  });

  test('删压缩包章节删对应文件并清映射；重复删除静默', () async {
    final File archiveFile = await writeArchiveChapter('Chapter 1.cbz');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');
    expect(archiveFile.existsSync(), isFalse);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);

    await expectLater(
      index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1'),
      completes,
    );
  });

  test('文件夹与压缩包混排各走各的删除路径', () async {
    final Directory folder = await writeNewLayoutChapter('Chapter 1');
    await writeArchiveChapter('Chapter 2.cbz', chapterKey: '/c/2');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1', '/c/2'},
    );

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');
    expect(folder.existsSync(), isFalse);
    expect(
      File(p.join(mangaDir, 'Chapter 2.cbz')).existsSync(),
      isTrue,
      reason: '删一章不得碰相邻的压缩包章节',
    );

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/2');
    expect(File(p.join(mangaDir, 'Chapter 2.cbz')).existsSync(), isFalse);
  });

  // ── 任意在线条目的已下载状态（ticket 07） ─────────────────────────────
  //
  // 详情页不再要求 Library 行：按 entry 身份（runtime + 数字 sourceId +
  // seriesKey）查映射，没有映射/行时用 `pages.json` 身份扫描 downloads 与
  // local。没有 manifest 的目录绝不按标题猜测。
  group('在线条目身份', () {
    const OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{'url': '/c/1'},
        ),
        OnlineMangaChapter(
          key: '/c/2',
          name: 'Chapter 2',
          raw: <String, Object?>{'url': '/c/2'},
        ),
      ],
    );

    /// 在一个漫画目录下写一章「完整下载」：页图 + pages.json。
    Future<void> writeManifestChapter(
      String mangaDirPath,
      String containerName,
      String chapterKey,
    ) async {
      final Directory chapterDir = downloadChapterDirectory(
        mangaDirPath,
        containerName,
      );
      await chapterDir.create(recursive: true);
      await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
      await writePagesManifestAtomically(chapterDir, manifestFor(chapterKey));
    }

    test('无 Library 行时按 pages.json 身份从 downloads 识别已下载章', () async {
      final String otherMangaDir = p.join(
        root.path,
        'downloads',
        'Example Source',
        'Not in library',
      );
      await writeManifestChapter(otherMangaDir, 'Chapter 1', '/c/1');

      final Set<String> downloaded = await DownloadLibraryIndex(
        db,
      ).downloadedChapterKeysForEntry(entry);

      expect(downloaded, <String>{'/c/1'});
    });

    test('local 中带 manifest 的文件夹可关联到在线条目', () async {
      final Directory localRoot = Directory(p.join(root.path, 'local'));
      await writeManifestChapter(
        p.join(localRoot.path, '不同的本地文件夹名'),
        'Chapter 2',
        '/c/2',
      );

      final Set<String> downloaded = await DownloadLibraryIndex(
        db,
        localComicRoot: localRoot,
      ).downloadedChapterKeysForEntry(entry);

      expect(downloaded, <String>{'/c/2'});
    });

    test('local 中没有 manifest 的文件夹不按标题关联', () async {
      final Directory localRoot = Directory(p.join(root.path, 'local'));
      // 目录名与作品标题完全相同、也有可读页图——但没有 pages.json 身份。
      final Directory chapterDir = Directory(
        p.join(localRoot.path, 'Fixture series', 'Chapter 1'),
      )..createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);

      final Set<String> downloaded = await DownloadLibraryIndex(
        db,
        localComicRoot: localRoot,
      ).downloadedChapterKeysForEntry(entry);

      expect(downloaded, isEmpty, reason: '无 manifest 不得按标题猜测');
    });

    test('多个目录的 manifest 都匹配同一作品时不猜', () async {
      final String sourceDir = p.join(root.path, 'downloads', 'Example Source');
      await writeManifestChapter(
        p.join(sourceDir, 'Copy A'),
        'Chapter 1',
        '/c/1',
      );
      await writeManifestChapter(
        p.join(sourceDir, 'Copy B'),
        'Chapter 2',
        '/c/2',
      );

      final Set<String> downloaded = await DownloadLibraryIndex(
        db,
      ).downloadedChapterKeysForEntry(entry);

      expect(downloaded, isEmpty, reason: '多个副本可证明同身份时也不猜');
    });

    test('有行时映射与 downloads/local manifest 扫描合并', () async {
      // 映射：/c/1 在行自己的漫画目录里。
      await writeManifestChapter(mangaDir, 'Mapped Chapter', '/c/1');
      await db.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: '/c/1',
        folderName: 'Mapped Chapter',
        updatedAt: 1,
      );
      // manifest：/c/2 在 local 里。
      final Directory localRoot = Directory(p.join(root.path, 'local'));
      await writeManifestChapter(
        p.join(localRoot.path, 'Local copy'),
        'Chapter 2',
        '/c/2',
      );

      final Set<String> downloaded =
          await DownloadLibraryIndex(
            db,
            localComicRoot: localRoot,
          ).downloadedChapterKeysForEntry(
            entry,
            row: await db.getEpubBook(bookKey),
          );

      expect(downloaded, <String>{'/c/1', '/c/2'});
    });
  });
}
