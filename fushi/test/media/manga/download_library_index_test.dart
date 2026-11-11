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
import 'package:fushi_engine/media/manga/book_storage.dart';
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

  MangaPagesManifest manifestFor(
    String chapterKey, {
    String mangaKey = '/series/fixture',
    String mangaTitle = 'Fixture series',
  }) => MangaPagesManifest(
    sourceRuntime: 'mihon',
    sourceId: '1',
    sourceName: 'Example Source',
    extensionPackage: 'org.example.fixture',
    mangaKey: mangaKey,
    mangaTitle: mangaTitle,
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

  /// 在共享漫画目录里为另一部作品写一章（容器 + manifest + 映射）。
  Future<Directory> writeSharedChapter({
    required String otherBookKey,
    required String mangaKey,
    required String chapterKey,
    required String folderName,
  }) async {
    final Directory chapterDir = downloadChapterDirectory(mangaDir, folderName);
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[2]);
    await writePagesManifestAtomically(
      chapterDir,
      manifestFor(chapterKey, mangaKey: mangaKey),
    );
    await db.upsertMangaChapterDir(
      bookKey: otherBookKey,
      chapterKey: chapterKey,
      folderName: folderName,
      updatedAt: 2,
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

  test('无 manifest 但可读的映射容器视为已下载（按容器名关联）', () async {
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    // 用户提供的文件夹：有页图、没有 pages.json；重链已按容器名写好映射。
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
      isTrue,
      reason: '无 manifest 容器的完整性不要求通过 pages.json 校验，可读即已下载',
    );
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1'},
    );
    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNotNull,
      reason: '容器目录存在就应能定位',
    );
  });

  test('无 manifest 且没有可读页的映射容器不算已下载', () async {
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    // 有映射，但章节目录是空的（或只有非图片文件）：读不出任何页。
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      'Chapter 1',
    );
    await chapterDir.create(recursive: true);
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
  });

  test('有 pages.json 但缺页的容器仍不算已下载', () async {
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    // pages.json 声明了 002.jpg，但只有 001.jpg —— 半成品不得冒充已下载。
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      'Chapter 1',
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    final MangaPagesManifest manifest = MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Example Source',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Fixture series',
      chapterKey: '/c/1',
      chapterName: 'Chapter 1',
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
          MokuroImage(
            url: '002.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    );
    await writePagesManifestAtomically(chapterDir, manifest);
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

  test('共享目录：删作品 A 的章节不动作品 B 的容器、映射与目录', () async {
    const String otherBookKey = 'other-work';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: otherBookKey,
        title: 'Fixture series',
        epubPath: 'pages.json',
        extractDir: mangaDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 2,
        format: const Value<String>('manga'),
      ),
    );
    // 两部作品在同一共享目录里使用相同的章 key `/c/1`，容器名不同。
    final Directory aChapter = await writeNewLayoutChapter('A chapter 1');
    final Directory bChapter = await writeSharedChapter(
      otherBookKey: otherBookKey,
      mangaKey: '/series/other',
      chapterKey: '/c/1',
      folderName: 'B chapter 1',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(aChapter.existsSync(), isFalse, reason: '只删 A 自己映射的容器');
    expect(bChapter.existsSync(), isTrue, reason: 'B 的容器必须保留');
    expect(
      File(p.join(bChapter.path, '001.jpg')).existsSync(),
      isTrue,
      reason: 'B 的页图必须保留',
    );
    expect(
      (await readPagesManifest(bChapter))?.mangaKey,
      '/series/other',
      reason: 'B 的 manifest 不得被改写或删除',
    );
    expect(
      await db.getMangaChapterDir(otherBookKey, '/c/1'),
      isNotNull,
      reason: 'B 的数据库映射必须保留',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
    expect(
      Directory(mangaDir).existsSync(),
      isTrue,
      reason: '共享目录里还有 B 的文件，不得清理',
    );
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isTrue,
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

  test('身份回退删除（无映射）同样清理空的 manga 与 source 目录', () async {
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
      ],
    );
    // 磁盘上有完整容器，但数据库里没有映射（清库后重开 / 映射丢失）。
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      'Chapter 1',
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(chapterDir, manifestFor('/c/1'));
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: entry,
      chapterKey: '/c/1',
      row: await db.getEpubBook(bookKey),
    );

    expect(chapterDir.existsSync(), isFalse);
    expect(
      Directory(mangaDir).existsSync(),
      isFalse,
      reason: '身份回退路径也要清理刚删空的 manga 目录',
    );
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isFalse,
    );
  });

  test('身份回退删除共享目录：只删本作品身份匹配的容器', () async {
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
      ],
    );
    const OnlineMangaLibraryEntry other = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/other',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/other'},
      ),
      chapters: <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/other/1',
          name: 'Chapter 1',
          raw: <String, Object?>{'url': '/other/1'},
        ),
      ],
    );
    Future<Directory> write(
      String folderName,
      String chapterKey,
      String mangaKey,
    ) async {
      final Directory chapterDir = downloadChapterDirectory(
        mangaDir,
        folderName,
      );
      await chapterDir.create(recursive: true);
      await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
      await writePagesManifestAtomically(
        chapterDir,
        manifestFor(chapterKey, mangaKey: mangaKey),
      );
      return chapterDir;
    }

    // 另一部作品的容器名排序在前，扫描必须先找到本作品的 manifest。
    final Directory otherChapter = await write(
      'A other work',
      '/other/1',
      '/series/other',
    );
    final Directory fixtureChapter = await write(
      'B fixture work',
      '/c/1',
      '/series/fixture',
    );
    // 模拟「清除数据库」：行与映射都不在，只剩磁盘上的 pages.json 身份。
    await db.deleteEpubBook(bookKey);
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: entry,
      chapterKey: '/c/1',
      row: null,
    );

    expect(fixtureChapter.existsSync(), isFalse, reason: '删掉本作品的容器');
    expect(otherChapter.existsSync(), isTrue, reason: '共享目录里另一部作品的容器必须保留');
    expect(File(p.join(otherChapter.path, '001.jpg')).existsSync(), isTrue);
    expect(Directory(mangaDir).existsSync(), isTrue, reason: '另一部作品还在用共享目录');

    // 另一部作品也删掉后才清理空目录。
    await index.deleteChapterForEntry(
      entry: other,
      chapterKey: '/other/1',
      row: null,
    );
    expect(otherChapter.existsSync(), isFalse);
    expect(Directory(mangaDir).existsSync(), isFalse);
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isFalse,
    );
  });

  test('共享目录：无 manifest 容器被多个作品映射时删除不猜', () async {
    const String otherBookKey = 'other-work';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: otherBookKey,
        title: 'Fixture series',
        epubPath: 'pages.json',
        extractDir: mangaDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 2,
        format: const Value<String>('manga'),
      ),
    );
    // 用户放进共享目录的无 manifest 容器：两个作品都曾按容器名映射到它。
    final Directory shared = downloadChapterDirectory(mangaDir, 'Chapter 1');
    await shared.create(recursive: true);
    await File(p.join(shared.path, '001.jpg')).writeAsBytes(<int>[1]);
    for (final String key in <String>[bookKey, otherBookKey]) {
      await db.upsertMangaChapterDir(
        bookKey: key,
        chapterKey: '/c/1',
        folderName: 'Chapter 1',
        updatedAt: 1,
      );
    }

    await DownloadLibraryIndex(
      db,
    ).deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(
      File(p.join(shared.path, '001.jpg')).existsSync(),
      isTrue,
      reason: '归属不明的容器只能由唯一映射证明，删除不得连带删掉另一部作品的文件',
    );
    expect(shared.existsSync(), isTrue);
  });

  test('空的 manga 目录仍被其他作品引用时不清理', () async {
    final Directory chapterDir = await writeNewLayoutChapter('Chapter 1');
    // 同名共享目录里的另一部作品还没有下载任何章，但它的行引用着这个目录。
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'other-work',
        title: 'Fixture series',
        epubPath: 'pages.json',
        extractDir: mangaDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 2,
        format: const Value<String>('manga'),
      ),
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(chapterDir.existsSync(), isFalse);
    expect(
      Directory(mangaDir).existsSync(),
      isTrue,
      reason: '另一部作品仍引用该共享目录，即使它此刻是空的也不能删',
    );
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isTrue,
      reason: 'manga 目录保留时 source 目录也不能清理',
    );
  });

  test('旧版本遗留的封面目录与随机字符串目录不自动删除', () async {
    final Directory sourceDir = Directory(
      p.join(root.path, 'downloads', 'Example Source'),
    );
    // 旧版本遗留：封面目录、随机字符串目录、以及一个空的随机字符串目录。
    final Directory coverOnly = Directory(p.join(sourceDir.path, 'Cover dir'))
      ..createSync(recursive: true);
    final File cover = File(p.join(coverOnly.path, 'cover.jpg'))
      ..writeAsBytesSync(<int>[9]);
    final Directory randomName = Directory(p.join(sourceDir.path, 'x8f2a9c'))
      ..createSync(recursive: true);
    final File randomCover = File(p.join(randomName.path, 'cover.jpg'))
      ..writeAsBytesSync(<int>[8]);
    final Directory emptyRandom = Directory(p.join(sourceDir.path, 'q7d1e0'))
      ..createSync(recursive: true);
    final Directory chapterDir = await writeNewLayoutChapter('Chapter 1');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(chapterDir.existsSync(), isFalse);
    expect(
      Directory(mangaDir).existsSync(),
      isFalse,
      reason: '本作品的空 manga 目录仍可清理',
    );
    expect(coverOnly.existsSync(), isTrue, reason: '旧封面目录不得自动删除');
    expect(cover.existsSync(), isTrue);
    expect(randomName.existsSync(), isTrue, reason: '随机字符串目录不得自动删除');
    expect(randomCover.existsSync(), isTrue);
    expect(emptyRandom.existsSync(), isTrue, reason: '空的遗留目录也不主动扫描删除');
    expect(
      sourceDir.existsSync(),
      isTrue,
      reason: 'source 目录并非真的空了（遗留目录还在），不能删',
    );
    expect(File(p.join(coverOnly.path, 'cover.jpg')).readAsBytesSync(), <int>[
      9,
    ], reason: '遗留文件内容不得被改写');
  });

  test('删最后一章后清理空的 manga 目录与 source 目录', () async {
    final Directory chapterDir = await writeNewLayoutChapter('Chapter 1');
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(chapterDir.existsSync(), isFalse);
    expect(
      Directory(mangaDir).existsSync(),
      isFalse,
      reason: '没有其他作品的容器时，空的 manga 目录一并清理',
    );
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isFalse,
      reason: '整个 source 目录也空了才删除 source',
    );
    expect(
      Directory(p.join(root.path, 'downloads')).existsSync(),
      isTrue,
      reason: 'Download library 根目录不是清理对象',
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

  test('无 manifest 但包内有图的 CBZ 视为已下载（按容器名关联）', () async {
    // 用户提供的普通 CBZ：只有页图，没有 pages.json。
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
    await Directory(mangaDir).create(recursive: true);
    final File archiveFile = downloadChapterArchiveFile(
      mangaDir,
      'Chapter 1.cbz',
    );
    await archiveFile.writeAsBytes(ZipEncoder().encode(archive)!);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: 'Chapter 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '无 manifest 的 CBZ 不要求 pages.json 完整性校验，可读即已下载',
    );
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container!.isArchive, isTrue);
  });

  test('无 manifest 且没有页图的 CBZ 不算已下载', () async {
    final Archive archive = Archive();
    await Directory(mangaDir).create(recursive: true);
    final File archiveFile = downloadChapterArchiveFile(
      mangaDir,
      'Chapter 1.cbz',
    );
    await archiveFile.writeAsBytes(ZipEncoder().encode(archive)!);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: 'Chapter 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isFalse,
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
    expect(
      Directory(mangaDir).existsSync(),
      isFalse,
      reason: '最后一个 CBZ 删除后空的 manga 目录也清理',
    );

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

  // ── 单章作品根 manifest（ticket 06） ─────────────────────────────────

  const OnlineMangaLibraryEntry rootManifestEntry = OnlineMangaLibraryEntry(
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
    ],
  );

  /// 把当前行改造成单章在线作品，并在漫画目录根写 pages.json + 页图。
  Future<void> writeRootManifestChapter() async {
    await db.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: rootManifestEntry.encode(),
      chapterCount: 1,
      chaptersJson: '[]',
    );
    await Directory(mangaDir).create(recursive: true);
    await File(p.join(mangaDir, '001.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(
      Directory(mangaDir),
      manifestFor('/c/1'),
    );
  }

  test('根 manifest 单章：解析为漫画目录根容器，可读即已下载', () async {
    await writeRootManifestChapter();
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull);
    expect(container!.isMangaRoot, isTrue);
    expect(container.directory!.path, mangaDir);
    expect(container.manifestFile!.path, p.join(mangaDir, 'pages.json'));
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
  });

  /// 把当前行重链到 Local source root 下的根 manifest 单章作品（用户原件）。
  Future<Directory> writeLocalRootManifestChapter() async {
    final Directory localMangaDir = Directory(
      p.join(root.path, 'local', 'Fixture series'),
    );
    await localMangaDir.create(recursive: true);
    await File(p.join(localMangaDir.path, '001.jpg')).writeAsBytes(<int>[3]);
    await writePagesManifestAtomically(localMangaDir, manifestFor('/c/1'));
    await db.updateEpubBookMihonState(
      bookKey,
      sourceMetadata: rootManifestEntry.encode(),
      chapterCount: 1,
      chaptersJson: '[]',
    );
    await db.updateEpubBookContentPaths(
      bookKey,
      extractDir: localMangaDir.path,
    );
    return localMangaDir;
  }

  test('local 根根 manifest 重链后：单章删除拒绝，用户原件保留', () async {
    final Directory localMangaDir = await writeLocalRootManifestChapter();
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: 'Local source root 下的用户原件仍可关联与阅读',
    );

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');

    expect(
      File(p.join(localMangaDir.path, '001.jpg')).existsSync(),
      isTrue,
      reason: 'local 根下的用户原件永不删除',
    );
    expect(
      File(p.join(localMangaDir.path, 'pages.json')).existsSync(),
      isTrue,
      reason: '根 manifest 也属于用户原件，删除下载不得清空它',
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '拒绝删除后已下载状态不变',
    );
  });

  test('local 根根 manifest 重链后：批量删除拒绝，用户原件保留', () async {
    final Directory localMangaDir = await writeLocalRootManifestChapter();
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: rootManifestEntry,
      chapterKey: '/c/1',
      row: row,
    );

    expect(
      File(p.join(localMangaDir.path, '001.jpg')).existsSync(),
      isTrue,
      reason: '批量删除与单章删除同一路径，都不得碰 local 原件',
    );
    expect(File(p.join(localMangaDir.path, 'pages.json')).existsSync(), isTrue);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
  });

  test('删除根 manifest 单章：清空页负载但保留作品条目、阅读进度与其他文件', () async {
    await writeRootManifestChapter();
    // 同目录下已有的 cover 与另一部作品（共享目录）内容不得被删。
    final File cover = File(p.join(mangaDir, 'cover.jpg'))
      ..writeAsBytesSync(<int>[9]);
    const String otherBookKey = 'other-work';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: otherBookKey,
        title: 'Fixture series',
        epubPath: 'pages.json',
        extractDir: mangaDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 2,
        format: const Value<String>('manga'),
      ),
    );
    final Directory otherChapter = downloadChapterDirectory(
      mangaDir,
      'Other chapter',
    )..createSync(recursive: true);
    File(p.join(otherChapter.path, '001.jpg')).writeAsBytesSync(<int>[2]);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    // 阅读进度：删除下载不等于清空阅读记录。
    await db.saveMangaChapterState(
      bookUid: row.uid,
      chapterKey: '/c/1',
      lastPage: 5,
      pageCount: 10,
      readAt: 1,
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: rootManifestEntry,
      chapterKey: '/c/1',
      row: row,
    );

    expect(
      File(p.join(mangaDir, 'pages.json')).existsSync(),
      isFalse,
      reason: '根 manifest 属于下载负载，必须删除',
    );
    expect(
      File(p.join(mangaDir, '001.jpg')).existsSync(),
      isFalse,
      reason: '根 manifest 声明的页图必须删除',
    );
    expect(cover.existsSync(), isTrue, reason: '已有 cover.jpg 不是下载负载，不得自动删除');
    expect(otherChapter.existsSync(), isTrue, reason: '共享目录里其他作品的内容不得被删');
    expect(Directory(mangaDir).existsSync(), isTrue, reason: '目录里还有其他内容');
    expect(await db.getEpubBook(bookKey), isNotNull, reason: '作品条目保留');
    final MangaChapterStateRow? state = await db.getMangaChapterState(
      bookUid: row.uid,
      chapterKey: '/c/1',
    );
    expect(state?.readAt, 1);
    expect(state?.lastPage, 5);
    expect(state?.pageCount, 10);
  });

  test('删除根 manifest 单章且目录已空：清理 manga 与 source 目录但保留条目', () async {
    await writeRootManifestChapter();
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: rootManifestEntry,
      chapterKey: '/c/1',
      row: row,
    );

    expect(Directory(mangaDir).existsSync(), isFalse);
    expect(
      Directory(p.join(root.path, 'downloads', 'Example Source')).existsSync(),
      isFalse,
    );
    expect(await db.getEpubBook(bookKey), isNotNull, reason: '单章作品条目保留');
  });

  test('没有行时根 manifest 单章按身份删除页负载（local 原件不动）', () async {
    await writeRootManifestChapter();
    final Directory localRoot = Directory(p.join(root.path, 'local'));
    // local 里的同名根 manifest 作品是用户原件，绝不参与删除。
    final Directory localMangaDir = Directory(
      p.join(localRoot.path, 'Fixture series'),
    );
    await localMangaDir.create(recursive: true);
    await File(p.join(localMangaDir.path, '001.jpg')).writeAsBytes(<int>[3]);
    await writePagesManifestAtomically(localMangaDir, manifestFor('/c/1'));
    await db.deleteEpubBook(bookKey);
    final DownloadLibraryIndex index = DownloadLibraryIndex(
      db,
      localComicRoot: localRoot,
    );

    await index.deleteChapterForEntry(
      entry: rootManifestEntry,
      chapterKey: '/c/1',
      row: null,
    );

    expect(File(p.join(mangaDir, 'pages.json')).existsSync(), isFalse);
    expect(File(p.join(mangaDir, '001.jpg')).existsSync(), isFalse);
    expect(Directory(mangaDir).existsSync(), isFalse);
    expect(
      File(p.join(localMangaDir.path, '001.jpg')).existsSync(),
      isTrue,
      reason: 'local 根下的用户原件永不删除',
    );
    expect(File(p.join(localMangaDir.path, 'pages.json')).existsSync(), isTrue);
  });

  test('书架批量口径：无 manifest 但可读的映射容器算已下载', () async {
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
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    final Set<String> downloaded = await index.booksWithAnyCompleteChapter(
      <String, MangaDownloadLibraryBook>{
        bookKey: MangaDownloadLibraryBook(
          extractDir: mangaDir,
          chapterKeys: <String>['/c/1'],
        ),
      },
      currentDownloadsRoot: Directory(p.join(root.path, 'downloads')),
    );

    expect(downloaded, <String>{bookKey});
  });

  test('批量删除无 manifest 文件夹：删掉 downloads 容器并清空目录', () async {
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
      ],
    );
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
    // local 里的同名用户原件（也没有 manifest）绝不参与删除。
    final Directory localRoot = Directory(p.join(root.path, 'local'));
    final Directory localOriginal = downloadChapterDirectory(
      p.join(localRoot.path, 'Fixture series'),
      'Chapter 1',
    );
    await localOriginal.create(recursive: true);
    await File(p.join(localOriginal.path, '001.jpg')).writeAsBytes(<int>[3]);
    final DownloadLibraryIndex index = DownloadLibraryIndex(
      db,
      localComicRoot: localRoot,
    );

    await index.deleteChapterForEntry(
      entry: entry,
      chapterKey: '/c/1',
      row: await db.getEpubBook(bookKey),
    );

    expect(chapterDir.existsSync(), isFalse);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
    expect(Directory(mangaDir).existsSync(), isFalse, reason: '删空的 manga 目录清理');
    expect(
      File(p.join(localOriginal.path, '001.jpg')).existsSync(),
      isTrue,
      reason: 'local 根下的用户原件永不删除',
    );
  });

  test('批量删除无 manifest CBZ：删掉压缩包并清空目录', () async {
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
      ],
    );
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
    await Directory(mangaDir).create(recursive: true);
    final File archiveFile = downloadChapterArchiveFile(
      mangaDir,
      'Chapter 1.cbz',
    );
    await archiveFile.writeAsBytes(ZipEncoder().encode(archive)!);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/1',
      folderName: 'Chapter 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);

    await index.deleteChapterForEntry(
      entry: entry,
      chapterKey: '/c/1',
      row: await db.getEpubBook(bookKey),
    );

    expect(archiveFile.existsSync(), isFalse);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
    expect(Directory(mangaDir).existsSync(), isFalse);
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
      String chapterKey, {
      String mangaKey = '/series/fixture',
      String mangaTitle = 'Fixture series',
    }) async {
      final Directory chapterDir = downloadChapterDirectory(
        mangaDirPath,
        containerName,
      );
      await chapterDir.create(recursive: true);
      await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
      await writePagesManifestAtomically(
        chapterDir,
        manifestFor(chapterKey, mangaKey: mangaKey, mangaTitle: mangaTitle),
      );
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

    test('downloads 中单章作品根 pages.json 也算已下载', () async {
      // 单章作品：pages.json + 页图直接放在漫画目录根，没有章子目录。
      final String rootManifestDir = p.join(
        root.path,
        'downloads',
        'Example Source',
        'Single chapter work',
      );
      await Directory(rootManifestDir).create(recursive: true);
      await File(p.join(rootManifestDir, '001.jpg')).writeAsBytes(<int>[1]);
      await writePagesManifestAtomically(
        Directory(rootManifestDir),
        manifestFor('/c/1'),
      );

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

    test('共享目录：第一部作品的 manifest 排在前时仍按身份识别另一部', () async {
      const OnlineMangaLibraryEntry other = OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: OnlineMangaSeries(
          key: '/series/other',
          title: 'Fixture series',
          raw: <String, Object?>{'url': '/series/other'},
        ),
        chapters: <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/other/1',
            name: 'Chapter 1',
            raw: <String, Object?>{'url': '/other/1'},
          ),
        ],
      );
      final String sharedDir = p.join(
        root.path,
        'downloads',
        'Example Source',
        'Fixture series',
      );
      // 按名字排序时 "A ..." 在前，所以第一份 manifest 属于另一部同名作品。
      await writeManifestChapter(
        sharedDir,
        'A other work',
        '/other/1',
        mangaKey: '/series/other',
      );
      await writeManifestChapter(
        sharedDir,
        'B fixture work',
        '/c/1',
        mangaKey: '/series/fixture',
      );

      final DownloadLibraryIndex index = DownloadLibraryIndex(db);
      expect(await index.downloadedChapterKeysForEntry(entry), <String>{
        '/c/1',
      }, reason: '共享目录里只认本作品身份证明的章');
      expect(await index.downloadedChapterKeysForEntry(other), <String>{
        '/other/1',
      }, reason: '另一部同名作品也只认自己的章');
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
