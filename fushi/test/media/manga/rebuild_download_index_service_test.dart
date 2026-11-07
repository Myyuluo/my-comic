import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_download_state.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Ticket 09：Rebuild download index 的 re-link 半场。
///
/// 书架条目是主线：在**当前** Content root 的 `downloads` / `localcomic` 里按
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
    localComicRoot = Directory(p.join(content.path, 'localcomic'));
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
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  MangaPagesManifest manifestFor(
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) => MangaPagesManifest(
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
    downloadedAt: DateTime.utc(2026, 11, 7),
  );

  Future<Directory> writeChapter({
    required Directory mangaDir,
    required String folderName,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
    String pageBytes = 'page',
  }) async {
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir.path,
      folderName,
    );
    await chapterDir.create(recursive: true);
    await File(
      p.join(chapterDir.path, '001.jpg'),
    ).writeAsString(pageBytes);
    await writePagesManifestAtomically(
      chapterDir,
      manifestFor(entry, chapter),
    );
    return chapterDir;
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
      await DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/c/1',
      ),
      isTrue,
      reason: '重建后已下载章节必须能被阅读器定位',
    );
    expect(
      await DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/c/2',
      ),
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
      File(
        p.join(oldMangaDir, 'Chapter 2', '001.jpg'),
      ).existsSync(),
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
    await File(
      p.join(legacyChapter.path, '001.jpg'),
    ).writeAsString('page');
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
      await DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/c/1',
      ),
      isFalse,
      reason: '缺稳定身份的 pages.json 不算完整下载（不能冒充已下载）',
    );
    expect(
      await db.getMangaChapterDir(bookKey, '/c/2'),
      isNull,
    );
  });

  test('同名文件夹与 pages.json 身份同时存在时，稳定 ID 优先于文件夹名', () async {
    const String bookKey = 'mihon-fixture';
    final OnlineMangaLibraryEntry entry = entryFor(
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(key: '/c/1', name: 'Chapter 1', raw: <String, Object?>{}),
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
    final String extractAfterFirst = (await db.getEpubBook(bookKey))!.extractDir;
    final String? mappingAfterFirst =
        (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName;

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
        OnlineMangaChapter(key: '/c/1', name: 'Chapter 1', raw: <String, Object?>{}),
      ],
    );
    final OnlineMangaLibraryEntry secondEntry = entryFor(
      seriesKey: '/series/second',
      title: 'Second series',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(key: '/c/2', name: 'Chapter 2', raw: <String, Object?>{}),
      ],
    );
    await insertOnlineBook(
      bookKey: 'mihon-first',
      entry: firstEntry,
      extractDir: p.join(oldContent.path, 'downloads', 'Example Source', 'First series'),
      importedAt: 2,
    );
    await insertOnlineBook(
      bookKey: 'mihon-second',
      entry: secondEntry,
      extractDir: p.join(oldContent.path, 'downloads', 'Example Source', 'Second series'),
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
    final Directory oldLocalRoot = Directory(
      p.join(oldContent.path, 'localcomic'),
    );
    final File oldPage = File(
      p.join(oldLocalRoot.path, 'Local Manga', 'Ch 1', '001.jpg'),
    )..createSync(recursive: true)
      ..writeAsStringSync('old page');
    await LocalSourceLibrary(db: db, root: oldLocalRoot).importFromRoot();
    final EpubBookRow before = (await db.getAllEpubBooks()).single;

    // 用户把整个作品目录搬到新 Content root 的 localcomic 下。
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
      reason: 'Local source 原地读取，extractDir 必须指向当前 localcomic 根',
    );
    expect(
      LocalSourceMetadata.tryParse(after.sourceMetadata)?.relativePath,
      'Local Manga',
    );
    expect(
      decodeLocalSourceChapters(after.chaptersJson)
          .map((LocalSourceChapterRecord c) => c.key),
      <String>['Ch 1'],
    );
    // 不复制、不删除任何文件。
    expect(oldPage.existsSync(), isTrue);
    expect(newPage.readAsStringSync(), 'new page');
  });

  test('Local source 改名后按文件夹名回退；找不到的作品保留记录并计 Missing', () async {
    final Directory oldLocalRoot = Directory(
      p.join(oldContent.path, 'localcomic'),
    );
    final File oldLocalPage = File(
      p.join(oldLocalRoot.path, 'Old local name', 'Ch 1', '001.jpg'),
    );
    oldLocalPage.parent.createSync(recursive: true);
    oldLocalPage.writeAsStringSync('page');
    await LocalSourceLibrary(db: db, root: oldLocalRoot).importFromRoot();
    final EpubBookRow before = (await db.getAllEpubBooks()).single;
    // 用户在新根里把作品文件夹改了名，并把书架标题也改成了新名字。
    await (db.update(
      db.epubBooks,
    )..where((t) => t.bookKey.equals(before.bookKey))).write(
      const EpubBooksCompanion(title: Value<String>('Renamed local')),
    );
    final File renamedPage = File(
      p.join(localComicRoot.path, 'Renamed local', 'Ch 1', '001.jpg'),
    );
    renamedPage.parent.createSync(recursive: true);
    renamedPage.writeAsStringSync('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksRelinked, 1);
    final EpubBookRow after = (await db.getEpubBook(before.bookKey))!;
    expect(
      p.equals(
        after.extractDir,
        p.join(localComicRoot.path, 'Renamed local'),
      ),
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
    expect(
      retained.extractDir,
      after.extractDir,
      reason: '找不到文件不得删除或改写记录',
    );
    expect(elsewhere.existsSync(), isTrue);
  });

  test('不扫描 autobackup；只增改已有书架条目（不创建新 Library 条目）', () async {
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
    // localcomic 里放一部书架没有的作品——票 10 才负责创建条目。
    final File orphanPage = File(
      p.join(localComicRoot.path, 'Orphan local', 'Ch 1', '001.jpg'),
    );
    orphanPage.parent.createSync(recursive: true);
    orphanPage.writeAsStringSync('page');

    final RebuildDownloadIndexReport report = await service().run();

    expect(report.booksMissing, 1);
    expect(report.chaptersMissing, 2);
    expect(
      (await db.getEpubBook('mihon-fixture'))!.extractDir,
      oldMangaDir,
      reason: 'autobackup 里的文件不是 Download library，不得参与 re-link',
    );
    expect(
      (await db.getAllEpubBooks()).length,
      1,
      reason: '票 09 不创建新 Library 条目（ticket 10 的范围）',
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
  });
}
