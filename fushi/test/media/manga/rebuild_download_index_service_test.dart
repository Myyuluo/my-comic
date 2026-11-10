import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_download_state.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:image/image.dart' as img;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_reader.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Ticket 09：Rebuild download index 的 re-link 半场。
///
/// 书架条目是主线：在**当前** Content root 的 `downloads` / `local` 里按
/// `pages.json` 稳定 ID 优先、文件夹名兜底重新定位章节，更新 `extractDir` 与
/// `manga_chapter_dirs` 映射。找不到的章保持记录并显示 Missing；不移动/删除
/// 任何文件，不读旧 Content root，不扫描 `autobackup`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory content;
  late Directory downloadsRoot;
  late Directory localComicRoot;
  late Directory oldContent;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('rebuild_download_index_');
    content = Directory(p.join(root.path, 'Content'));
    downloadsRoot = Directory(p.join(content.path, 'downloads'));
    localComicRoot = Directory(p.join(content.path, 'local'));
    oldContent = Directory(p.join(root.path, 'OldContent'));
    await downloadsRoot.create(recursive: true);
    await localComicRoot.create(recursive: true);
    await oldContent.create(recursive: true);
    // DownloadLibraryIndex 的测试缝：override 指向 `<content>`，它会派生出
    // `<content>/fushi_books` 与同级 `<content>/downloads`。
    EpubStorage.debugBaseDirectoryOverride = content.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  OnlineMangaLibraryEntry entryFor({
    String seriesKey = '/series/fixture',
    String title = 'Fixture series',
    List<OnlineMangaChapter>? chapters,
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.fixture',
    sourceId: '1',
    series: OnlineMangaSeries(
      key: seriesKey,
      title: title,
      raw: const <String, Object?>{},
    ),
    chapters:
        chapters ??
        const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/c/1',
            name: 'Chapter 1',
            raw: <String, Object?>{},
          ),
          OnlineMangaChapter(
            key: '/c/2',
            name: 'Chapter 2',
            raw: <String, Object?>{},
          ),
        ],
  );

  Future<EpubBookRow> insertOnlineBook({
    required String bookKey,
    required OnlineMangaLibraryEntry entry,
    required String extractDir,
    String? title,
    int importedAt = 1,
    bool inLibrary = true,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title ?? entry.series.title,
        epubPath: kDownloadPagesFileName,
        extractDir: extractDir,
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: importedAt,
        format: const Value<String>('manga'),
        inLibrary: Value<bool>(inLibrary),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  MangaPagesManifest manifestFor(
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter, {
    DateTime? downloadedAt,
  }) => MangaPagesManifest(
    sourceRuntime: entry.runtime.wireValue,
    sourceId: entry.sourceId,
    sourceName: 'Example Source',
    extensionPackage: entry.extensionPackage,
    mangaKey: entry.series.key,
    mangaTitle: entry.series.title,
    chapterKey: chapter.key,
    chapterName: chapter.name,
    payload: const MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: '001.jpg',
          size: MokuroSize(100, 150),
          blocks: <MokuroBlock>[],
        ),
      ],
    ),
    downloadedAt: downloadedAt ?? DateTime.utc(2026, 11, 7),
  );

  Future<Directory> writeChapter({
    required Directory mangaDir,
    required String folderName,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    String pageBytes = 'page',
    DateTime? downloadedAt,
  }) async {
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir.path,
      folderName,
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsString(pageBytes);
    await writePagesManifestAtomically(
      chapterDir,
      manifestFor(entry, chapter, downloadedAt: downloadedAt),
    );
    return chapterDir;
  }

  /// 手工制作一个 CBZ 章节：包根平铺 `001.jpg` + `pages.json`。
  Future<File> writeArchiveChapter({
    required Directory mangaDir,
    required String fileName,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    bool writePage = true,
  }) async {
    final Archive archive = Archive();
    if (writePage) {
      final List<int> page = utf8.encode('page');
      archive.addFile(ArchiveFile('001.jpg', page.length, page));
    }
    final List<int> manifest = utf8.encode(
      jsonEncode(manifestFor(entry, chapter).toJson()),
    );
    archive.addFile(
      ArchiveFile(kDownloadPagesFileName, manifest.length, manifest),
    );
    await mangaDir.create(recursive: true);
    final File file = downloadChapterArchiveFile(mangaDir.path, fileName);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  RebuildDownloadIndexService service() => RebuildDownloadIndexService(
    database: db,
    downloadsRoot: downloadsRoot,
    localComicRoot: localComicRoot,
  );

  /// 模拟「Download index 曾认为这一章已下载」：写一条 `done` 任务行。
  Future<void> markDownloaded(String bookKey, String chapterKey) =>
      db.upsertMangaDownloadJob(
        MangaDownloadJobsCompanion.insert(
          jobId: 'job-$bookKey-$chapterKey',
          kind: MangaDownloadJobKind.chapter,
          bookKey: bookKey,
          chapterKey: chapterKey,
          runtime: 'mihon',
          title: 'Fixture series',
          chapterTitle: chapterKey,
          status: const Value<String>(MangaDownloadJobStatus.done),
          createdAt: 1,
          updatedAt: 1,
        ),
      );

  /// 模拟「扩展和源都已安装」：恢复分支据此决定建在线条目还是本地条目。
  Future<void> installSource({
    String extensionPackage = 'org.example.fixture',
    String sourceId = '1',
  }) async {
    await db.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: extensionPackage,
        name: 'Fixture extension',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.5',
        language: 'en',
        apkPath: 'fixture.apk',
        apkSha256: 'sha',
        signerSha256: 'signer',
        installedAt: 1,
      ),
    );
    await db.replaceMangaOnlineSources(
      extensionPackage,
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: extensionPackage,
          sourceId: sourceId,
          name: 'Example Source',
          language: 'en',
        ),
      ],
    );
  }

  test('文件搬到新 Content root 后按 pages.json 稳定 ID 重新关联'
      '（目录改名也能找到），旧根不读、缺失章保留记录', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    final String oldMangaDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: oldMangaDir,
    );
    await markDownloaded(bookKey, '/c/2');
    // 旧根里放一份「同名章」——重建绝不能回头读它。
    await writeChapter(
      mangaDir: Directory(oldMangaDir),
      folderName: 'Chapter 2',
      entry: entry,
      chapter: entry.chapters[1],
      pageBytes: 'old page',
    );

    // 用户手动把第 1 章搬到新 Content root，并把漫画目录与章目录都改了名。
    final Directory newMangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Renamed series'),
    );
    final Directory newChapterDir = await writeChapter(
      mangaDir: newMangaDir,
      folderName: 'Ch 01',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksScanned, 1);
    expect(report.booksRelinked, 1);
    expect(report.chaptersRelinked, 1);
    expect(report.chaptersMissing, 1);
    expect(report.cancelled, isFalse);
    expect(report.failed, 0);

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(
      p.equals(row.extractDir, newMangaDir.path),
      isTrue,
      reason: '书目记录必须重指向当前 Content root 里按 ID 找到的漫画目录',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Ch 01',
      reason: '章目录改名后也必须按 pages.json 的稳定身份恢复映射',
    );
    expect(
      await db.getMangaChapterDir(bookKey, '/c/2'),
      isNull,
      reason: '旧根里的 Chapter 2 不得被读取，更不能写入映射',
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '重建后已下载章节必须能被阅读器定位',
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/2'),
      isFalse,
    );
    final MangaDownloadJobRow doneJob = MangaDownloadJobRow(
      jobId: 'job-2',
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/c/2',
      runtime: 'mihon',
      title: 'Fixture series',
      chapterTitle: 'Chapter 2',
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
      reason: '原任务记录 + 当前根下无文件 = Missing',
    );

    // 不删除记录，也不移动/删除任何文件。
    expect(await db.getEpubBook(bookKey), isNotNull);
    expect(newChapterDir.existsSync(), isTrue);
    expect(
      File(p.join(oldMangaDir, 'Chapter 2', '001.jpg')).existsSync(),
      isTrue,
      reason: '旧根文件原地保留（且从未被读取）',
    );
  });

  test('没有 pages.json 稳定身份时按文件夹名回退（ID 仍是首选）', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );

    // 当前根里的漫画目录名 = 作品标题（名称匹配），章节目录名 = 章标题；
    // 章目录里只有一份没有稳定身份的旧式 pages.json。
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory legacyChapter = downloadChapterDirectory(
      mangaDir.path,
      'Chapter 1',
    );
    await legacyChapter.create(recursive: true);
    await File(p.join(legacyChapter.path, '001.jpg')).writeAsString('page');
    await File(p.join(legacyChapter.path, 'pages.json')).writeAsString(
      '{"pages":[{"url":"001.jpg","width":100,"height":150,"blocks":[]}]}',
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.chaptersRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
      reason: '没有稳定 ID 的章目录按文件夹名回退关联',
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '按文件夹名关联后，可读容器即视为已下载（ticket 06：不要求 pages.json 校验）',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/2'), isNull);
  });

  test('没有 pages.json 的用户文件夹：重建按容器名关联后显示已下载（来源未安装）', () async {
    const String bookKey = 'mihon-user-folder';
    final OnlineMangaLibraryEntry entry = entryFor();
    // 导入的 Manga 行存在，但扩展 / 源没有安装（测试里刻意不 installSource）。
    final String oldMangaDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: oldMangaDir,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory userChapter = downloadChapterDirectory(
      mangaDir.path,
      'Chapter 1',
    );
    await userChapter.create(recursive: true);
    await File(p.join(userChapter.path, '001.jpg')).writeAsString('page');
    await File(p.join(userChapter.path, '002.jpg')).writeAsString('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
      reason: '没有 manifest 的容器按容器名与章节关联',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '关联后的无 manifest 容器只要可读就视为已下载',
    );
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1'},
    );
    expect(
      await index.resolveChapter(bookKey: bookKey, chapterKey: '/c/1'),
      isNotNull,
      reason: '已下载章必须能被阅读器定位',
    );
    expect(File(p.join(userChapter.path, '001.jpg')).existsSync(), isTrue);
  });

  test('带哈希后缀的章节文件夹（pages.json 损坏）：重建按容器名关联', () async {
    const String bookKey = 'mihon-hashed-folder';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    // 新命名在章名冲突时追加 `~<8 位哈希>`；pages.json 损坏 = 无稳定身份。
    final Directory hashedChapter = downloadChapterDirectory(
      mangaDir.path,
      'Chapter 1~a1b2c3d4',
    );
    await hashedChapter.create(recursive: true);
    await File(p.join(hashedChapter.path, '001.jpg')).writeAsString('page');
    await File(p.join(hashedChapter.path, 'pages.json')).writeAsString('{bad');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.chaptersRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1~a1b2c3d4',
      reason: '没有可用 pages.json 时，哈希后缀容器名也要能回退关联',
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
  });

  test('带哈希后缀的章节 CBZ（没有 pages.json）：重建按容器名关联', () async {
    const String bookKey = 'mihon-hashed-cbz';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await mangaDir.create(recursive: true);
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
    final File hashedArchive = downloadChapterArchiveFile(
      mangaDir.path,
      'Chapter 2~a1b2c3d4.cbz',
    );
    await hashedArchive.writeAsBytes(ZipEncoder().encode(archive)!);

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.chaptersRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))?.folderName,
      'Chapter 2~a1b2c3d4.cbz',
    );
    final MangaChapterContainer? container = await DownloadLibraryIndex(
      db,
    ).resolveChapter(bookKey: bookKey, chapterKey: '/c/2');
    expect(container?.isArchive, isTrue);
  });

  test('没有 pages.json 的用户 CBZ：重建按容器名关联，可定位且可阅读', () async {
    const String bookKey = 'mihon-user-cbz';
    final OnlineMangaLibraryEntry entry = entryFor();
    final String oldMangaDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: oldMangaDir,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await mangaDir.create(recursive: true);
    // 普通 CBZ：包根只有页图，没有 pages.json。
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
    final File userArchive = downloadChapterArchiveFile(
      mangaDir.path,
      'Chapter 2.cbz',
    );
    await userArchive.writeAsBytes(ZipEncoder().encode(archive)!);

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))?.folderName,
      'Chapter 2.cbz',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/2'),
      isTrue,
    );
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/2',
    );
    expect(container?.isArchive, isTrue);
    // 阅读器打开下载库 CBZ 的入口：包可打开且有可读页。
    expect(
      await LocalSourceReader.readArchiveContent(container!.archiveFile!.path),
      isNotNull,
    );
  });

  test('downloads 里根 pages.json 单章作品：重建后显示已下载且可阅读', () async {
    const String bookKey = 'mihon-root-manifest-downloads';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    // 用户提供的单章作品：pages.json + 页图直接放在漫画目录根，没有章子目录。
    // 目录名与作品标题不同：只有根 manifest 的稳定身份能把它关联回来。
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'User single chapter'),
    );
    await mangaDir.create(recursive: true);
    await File(p.join(mangaDir.path, '001.jpg')).writeAsString('page');
    await writePagesManifestAtomically(
      mangaDir,
      manifestFor(entry, entry.chapters.single),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
    expect(
      await db.getMangaChapterDir(bookKey, '/c/1'),
      isNull,
      reason: '根 pages.json 不是章容器，不能写 <manga>/<manga> 映射',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '单章作品根目录的 pages.json + 页负载可读即视为已下载',
    );
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull, reason: '阅读器要能按根 manifest 定位这一章');
    expect(
      p.equals(
        container!.manifestFile!.path,
        p.join(mangaDir.path, 'pages.json'),
      ),
      isTrue,
    );
    expect(container.imagesDirectory!.path, mangaDir.path);
    expect(
      await readDownloadLibraryChapterPayload(mangaDir),
      isNotNull,
      reason: '根 manifest 的页负载可读（阅读器装载路径）',
    );
  });

  test('占位扩展包条目按数字 sourceId + seriesKey 重链真实包 manifest', () async {
    const String bookKey = 'mihon-placeholder';
    final OnlineMangaLibraryEntry real = entryFor();
    final OnlineMangaLibraryEntry placeholder = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'mihon.unavailable',
      sourceId: '1',
      series: real.series,
      chapters: real.chapters,
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: placeholder,
      extractDir: p.join(
        downloadsRoot.path,
        'Example Source',
        'Old missing folder',
      ),
    );
    // 磁盘 manifest 是真实扩展包写的；条目身份仍是导入时的占位包。
    final Directory moved = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Renamed series'),
    );
    await writeChapter(
      mangaDir: moved,
      folderName: 'Chapter 1',
      entry: real,
      chapter: real.chapters.first,
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    expect(
      (await db.getEpubBook(bookKey))!.extractDir,
      moved.path,
      reason: '占位包与真实包视为同一身份，数字 sourceId + seriesKey 命中',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
  });

  test('同名文件夹与 pages.json 身份同时存在时，稳定 ID 优先于文件夹名', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );

    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    // 名称看起来对、但没有稳定身份的目录。
    final Directory nameOnly = downloadChapterDirectory(
      mangaDir.path,
      'Chapter 1',
    );
    await nameOnly.create(recursive: true);
    await File(p.join(nameOnly.path, '001.jpg')).writeAsString('name-only');
    // 名称完全不同、但 pages.json 身份属于本章的目录。
    final Directory idMatch = await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Totally different folder',
      entry: entry,
      chapter: entry.chapters.single,
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.chaptersRelinked, 1);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Totally different folder',
      reason: 'pages.json 稳定 ID 比文件夹名更强，不能被同名目录抢先',
    );
    expect(idMatch.existsSync(), isTrue);
    expect(nameOnly.existsSync(), isTrue, reason: '不得删除/移动任何目录');
  });

  test('重复运行是幂等的：第二次不再改库，缺失统计保持一致', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    await markDownloaded(bookKey, '/c/2');
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport first = await service().run();
    final String extractAfterFirst = (await db.getEpubBook(
      bookKey,
    ))!.extractDir;
    final String? mappingAfterFirst = (await db.getMangaChapterDir(
      bookKey,
      '/c/1',
    ))?.folderName;

    final RebuildDownloadIndexReport second = await service().run();

    expect(first.booksRelinked, 1);
    expect(first.chaptersRelinked, 1);
    expect(first.chaptersMissing, 1);
    expect(second.booksRelinked, 0, reason: '第二次没有可更新的路径');
    expect(second.chaptersRelinked, 0, reason: '第二次没有可更新的映射');
    expect(second.chaptersMissing, 1);
    expect(second.cancelled, isFalse);
    expect((await db.getEpubBook(bookKey))!.extractDir, extractAfterFirst);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      mappingAfterFirst,
    );
  });

  test('显示进度；取消时停在下一本之前，已完成部分保留', () async {
    final OnlineMangaLibraryEntry firstEntry = entryFor(
      seriesKey: '/series/first',
      title: 'First series',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final OnlineMangaLibraryEntry secondEntry = entryFor(
      seriesKey: '/series/second',
      title: 'Second series',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/2',
          name: 'Chapter 2',
          raw: <String, Object?>{},
        ),
      ],
    );
    await insertOnlineBook(
      bookKey: 'mihon-first',
      entry: firstEntry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'First series',
      ),
      importedAt: 2,
    );
    await insertOnlineBook(
      bookKey: 'mihon-second',
      entry: secondEntry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Second series',
      ),
      importedAt: 1,
    );
    await writeChapter(
      mangaDir: Directory(
        p.join(downloadsRoot.path, 'Example Source', 'First series'),
      ),
      folderName: 'Chapter 1',
      entry: firstEntry,
      chapter: firstEntry.chapters.single,
    );

    final RebuildDownloadIndexCancelToken token =
        RebuildDownloadIndexCancelToken();
    final List<RebuildDownloadIndexProgress> progress =
        <RebuildDownloadIndexProgress>[];
    final RebuildDownloadIndexReport report = await service().run(
      cancelToken: token,
      onProgress: (RebuildDownloadIndexProgress value) {
        progress.add(value);
        if (value.total == 2 && value.completed == 0) token.cancel();
      },
    );

    expect(report.cancelled, isTrue);
    expect(report.booksScanned, 2);
    expect(report.booksRelinked, 1, reason: '取消前已处理的第一本保留更新');
    expect(progress.first.total, 2);
    expect(
      progress.map((RebuildDownloadIndexProgress p) => p.currentTitle),
      contains('First series'),
    );
    expect(
      (await db.getEpubBook('mihon-first'))!.extractDir,
      p.join(downloadsRoot.path, 'Example Source', 'First series'),
      reason: '取消前完成的书已重指向新根',
    );
    expect(
      (await db.getEpubBook('mihon-second'))!.extractDir,
      p.join(oldContent.path, 'downloads', 'Example Source', 'Second series'),
      reason: '取消后不再处理后面的书',
    );
  });

  test('Local source 条目搬到新 Content root 后按相对路径重新关联（原地读取）', () async {
    final Directory oldLocalRoot = Directory(p.join(oldContent.path, 'local'));
    final File oldPage =
        File(p.join(oldLocalRoot.path, 'Local Manga', 'Ch 1', '001.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('old page');
    await LocalSourceLibrary(
      db: db,
      root: oldLocalRoot,
    ).registerScannedManga((await scanLocalSourceRoot(oldLocalRoot)).single);
    final EpubBookRow before = (await db.getAllEpubBooks()).single;

    // 用户把整个作品目录搬到新 Content root 的 local 下。
    final Directory newMangaDir = Directory(
      p.join(localComicRoot.path, 'Local Manga'),
    );
    final File newPage = File(p.join(newMangaDir.path, 'Ch 1', '001.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksScanned, 1);
    expect(report.booksRelinked, 1);
    final EpubBookRow after = (await db.getEpubBook(before.bookKey))!;
    expect(
      p.equals(after.extractDir, newMangaDir.path),
      isTrue,
      reason: 'Local source 原地读取，extractDir 必须指向当前 local 根',
    );
    expect(
      LocalSourceMetadata.tryParse(after.sourceMetadata)?.relativePath,
      'Local Manga',
    );
    expect(
      decodeLocalSourceChapters(
        after.chaptersJson,
      ).map((LocalSourceChapterRecord c) => c.key),
      <String>['Ch 1'],
    );
    // 不复制、不删除任何文件。
    expect(oldPage.existsSync(), isTrue);
    expect(newPage.readAsStringSync(), 'new page');
  });

  test('Local source 改名后按文件夹名回退；找不到的作品保留记录并计 Missing', () async {
    final Directory oldLocalRoot = Directory(p.join(oldContent.path, 'local'));
    final File oldLocalPage = File(
      p.join(oldLocalRoot.path, 'Old local name', 'Ch 1', '001.jpg'),
    );
    oldLocalPage.parent.createSync(recursive: true);
    oldLocalPage.writeAsStringSync('page');
    await LocalSourceLibrary(
      db: db,
      root: oldLocalRoot,
    ).registerScannedManga((await scanLocalSourceRoot(oldLocalRoot)).single);
    final EpubBookRow before = (await db.getAllEpubBooks()).single;
    // 用户在新根里把作品文件夹改了名，并把书架标题也改成了新名字。
    await (db.update(db.epubBooks)
          ..where((t) => t.bookKey.equals(before.bookKey)))
        .write(const EpubBooksCompanion(title: Value<String>('Renamed local')));
    final File renamedPage = File(
      p.join(localComicRoot.path, 'Renamed local', 'Ch 1', '001.jpg'),
    );
    renamedPage.parent.createSync(recursive: true);
    renamedPage.writeAsStringSync('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    final EpubBookRow after = (await db.getEpubBook(before.bookKey))!;
    expect(
      p.equals(after.extractDir, p.join(localComicRoot.path, 'Renamed local')),
      isTrue,
      reason: '相对路径失效时按标题/文件夹名回退',
    );
    expect(
      LocalSourceMetadata.tryParse(after.sourceMetadata)?.relativePath,
      'Renamed local',
      reason: '重新关联后要写回新的相对路径',
    );

    // 再跑一次：仍找不到新根里不存在的作品（这里把目录挪走模拟丢失），
    // 记录保留、文件不删，并计入 Missing。
    final Directory renamed = Directory(
      p.join(localComicRoot.path, 'Renamed local'),
    );
    final Directory elsewhere = Directory(
      p.join(root.path, 'elsewhere', 'Renamed local'),
    );
    elsewhere.parent.createSync(recursive: true);
    await renamed.rename(elsewhere.path);
    final RebuildDownloadIndexReport missing = await service().run();
    expect(missing.booksMissing, 1);
    expect(missing.chaptersMissing, 1);
    final EpubBookRow retained = (await db.getEpubBook(before.bookKey))!;
    expect(retained.extractDir, after.extractDir, reason: '找不到文件不得删除或改写记录');
    expect(elsewhere.existsSync(), isTrue);
  });

  test('不扫描 autobackup；local 里书架没有的作品由票 10 补建条目', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    final String oldMangaDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: 'mihon-fixture',
      entry: entry,
      extractDir: oldMangaDir,
    );
    await markDownloaded('mihon-fixture', '/c/1');
    await markDownloaded('mihon-fixture', '/c/2');
    // autobackup 里放一份身份完全匹配的「下载」——绝不能被当成 Download library。
    await writeChapter(
      mangaDir: Directory(
        p.join(content.path, 'autobackup', 'Example Source', 'Fixture series'),
      ),
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    // local 里放一部书架没有的作品——票 10 负责创建条目。
    final File orphanPage = File(
      p.join(localComicRoot.path, 'Orphan local', 'Ch 1', '001.jpg'),
    );
    orphanPage.parent.createSync(recursive: true);
    orphanPage.writeAsStringSync('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMissing, 1);
    expect(report.chaptersMissing, 2);
    expect(report.booksAdded, 1, reason: 'local 里的孤儿作品会被补建');
    expect(
      (await db.getEpubBook('mihon-fixture'))!.extractDir,
      oldMangaDir,
      reason: 'autobackup 里的文件不是 Download library，不得参与 re-link',
    );
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows.length, 2);
    final EpubBookRow added = rows.singleWhere(
      (EpubBookRow row) => row.bookKey != 'mihon-fixture',
    );
    expect(
      p.equals(added.extractDir, p.join(localComicRoot.path, 'Orphan local')),
      isTrue,
      reason: '只登记 local 里的作品，不碰 autobackup',
    );
    expect(p.isWithin(content.path, added.extractDir), isTrue);
    expect(
      p.isWithin(p.join(content.path, 'autobackup'), added.extractDir),
      isFalse,
    );
  });

  test('同名候选有歧义且无稳定 ID 时跳过并报告，不猜、不改库', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    final String oldMangaDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: oldMangaDir,
    );
    await markDownloaded(bookKey, '/c/1');
    await markDownloaded(bookKey, '/c/2');
    // 两个不同 Source 下都有同名 Manga 目录，且都没有 pages.json 身份。
    for (final String source in <String>['Source A', 'Source B']) {
      final Directory chapterDir = Directory(
        p.join(downloadsRoot.path, source, 'Fixture series', 'Chapter 1'),
      );
      chapterDir.createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsStringSync('page');
    }

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksSkipped, 1);
    expect(report.chaptersSkipped, 2);
    expect(report.booksRelinked, 0);
    expect(
      (await db.getEpubBook(bookKey))!.extractDir,
      oldMangaDir,
      reason: '歧义匹配不得改写记录',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
    expect(await db.getMangaChapterDir(bookKey, '/c/2'), isNull);
    expect(
      await db.getAllEpubBooks(),
      hasLength(1),
      reason: '歧义候选不能被当成新作品恢复，否则等于猜了一个匹配',
    );
  });

  test('downloads 里书架没有的作品：源已安装时创建在线条目并标记已下载章节', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 2',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 1);
    expect(report.booksAddedLocal, 0);
    expect(report.chaptersAdded, 2);
    final String bookKey = onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final OnlineMangaLibraryEntry recovered = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    )!;
    expect(recovered.runtime, OnlineMangaRuntimeKind.mihon);
    expect(recovered.extensionPackage, entry.extensionPackage);
    expect(recovered.sourceId, entry.sourceId);
    expect(recovered.series.key, entry.series.key);
    expect(recovered.series.title, entry.series.title);
    expect(
      recovered.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/c/1', '/c/2'],
    );
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))?.folderName,
      'Chapter 2',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
    );
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/2'),
      isTrue,
    );

    // 幂等：第二次不再新增条目 / 重复映射，文件原样保留。
    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect(second.chaptersAdded, 0);
    expect((await db.getAllEpubBooks()).length, 1);
    expect(
      File(p.join(mangaDir.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(mangaDir.path, 'Chapter 2', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('downloads 里书架没有的作品：源未安装时降级为指向该文件夹的本地条目并报告', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    // 刻意不安装扩展 / 在线源。
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 2',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 0);
    expect(report.booksAddedLocal, 1);
    expect(report.booksAddedLocalSourceMissing, 1);
    expect(report.chaptersAdded, 2);
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows.length, 1);
    final EpubBookRow row = rows.single;
    expect(
      row.bookKey,
      localSourceBookKeyFor(mangaDir.path),
      reason: '降级后的本地条目身份 = 文件夹路径',
    );
    expect(OnlineMangaLibraryEntry.tryParse(row.sourceMetadata), isNull);
    final LocalSourceMetadata metadata = LocalSourceMetadata.tryParse(
      row.sourceMetadata,
    )!;
    expect(metadata.relativePath, 'Example Source/Fixture series');
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
    expect(
      decodeLocalSourceChapters(
        row.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Chapter 1', 'Chapter 2'],
    );

    // 降级条目仍可阅读：Local source reader 接受当前 Download library 根里的
    // 恢复条目（不复制文件）。
    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: row.bookKey,
          chapterIndex: 0,
          downloadsRoot: downloadsRoot,
        );
    expect(resolved, isNotNull);
    expect(
      p.equals(
        resolved!.chapterDirectory.path,
        p.join(mangaDir.path, 'Chapter 1'),
      ),
      isTrue,
    );

    // 幂等：第二次不会把同一目录再加一遍。
    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect(second.booksSkipped, 0);
    expect((await db.getAllEpubBooks()).length, 1);
    expect(
      File(p.join(mangaDir.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('downloads 里没有 pages.json 的目录：扫描图片建本地条目', () async {
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Manual Source', 'Manual manga'),
    );
    for (final String chapter in <String>['Ch 1', 'Ch 2']) {
      final Directory chapterDir = Directory(p.join(mangaDir.path, chapter))
        ..createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsStringSync('page-1');
      File(p.join(chapterDir.path, '002.jpg')).writeAsStringSync('page-2');
    }

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 0);
    expect(report.booksAddedLocal, 1);
    expect(report.booksAddedLocalSourceMissing, 0);
    expect(report.chaptersAdded, 2);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.bookKey, localSourceBookKeyFor(mangaDir.path));
    expect(row.title, 'Manual manga');
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
    expect(row.chapterCount, 4);
    expect(
      decodeLocalSourceChapters(
        row.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Ch 1', 'Ch 2'],
    );
    // 没有写 pages.json，也没有复制/删除任何文件。
    expect(
      File(p.join(mangaDir.path, 'Ch 1', 'pages.json')).existsSync(),
      isFalse,
    );
    expect(
      File(p.join(mangaDir.path, 'Ch 1', '002.jpg')).readAsStringSync(),
      'page-2',
    );
    // 来源未安装也能读：降级条目经 Local source 阅读路径原地读取无 manifest
    // 文件夹（ticket 06「关联后的容器可以阅读」）。
    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: row.bookKey,
          chapterIndex: 0,
          downloadsRoot: downloadsRoot,
        );
    expect(resolved, isNotNull);
    expect(resolved!.payload.images, isNotEmpty);

    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect((await db.getAllEpubBooks()).length, 1);
  });

  test('local 里书架没有的作品也会被登记；重复运行不重复添加', () async {
    final File page =
        File(p.join(localComicRoot.path, 'Local orphan', 'Ch 1', '001.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 0);
    expect(report.booksAddedLocal, 1);
    expect(report.booksAddedLocalSourceMissing, 0);
    expect(report.chaptersAdded, 1);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.bookKey, localSourceBookKeyFor(page.parent.parent.path));
    expect(row.title, 'Local orphan');
    final LocalSourceMetadata metadata = LocalSourceMetadata.tryParse(
      row.sourceMetadata,
    )!;
    expect(metadata.relativePath, 'Local orphan');
    expect(
      decodeLocalSourceChapters(
        row.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Ch 1'],
    );

    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect(second.booksRelinked, 0);
    expect((await db.getAllEpubBooks()).length, 1);
    expect(page.readAsStringSync(), 'page');
  });

  /// 一张真实可解码的页图（封面生成要能解码第一页）。
  List<int> coverTestPageBytes() {
    final img.Image image = img.Image(width: 400, height: 600)
      ..clear(img.ColorRgb8(255, 0, 0));
    return img.encodePng(image);
  }

  test('Rebuild 给只经它登记的本地作品生成 cover.jpg 并写入 coverPath', () async {
    final Directory mangaDir = Directory(
      p.join(localComicRoot.path, 'Cover orphan'),
    );
    final File page = File(p.join(mangaDir.path, 'Ch 1', '001.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(coverTestPageBytes());

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAddedLocal, 1);
    final File cover = File(p.join(mangaDir.path, 'cover.jpg'));
    expect(cover.existsSync(), isTrue, reason: 'Rebuild 登记时补齐封面');
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.coverPath, 'cover.jpg', reason: '书架 / 作品页据此显示封面');
    expect(page.readAsBytesSync(), isNotEmpty);

    // 幂等：再跑一次不重复生成、不覆盖已生成的封面。
    final List<int> coverBytes = cover.readAsBytesSync();
    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect(cover.readAsBytesSync(), coverBytes);
  });

  test('Rebuild 重链已登记的 CBZ 本地作品时补封面并更新 coverPath', () async {
    final Directory mangaDir = Directory(
      p.join(localComicRoot.path, 'Cover cbz'),
    );
    await mangaDir.create(recursive: true);
    final List<int> pageBytes = coverTestPageBytes();
    final Archive archive = Archive()
      ..addFile(ArchiveFile('001.png', pageBytes.length, pageBytes));
    await File(
      p.join(mangaDir.path, 'Ch 1.cbz'),
    ).writeAsBytes(ZipEncoder().encode(archive)!);
    final LocalSourceManga scanned = (await scanLocalSourceRoot(
      localComicRoot,
    )).single;
    await LocalSourceLibrary(
      db: db,
      root: localComicRoot,
    ).registerScannedManga(scanned);
    // CBZ 的页没有独立文件：登记时 coverPath 为空，正是需要 Rebuild 补齐的情形。
    expect((await db.getAllEpubBooks()).single.coverPath, isNull);

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, greaterThanOrEqualTo(1));
    final File cover = File(p.join(mangaDir.path, 'cover.jpg'));
    expect(cover.existsSync(), isTrue, reason: '重链时补齐缺失封面');
    expect((await db.getAllEpubBooks()).single.coverPath, 'cover.jpg');
  });

  test('尊重 book_tombstones：主动移出书架的下载/本地作品不会被重新加入', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory downloaded = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: downloaded,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await db.insertBookTombstone(
      onlineMangaBookKeyFor(
        runtime: entry.runtime,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        seriesKey: entry.series.key,
      ),
    );

    final File localPage =
        File(p.join(localComicRoot.path, 'Tombstoned local', 'Ch 1', '001.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('page');
    final Directory localMangaDir = localPage.parent.parent;
    await db.insertBookTombstone(localSourceBookKeyFor(localMangaDir.path));

    // downloads 里没有 pages.json 的手工目录：按本地身份立碑也要跳过。
    final File manualPage =
        File(
            p.join(
              downloadsRoot.path,
              'Manual Source',
              'Manual manga',
              'Ch 1',
              '001.jpg',
            ),
          )
          ..createSync(recursive: true)
          ..writeAsStringSync('page');
    await db.insertBookTombstone(
      localSourceBookKeyFor(manualPage.parent.parent.path),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 0);
    expect(report.booksSkipped, 3);
    expect(report.booksSkippedTombstoned, 3);
    expect(await db.getAllEpubBooks(), isEmpty);
    // 只跳过登记，不删文件。
    expect(
      File(p.join(downloaded.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(localPage.existsSync(), isTrue);
    expect(manualPage.existsSync(), isTrue);
    expect((await db.getBookTombstoneKeys()).length, 3);
  });

  test('报告新增/更新/缺失/跳过数量，且不删除已有记录和文件', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );

    // 1) 书架里的在线条目：文件已不在当前 Content root → Missing。
    final OnlineMangaLibraryEntry missingEntry = entryFor(
      seriesKey: '/series/missing',
      title: 'Missing series',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    await insertOnlineBook(
      bookKey: 'mihon-missing',
      entry: missingEntry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Missing series',
      ),
    );
    await markDownloaded('mihon-missing', '/c/1');

    // 2) 书架里的 Local source 条目：用户把目录搬到了当前 local → 更新。
    final Directory oldLocalRoot = Directory(p.join(oldContent.path, 'local'));
    File(p.join(oldLocalRoot.path, 'Moved local', 'Ch 1', '001.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old local page');
    await LocalSourceLibrary(
      db: db,
      root: oldLocalRoot,
    ).registerScannedManga((await scanLocalSourceRoot(oldLocalRoot)).single);
    final String movedLocalKey = (await db.getAllEpubBooks())
        .singleWhere((EpubBookRow row) => row.title == 'Moved local')
        .bookKey;
    final Directory movedLocal = Directory(
      p.join(localComicRoot.path, 'Moved local'),
    );
    File(p.join(movedLocal.path, 'Ch 1', '001.jpg'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new local page');

    // 3) downloads 里书架没有的作品：源已安装 → 新增在线条目。
    final OnlineMangaLibraryEntry newEntry = entryFor(
      seriesKey: '/series/new',
      title: 'New series',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/2',
          name: 'Chapter 2',
          raw: <String, Object?>{},
        ),
      ],
    );
    await writeChapter(
      mangaDir: Directory(
        p.join(downloadsRoot.path, 'Example Source', 'New series'),
      ),
      folderName: 'Chapter 2',
      entry: newEntry,
      chapter: newEntry.chapters.single,
    );

    // 4) 主动移出书架的 local 作品 → 跳过。
    final File tombstonedPage =
        File(p.join(localComicRoot.path, 'Tombstoned', 'Ch 1', '001.jpg'))
          ..createSync(recursive: true)
          ..writeAsStringSync('page');
    await db.insertBookTombstone(
      localSourceBookKeyFor(tombstonedPage.parent.parent.path),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 1);
    expect(report.booksAddedLocal, 0);
    expect(report.booksRelinked, 1);
    expect(report.booksMissing, 1);
    expect(report.booksSkipped, 1);
    expect(report.booksSkippedTombstoned, 1);
    expect(report.chaptersAdded, 1);
    expect(report.chaptersMissing, 1);
    expect(
      (await db.getAllEpubBooks()).map((EpubBookRow row) => row.bookKey),
      containsAll(<String>[
        'mihon-missing',
        movedLocalKey,
        onlineMangaBookKeyFor(
          runtime: newEntry.runtime,
          extensionPackage: newEntry.extensionPackage,
          sourceId: newEntry.sourceId,
          seriesKey: newEntry.series.key,
        ),
      ]),
    );
    expect((await db.getAllEpubBooks()).length, 3);
    expect(
      p.equals(
        (await db.getEpubBook(movedLocalKey))!.extractDir,
        movedLocal.path,
      ),
      isTrue,
      reason: '已搬动的 Local source 条目被更新到当前根',
    );
    // 文件从未被移动或删除；缺失记录也保留在库。
    expect(
      File(p.join(movedLocal.path, 'Ch 1', '001.jpg')).readAsStringSync(),
      'new local page',
    );
    expect(
      File(
        p.join(oldLocalRoot.path, 'Moved local', 'Ch 1', '001.jpg'),
      ).existsSync(),
      isTrue,
    );
    expect(tombstonedPage.existsSync(), isTrue);
  });

  test('半成品章节不会进入恢复后的下载索引', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    // 第二章 pages.json 完整但页文件已被删掉（半成品）——不能算已下载。
    final Directory incomplete = await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 2',
      entry: entry,
      chapter: entry.chapters[1],
    );
    File(p.join(incomplete.path, '001.jpg')).deleteSync();

    final RebuildDownloadIndexReport report = await service().run();

    final String bookKey = onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );
    expect(report.booksAdded, 1);
    expect(report.chaptersAdded, 1);
    final OnlineMangaLibraryEntry recovered = OnlineMangaLibraryEntry.tryParse(
      (await db.getEpubBook(bookKey))!.sourceMetadata,
    )!;
    expect(
      recovered.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/c/1'],
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/2'), isNull);
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/2'),
      isFalse,
    );
  });

  test('重建不清除 manga_chapter_dirs 记录：指向被 ID 认领目录的旧映射原样保留', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: mangaDir.path,
    );
    // /c/2 的旧映射指向磁盘上已被 pages.json 证明属于 /c/1 的目录。
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/2',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );

    await service().run();

    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))?.folderName,
      'Chapter 1',
      reason: 'Rebuild 只增改数据库行，绝不删除记录（spec 规则 4）',
    );
  });

  test('手工放置的 CBZ 章节：重建按 pages.json 身份关联为 archive，可定位/删除', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );

    // 用户手工把一个 CBZ 章节放进当前 Content root，漫画目录还改了名。
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Renamed series'),
    );
    final File cbz = await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 1.cbz',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.chaptersRelinked, 1);
    expect(report.failed, 0);
    expect(
      p.equals((await db.getEpubBook(bookKey))!.extractDir, mangaDir.path),
      isTrue,
    );
    final MangaChapterDirRow mapping = (await db.getMangaChapterDir(
      bookKey,
      '/c/1',
    ))!;
    expect(mapping.folderName, 'Chapter 1.cbz');
    expect(mapping.containerKindEnum, MangaChapterContainerKind.archive);

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/c/1',
    );
    expect(container, isNotNull);
    expect(container!.isArchive, isTrue);
    expect(container.archiveFile!.path, cbz.path);
    expect(
      await index.isChapterDownloaded(bookKey: bookKey, chapterKey: '/c/1'),
      isTrue,
      reason: '手工放置的 CBZ 必须被识别为已下载',
    );

    await index.deleteChapter(bookKey: bookKey, chapterKey: '/c/1');
    expect(cbz.existsSync(), isFalse, reason: '删压缩包章节 = 删对应文件');
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
  });

  test('同一漫画目录混排文件夹与 CBZ：分别记录容器类型，重复运行幂等', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    final File archive = await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 2.cbz',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final RebuildDownloadIndexReport first = await service().run();

    expect(first.chaptersRelinked, 2);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))!.containerKindEnum,
      MangaChapterContainerKind.folder,
    );
    final MangaChapterDirRow archiveRow = (await db.getMangaChapterDir(
      bookKey,
      '/c/2',
    ))!;
    expect(archiveRow.folderName, 'Chapter 2.cbz');
    expect(archiveRow.containerKindEnum, MangaChapterContainerKind.archive);
    expect(
      await DownloadLibraryIndex(
        db,
      ).downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1', '/c/2'},
    );

    final RebuildDownloadIndexReport second = await service().run();
    expect(second.chaptersRelinked, 0, reason: '容器名与类型都没变 = 幂等');
    expect(archive.existsSync(), isTrue);
  });

  test('downloads 里书架没有的作品：仅 CBZ 章节也建在线条目并标记 archive', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 1.cbz',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 2.cbz',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedOnline, 1);
    expect(report.chaptersAdded, 2);
    final String bookKey = onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))!.containerKindEnum,
      MangaChapterContainerKind.archive,
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))!.folderName,
      'Chapter 1.cbz',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))!.containerKindEnum,
      MangaChapterContainerKind.archive,
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.downloadedChapterKeys(bookKey, <String>['/c/1', '/c/2']),
      <String>{'/c/1', '/c/2'},
    );

    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksAdded, 0);
    expect(second.chaptersAdded, 0);
  });

  test('downloads 里书架没有的作品：源未安装的纯 CBZ 目录降级为本地条目', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    // 刻意不安装扩展 / 在线源。
    await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 1.cbz',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedLocal, 1);
    expect(report.booksAddedLocalSourceMissing, 1);
    expect(report.chaptersAdded, 1);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.bookKey, localSourceBookKeyFor(mangaDir.path));
    expect(
      decodeLocalSourceChapters(
        row.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Chapter 1.cbz'],
    );
  });

  test('local 中带 manifest 的文件夹按身份关联到在线 Manga 行（含非书架）', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
      inLibrary: false,
    );
    // 目录名与作品标题毫无关系：只有 pages.json 能证明身份。
    final Directory localMangaDir = Directory(
      p.join(localComicRoot.path, '完全不同的本地目录'),
    );
    await writeChapter(
      mangaDir: localMangaDir,
      folderName: 'Local Ch 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeChapter(
      mangaDir: localMangaDir,
      folderName: 'Local Ch 2',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksScanned, 1);
    expect(report.booksMatched, 1);
    expect(report.booksRelinked, 1);
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(after.isInLibrary, isFalse, reason: '非书架归属不被重建改写');
    expect(
      p.equals(after.extractDir, localMangaDir.path),
      isTrue,
      reason: 'local manifest 证明身份时，在线行关联到该本地目录',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Local Ch 1',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/2'))?.folderName,
      'Local Ch 2',
    );
    expect(
      await db.getAllEpubBooks(),
      hasLength(1),
      reason: '已被在线行认领的 local 目录不能再登记成重复的本地条目',
    );
    // 只关联、不搬移、不删除任何文件。
    expect(
      File(p.join(localMangaDir.path, 'Local Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(localMangaDir.path, 'Local Ch 2', '001.jpg')).existsSync(),
      isTrue,
    );

    // 幂等：第二次仍能匹配，但不再改写记录、不再补建条目。
    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksMatched, 1);
    expect(second.booksRelinked, 0);
    expect(second.booksAdded, 0);
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('local 单章作品根 pages.json：关联目录但不合成假章容器、不计 relinked', () async {
    const String bookKey = 'mihon-root-manifest';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
      inLibrary: false,
    );
    // 单章作品把 pages.json 直接放在 local/<manga> 根；没有章节子目录。
    final Directory localMangaDir = Directory(
      p.join(localComicRoot.path, 'Single chapter'),
    );
    await localMangaDir.create(recursive: true);
    await File(
      p.join(localMangaDir.path, '001.jpg'),
    ).writeAsBytes(<int>[1, 2, 3]);
    await writePagesManifestAtomically(
      localMangaDir,
      manifestFor(entry, entry.chapters.single),
    );
    // 下载索引曾认为这一章已下载：根 manifest 存在且页齐时不能报 Missing。
    await markDownloaded(bookKey, '/c/1');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 1);
    expect(report.chaptersRelinked, 0, reason: '根 pages.json 不是章容器，不能计为已写入映射');
    expect(
      report.chaptersMissing,
      0,
      reason: '根 manifest + 页图齐全时章确实已下载，不能报 Missing',
    );
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      p.equals(after.extractDir, localMangaDir.path),
      isTrue,
      reason: '仍要把作品目录（extractDir）关联到 local 文件夹',
    );
    expect(
      await db.getMangaChapterDir(bookKey, '/c/1'),
      isNull,
      reason: '不能写 <manga>/<manga> 这种不可用的章映射',
    );
    // 已下载状态仍由共享 manifest 扫描提供（根 manifest 也算一章）。
    final Set<String> downloaded =
        await DownloadLibraryIndex(
          db,
          downloadsRoot: downloadsRoot,
          localComicRoot: localComicRoot,
        ).downloadedChapterKeysForEntry(
          entry,
          row: after,
          chapterKeys: const <String>['/c/1'],
        );
    expect(downloaded, <String>{'/c/1'});

    // 幂等：第二次重建不再改写。
    final RebuildDownloadIndexReport second = await service().run();
    expect(second.booksMatched, 1);
    expect(second.booksRelinked, 0);
    expect(second.chaptersRelinked, 0);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
  });

  test('membership=false 的 Manga 行也按 pages.json 身份 re-link', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor();
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
      inLibrary: false,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksScanned, 1);
    expect(report.booksMatched, 1);
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(after.isInLibrary, isFalse);
    expect(p.equals(after.extractDir, mangaDir.path), isTrue);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
  });

  test('重复副本优先已记录的 extractDir（即使另一份更新）', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final Directory recordedDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory newerCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series (2)'),
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: recordedDir.path,
    );
    await writeChapter(
      mangaDir: recordedDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 1),
    );
    await writeChapter(
      mangaDir: newerCopy,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 9),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 1);
    expect(report.booksAmbiguous, 0);
    expect(report.booksSkipped, 0);
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      p.equals(after.extractDir, recordedDir.path),
      isTrue,
      reason: '已记录的下载目录优先于更新的重复副本',
    );
    expect(
      File(p.join(newerCopy.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '未采用的重复副本原样保留',
    );
  });

  test('没有记录目录时重复副本优先最新完整副本', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final Directory olderCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory newerCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series (2)'),
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: p.join(
        oldContent.path,
        'downloads',
        'Example Source',
        'Fixture series',
      ),
    );
    await writeChapter(
      mangaDir: olderCopy,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 1),
    );
    await writeChapter(
      mangaDir: newerCopy,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 9),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 1);
    expect(report.booksAmbiguous, 0);
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      p.equals(after.extractDir, newerCopy.path),
      isTrue,
      reason: '没有记录目录时采用 manifest 时间最新的完整副本',
    );
    expect(
      File(p.join(olderCopy.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '较旧的重复副本原样保留',
    );
  });

  test('重复副本无法决定时跳过并报告歧义，不改记录、不删文件、不补建重复条目', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final Directory firstCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory secondCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series (2)'),
    );
    final String recorded = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: recorded,
    );
    final DateTime sameTime = DateTime.utc(2026, 11, 9);
    for (final Directory copy in <Directory>[firstCopy, secondCopy]) {
      await writeChapter(
        mangaDir: copy,
        folderName: 'Chapter 1',
        entry: entry,
        chapter: entry.chapters.single,
        downloadedAt: sameTime,
      );
    }

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 0);
    expect(report.booksRelinked, 0);
    expect(report.booksSkipped, 1);
    expect(report.booksAmbiguous, 1);
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(after.extractDir, recorded, reason: '无法决定时不得改写记录');
    expect(
      await db.getMangaChapterDir(bookKey, '/c/1'),
      isNull,
      reason: '无法决定时不得写映射',
    );
    expect(await db.getAllEpubBooks(), hasLength(1));
    for (final Directory copy in <Directory>[firstCopy, secondCopy]) {
      expect(
        File(p.join(copy.path, 'Chapter 1', '001.jpg')).existsSync(),
        isTrue,
        reason: '不删除任何重复副本文件',
      );
    }
  });

  test('local 中带 manifest 的孤儿作品仍按现有语义登记为本地条目', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory localMangaDir = Directory(
      p.join(localComicRoot.path, 'Unindexed local'),
    );
    await writeChapter(
      mangaDir: localMangaDir,
      folderName: 'Ch 1',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 1);
    expect(report.booksAddedLocal, 1);
    final EpubBookRow epubBook = (await db.getAllEpubBooks()).single;
    expect(
      LocalSourceMetadata.tryParse(epubBook.sourceMetadata),
      isNotNull,
      reason: 'orphan recovery 保留本地条目语义',
    );
    expect(p.equals(epubBook.extractDir, localMangaDir.path), isTrue);
    expect(
      File(p.join(localMangaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('local manifest 证明属于已移出书架的在线作品时不复活', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    final Directory localMangaDir = Directory(
      p.join(localComicRoot.path, 'Removed online work'),
    );
    await writeChapter(
      mangaDir: localMangaDir,
      folderName: 'Ch 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await db.insertBookTombstone(
      onlineMangaBookKeyFor(
        runtime: entry.runtime,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        seriesKey: entry.series.key,
      ),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 0);
    expect(report.booksSkipped, 1);
    expect(report.booksSkippedTombstoned, 1);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(
      File(p.join(localMangaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '只跳过登记，不删文件',
    );
  });

  test('local 里与在线行身份相同的重复副本不补建本地条目', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final Directory downloadsCopy = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory localCopy = Directory(
      p.join(localComicRoot.path, 'Local duplicate'),
    );
    await insertOnlineBook(
      bookKey: bookKey,
      entry: entry,
      extractDir: downloadsCopy.path,
    );
    await writeChapter(
      mangaDir: downloadsCopy,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 1),
    );
    await writeChapter(
      mangaDir: localCopy,
      folderName: 'Local Ch 1',
      entry: entry,
      chapter: entry.chapters.single,
      downloadedAt: DateTime.utc(2026, 11, 2),
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 1);
    expect(report.booksAdded, 0);
    expect(
      await db.getAllEpubBooks(),
      hasLength(1),
      reason: '同一在线身份已被行覆盖时，local 重复副本不得补建本地条目',
    );
    expect(
      File(p.join(localCopy.path, 'Local Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('共享目录里多个作品身份：Rebuild 各建条目并只映射自己的章', () async {
    final OnlineMangaLibraryEntry first = entryFor(
      seriesKey: '/series/first',
      title: 'Shared title',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final OnlineMangaLibraryEntry second = entryFor(
      seriesKey: '/series/second',
      title: 'Shared title',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    await installSource(
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Shared title'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'A first',
      entry: first,
      chapter: first.chapters.single,
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'B second',
      entry: second,
      chapter: second.chapters.single,
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksAdded, 2, reason: '共享目录里的每个作品身份各建一条');
    expect(report.booksAddedOnline, 2);
    expect(report.booksSkipped, 0, reason: '共享目录不再整目录跳过');
    expect(report.chaptersAdded, 2);
    expect(await db.getAllEpubBooks(), hasLength(2));

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    for (final EpubBookRow row in rows) {
      expect(
        p.equals(row.extractDir, mangaDir.path),
        isTrue,
        reason: '两部作品都指向同一个共享目录',
      );
    }
    final EpubBookRow firstRow = rows.firstWhere((EpubBookRow row) {
      final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      )!;
      return entry.series.key == '/series/first';
    });
    final EpubBookRow secondRow = rows.firstWhere((EpubBookRow row) {
      final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
        row.sourceMetadata,
      )!;
      return entry.series.key == '/series/second';
    });
    expect(
      (await db.getMangaChapterDirRowsForBook(
        firstRow.bookKey,
      )).values.single.folderName,
      'A first',
    );
    expect(
      (await db.getMangaChapterDirRowsForBook(
        secondRow.bookKey,
      )).values.single.folderName,
      'B second',
    );
    expect(await db.getMangaChapterDir(firstRow.bookKey, '/c/1'), isNotNull);
    expect(await db.getMangaChapterDir(secondRow.bookKey, '/c/1'), isNotNull);
    expect(
      File(p.join(mangaDir.path, 'A first', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(mangaDir.path, 'B second', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('共享目录里无 manifest 的容器不按名称认领；删除 A 不动它', () async {
    const List<OnlineMangaChapter> sharedChapters = <OnlineMangaChapter>[
      OnlineMangaChapter(
        key: '/c/1',
        name: 'Chapter 1',
        raw: <String, Object?>{},
      ),
      OnlineMangaChapter(
        key: '/c/2',
        name: 'Chapter 2',
        raw: <String, Object?>{},
      ),
    ];
    final OnlineMangaLibraryEntry first = entryFor(
      seriesKey: '/series/first',
      title: 'Shared title',
      chapters: sharedChapters,
    );
    final OnlineMangaLibraryEntry second = entryFor(
      seriesKey: '/series/second',
      title: 'Shared title',
      chapters: sharedChapters,
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Shared title'),
    );
    final EpubBookRow firstRow = await insertOnlineBook(
      bookKey: onlineMangaBookKeyFor(
        runtime: first.runtime,
        extensionPackage: first.extensionPackage,
        sourceId: first.sourceId,
        seriesKey: first.series.key,
      ),
      entry: first,
      extractDir: mangaDir.path,
    );
    final EpubBookRow secondRow = await insertOnlineBook(
      bookKey: onlineMangaBookKeyFor(
        runtime: second.runtime,
        extensionPackage: second.extensionPackage,
        sourceId: second.sourceId,
        seriesKey: second.series.key,
      ),
      entry: second,
      extractDir: mangaDir.path,
    );
    // 两部作品各自用 pages.json 证明 /c/1 的容器。
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'A first',
      entry: first,
      chapter: sharedChapters.first,
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'B second',
      entry: second,
      chapter: sharedChapters.first,
    );
    // 用户放进共享目录的 /c/2：没有 pages.json，名字对两部作品都成立。
    final Directory ambiguous = downloadChapterDirectory(
      mangaDir.path,
      'Chapter 2',
    );
    await ambiguous.create(recursive: true);
    await File(p.join(ambiguous.path, '001.jpg')).writeAsString('user page');

    await service().run();

    expect(
      (await db.getMangaChapterDirRowsForBook(firstRow.bookKey)).keys,
      <String>{'/c/1'},
      reason: '共享目录里无身份的容器归属不明，不猜给 A',
    );
    expect(
      (await db.getMangaChapterDirRowsForBook(secondRow.bookKey)).keys,
      <String>{'/c/1'},
      reason: '共享目录里无身份的容器归属不明，不猜给 B',
    );

    await DownloadLibraryIndex(
      db,
    ).deleteChapter(bookKey: firstRow.bookKey, chapterKey: '/c/2');

    expect(
      File(p.join(ambiguous.path, '001.jpg')).existsSync(),
      isTrue,
      reason: '删除 A 不得删掉 B 可能引用的无 manifest 容器',
    );
    expect(
      File(p.join(mangaDir.path, 'B second', '001.jpg')).existsSync(),
      isTrue,
      reason: 'B 自己的容器也不受影响',
    );
  });

  test('共享目录中已有两部作品条目：Rebuild 分别重链各自的章', () async {
    final OnlineMangaLibraryEntry first = entryFor(
      seriesKey: '/series/first',
      title: 'Shared title',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final OnlineMangaLibraryEntry second = entryFor(
      seriesKey: '/series/second',
      title: 'Shared title',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: '/c/1',
          name: 'Chapter 1',
          raw: <String, Object?>{},
        ),
      ],
    );
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Shared title'),
    );
    final EpubBookRow firstRow = await insertOnlineBook(
      bookKey: onlineMangaBookKeyFor(
        runtime: first.runtime,
        extensionPackage: first.extensionPackage,
        sourceId: first.sourceId,
        seriesKey: first.series.key,
      ),
      entry: first,
      extractDir: mangaDir.path,
    );
    final EpubBookRow secondRow = await insertOnlineBook(
      bookKey: onlineMangaBookKeyFor(
        runtime: second.runtime,
        extensionPackage: second.extensionPackage,
        sourceId: second.sourceId,
        seriesKey: second.series.key,
      ),
      entry: second,
      extractDir: mangaDir.path,
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'A first',
      entry: first,
      chapter: first.chapters.single,
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'B second',
      entry: second,
      chapter: second.chapters.single,
    );

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMatched, 2);
    expect(report.booksMissing, 0);
    expect(
      (await db.getMangaChapterDirRowsForBook(
        firstRow.bookKey,
      )).values.single.folderName,
      'A first',
    );
    expect(
      (await db.getMangaChapterDirRowsForBook(
        secondRow.bookKey,
      )).values.single.folderName,
      'B second',
    );
    expect(
      (await db.getMangaChapterDirRowsForBook(firstRow.bookKey)).keys,
      <String>{'/c/1'},
    );
    expect(
      (await db.getMangaChapterDirRowsForBook(secondRow.bookKey)).keys,
      <String>{'/c/1'},
    );
  });
}
