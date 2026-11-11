import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/scan_downloaded_manga_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Ticket 03：「检索已下载」只扫描当前 Content root 的 `downloads`，把已下载
/// 但未加入书架、且至少有一个完整章节的作品加入书架。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory content;
  late Directory downloadsRoot;
  late Directory localComicRoot;
  late Directory oldContent;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scan_downloaded_');
    content = Directory(p.join(root.path, 'Content'));
    downloadsRoot = Directory(p.join(content.path, 'downloads'));
    localComicRoot = Directory(p.join(content.path, 'local'));
    oldContent = Directory(p.join(root.path, 'OldContent'));
    await downloadsRoot.create(recursive: true);
    await localComicRoot.create(recursive: true);
    await oldContent.create(recursive: true);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
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
    bool complete = true,
  }) async {
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir.path,
      folderName,
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsString('page');
    await writePagesManifestAtomically(chapterDir, manifestFor(entry, chapter));
    if (!complete) {
      File(p.join(chapterDir.path, '001.jpg')).deleteSync();
    }
    return chapterDir;
  }

  Future<void> installSource({
    String extensionPackage = 'org.example.fixture',
    String sourceId = '1',
    bool extensionEnabled = true,
    bool sourceEnabled = true,
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
        enabled: Value<bool>(extensionEnabled),
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
          enabled: Value<bool>(sourceEnabled),
        ),
      ],
    );
    // replace 会保留已有源的设置；显式改启用位才能覆盖同一 Source 的旧状态。
    await db.updateMangaOnlineSourceSettings(
      extensionPackage: extensionPackage,
      sourceId: sourceId,
      enabled: sourceEnabled,
    );
  }

  ScanDownloadedMangaService service() =>
      ScanDownloadedMangaService(database: db, downloadsRoot: downloadsRoot);

  String onlineBookKeyFor(OnlineMangaLibraryEntry entry) =>
      onlineMangaBookKeyFor(
        runtime: entry.runtime,
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        seriesKey: entry.series.key,
      );

  Future<void> writePlainLocalChapter(
    Directory mangaDir,
    String chapterName,
  ) async {
    final Directory chapterDir = Directory(p.join(mangaDir.path, chapterName))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsStringSync('page');
  }

  test('只扫描当前 Content root 的 downloads：完整作品加入在线条目，'
      '半成品与空目录跳过，重复运行幂等', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory completeDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final Directory completeChapter = await writeChapter(
      mangaDir: completeDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeChapter(
      mangaDir: completeDir,
      folderName: 'Chapter 2',
      entry: entry,
      chapter: entry.chapters[1],
      complete: false,
    );
    // 只有半成品的作品：不得加入书架。
    final Directory halfDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Half series'),
    );
    await writeChapter(
      mangaDir: halfDir,
      folderName: 'Chapter 1',
      entry: entryFor(title: 'Half series', seriesKey: '/series/half'),
      chapter: entry.chapters[0],
      complete: false,
    );
    // 空目录：不得加入书架。
    Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Empty series'),
    ).createSync(recursive: true);

    // `local` 与旧 Content root 里的完整作品都不属于本动作的扫描范围。
    final Directory localComplete = Directory(
      p.join(localComicRoot.path, 'Local only'),
    );
    await writePlainLocalChapter(localComplete, 'Ch 1');
    final Directory oldComplete = Directory(
      p.join(oldContent.path, 'downloads', 'Example Source', 'Old series'),
    );
    await writeChapter(
      mangaDir: oldComplete,
      folderName: 'Chapter 1',
      entry: entryFor(title: 'Old series', seriesKey: '/series/old'),
      chapter: entry.chapters[0],
    );

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.foldersScanned, 3);
    expect(report.addedOnline, 1);
    expect(report.addedLocal, 0);
    expect(report.addedLocalSourceMissing, 0);
    expect(report.promoted, 0);
    expect(report.revivedTombstones, 0);
    expect(report.skippedIncomplete, 2, reason: '半成品与空目录各跳过 1 个');
    expect(report.skippedAmbiguous, 0);
    expect(report.failed, 0);
    expect(report.cancelled, isFalse);

    final String bookKey = onlineBookKeyFor(entry);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue);
    expect(p.equals(row.extractDir, completeDir.path), isTrue);
    final OnlineMangaLibraryEntry recovered = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    )!;
    expect(
      recovered.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/c/1'],
      reason: '半成品章节不写入下载索引',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/2'), isNull);
    expect(
      await db.getAllEpubBooks(),
      hasLength(1),
      reason: 'local / 旧 Content root 的作品不得被加入书架',
    );
    expect(
      File(p.join(completeChapter.path, '001.jpg')).existsSync(),
      isTrue,
      reason: '不移动、不复制、不删除文件',
    );
    expect(
      File(p.join(localComplete.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );

    final ScanDownloadedMangaReport second = await service().run();
    expect(second.addedOnline, 0);
    expect(second.addedLocal, 0);
    expect(second.promoted, 0);
    expect(second.revivedTombstones, 0);
    expect(await db.getAllEpubBooks(), hasLength(1));
    expect((await db.getMangaChapterDirRowsForBook(bookKey)).keys, <String>[
      '/c/1',
    ], reason: '重复运行不产生重复映射');
  });

  test('源未安装或没有 pages.json：登记为指向 downloads 的本地条目，'
      '并单列因来源未安装降级的数量', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    // 刻意不安装扩展 / 在线源。
    final Directory manifestDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: manifestDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    final Directory manualDir = Directory(
      p.join(downloadsRoot.path, 'Manual Source', 'Manual manga'),
    );
    await writePlainLocalChapter(manualDir, 'Ch 1');
    await writePlainLocalChapter(manualDir, 'Ch 2');

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.addedOnline, 0);
    expect(report.addedLocal, 2);
    expect(
      report.addedLocalSourceMissing,
      1,
      reason: '只有带 pages.json 的组因源未安装降级',
    );
    expect(report.promoted, 0);
    expect(report.revivedTombstones, 0);
    expect(report.skippedIncomplete, 0);
    expect(await db.getAllEpubBooks(), hasLength(2));

    final EpubBookRow manifestRow = (await db.getEpubBook(
      localSourceBookKeyFor(manifestDir.path),
    ))!;
    expect(manifestRow.isInLibrary, isTrue);
    expect(
      LocalSourceMetadata.tryParse(manifestRow.sourceMetadata)!.relativePath,
      'Example Source/Fixture series',
    );
    expect(p.equals(manifestRow.extractDir, manifestDir.path), isTrue);
    expect(
      decodeLocalSourceChapters(
        manifestRow.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Chapter 1'],
    );

    final EpubBookRow manualRow = (await db.getEpubBook(
      localSourceBookKeyFor(manualDir.path),
    ))!;
    expect(manualRow.isInLibrary, isTrue);
    expect(manualRow.title, 'Manual manga');
    expect(
      decodeLocalSourceChapters(
        manualRow.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Ch 1', 'Ch 2'],
    );
    expect(
      File(p.join(manualDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '文件继续留在 downloads 原地',
    );
  });

  test('扩展或在线源被停用时按「源未安装」降级本地条目并计入报告', () async {
    final List<Directory> mangaDirs = <Directory>[];
    for (final ({String label, bool extensionEnabled, bool sourceEnabled}) flags
        in <({String label, bool extensionEnabled, bool sourceEnabled})>[
          (
            label: 'disabled-extension',
            extensionEnabled: false,
            sourceEnabled: true,
          ),
          (
            label: 'disabled-source',
            extensionEnabled: true,
            sourceEnabled: false,
          ),
        ]) {
      final OnlineMangaLibraryEntry entry = entryFor(
        seriesKey: '/series/${flags.label}',
      );
      await installSource(
        extensionPackage: entry.extensionPackage,
        sourceId: entry.sourceId,
        extensionEnabled: flags.extensionEnabled,
        sourceEnabled: flags.sourceEnabled,
      );
      final Directory mangaDir = Directory(
        p.join(downloadsRoot.path, 'Example Source', flags.label),
      );
      mangaDirs.add(mangaDir);
      await writeChapter(
        mangaDir: mangaDir,
        folderName: 'Chapter 1',
        entry: entry,
        chapter: entry.chapters[0],
      );
    }

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.addedOnline, 0, reason: '停用的源不得建在线条目');
    expect(report.addedLocal, 2);
    expect(report.addedLocalSourceMissing, 2);
    for (final Directory mangaDir in mangaDirs) {
      final EpubBookRow row = (await db.getEpubBook(
        localSourceBookKeyFor(mangaDir.path),
      ))!;
      expect(row.isInLibrary, isTrue);
      expect(OnlineMangaLibraryEntry.tryParse(row.sourceMetadata), isNull);
      expect(LocalSourceMetadata.tryParse(row.sourceMetadata), isNotNull);
    }
  });

  test('已有非书架记录原地提升为书架成员：保留进度、章节与下载映射，不新建行', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final String bookKey = onlineBookKeyFor(entry);
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        epubPath: kDownloadPagesFileName,
        extractDir: mangaDir.path,
        chapterCount: 2,
        chaptersJson: '[{"key":"/c/9"}]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: 42,
        format: const Value<String>('manga'),
        inLibrary: const Value<bool>(false),
        completedAt: Value<DateTime?>(DateTime.utc(2026, 1, 2)),
      ),
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/c/9',
      folderName: 'Old chapter',
      containerKind: MangaChapterContainerKind.folder,
      updatedAt: 1,
    );
    final EpubBookRow before = (await db.getEpubBook(bookKey))!;

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.promoted, 1);
    expect(report.addedOnline, 0);
    expect(report.addedLocal, 0);
    expect(report.revivedTombstones, 0);
    expect(await db.getAllEpubBooks(), hasLength(1), reason: '复用同一条记录');
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(after.isInLibrary, isTrue);
    expect(after.completedAt, before.completedAt);
    expect(after.chaptersJson, before.chaptersJson);
    expect(after.sourceMetadata, before.sourceMetadata);
    expect(after.extractDir, before.extractDir);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/9'))?.folderName,
      'Old chapter',
      reason: '提升不重链下载映射',
    );
    expect(
      await db.getMangaChapterDir(bookKey, '/c/1'),
      isNull,
      reason: '提升只写 membership；重链仍属于重建的职责',
    );
  });

  test('已在书架的作品跳过：不改写记录、不重链下载映射', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final String bookKey = onlineBookKeyFor(entry);
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: mangaDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    final String recordedDir = p.join(
      oldContent.path,
      'downloads',
      'Example Source',
      'Fixture series',
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        epubPath: kDownloadPagesFileName,
        extractDir: recordedDir,
        chapterCount: 2,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.addedOnline, 0);
    expect(report.promoted, 0);
    expect(report.revivedTombstones, 0);
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue);
    expect(row.extractDir, recordedDir);
    expect(await db.getMangaChapterDir(bookKey, '/c/1'), isNull);
  });

  test('用户显式执行时复活 tombstone 作品并清除墓碑', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final String onlineBookKey = onlineBookKeyFor(entry);
    final Directory onlineDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: onlineDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await db.insertBookTombstone(onlineBookKey);

    final Directory manualDir = Directory(
      p.join(downloadsRoot.path, 'Manual Source', 'Manual manga'),
    );
    await writePlainLocalChapter(manualDir, 'Ch 1');
    final String localBookKey = localSourceBookKeyFor(manualDir.path);
    await db.insertBookTombstone(localBookKey);
    expect(await db.getBookTombstoneKeys(), hasLength(2));

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.revivedTombstones, 2);
    expect(report.addedOnline, 1);
    expect(report.addedLocal, 1);
    expect(await db.getBookTombstoneKeys(), isEmpty, reason: '显式检索清除墓碑');
    expect((await db.getEpubBook(onlineBookKey))!.isInLibrary, isTrue);
    expect((await db.getEpubBook(localBookKey))!.isInLibrary, isTrue);
    expect(
      File(p.join(onlineDir.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('同身份多个完整副本：跳过并报告歧义，不猜、不改库', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final Directory firstDir = Directory(
      p.join(downloadsRoot.path, 'Source A', 'Fixture series'),
    );
    final Directory secondDir = Directory(
      p.join(downloadsRoot.path, 'Source B', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: firstDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    await writeChapter(
      mangaDir: secondDir,
      folderName: 'Chapter 1 copy',
      entry: entry,
      chapter: entry.chapters[0],
    );

    final ScanDownloadedMangaReport report = await service().run();

    expect(report.skippedAmbiguous, 1);
    expect(report.addedOnline, 0);
    expect(report.addedLocal, 0);
    expect(await db.getAllEpubBooks(), isEmpty, reason: '歧义时不猜归属');
    expect(
      await db.getMangaChapterDirRowsForBook(onlineBookKeyFor(entry)),
      isEmpty,
    );
    expect(
      File(p.join(firstDir.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(secondDir.path, 'Chapter 1 copy', '001.jpg')).existsSync(),
      isTrue,
    );
  });

  test('取消后保留已完成的部分并标记 cancelled', () async {
    final OnlineMangaLibraryEntry first = entryFor();
    final OnlineMangaLibraryEntry second = entryFor(
      seriesKey: '/series/second',
      title: 'Second series',
    );
    await installSource(
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
    );
    await writeChapter(
      mangaDir: Directory(
        p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
      ),
      folderName: 'Chapter 1',
      entry: first,
      chapter: first.chapters[0],
    );
    await writeChapter(
      mangaDir: Directory(
        p.join(downloadsRoot.path, 'Example Source', 'Second series'),
      ),
      folderName: 'Chapter 1',
      entry: second,
      chapter: second.chapters[0],
    );
    final ScanDownloadedMangaCancelToken token =
        ScanDownloadedMangaCancelToken();

    final ScanDownloadedMangaReport report = await service().run(
      cancelToken: token,
      onProgress: (ScanDownloadedMangaProgress progress) {
        if (progress.completed == 1) token.cancel();
      },
    );

    expect(report.cancelled, isTrue);
    expect(report.addedOnline, 1, reason: '取消前完成的目录保留');
    expect(await db.getAllEpubBooks(), hasLength(1));
    expect(
      await db.getEpubBook(onlineBookKeyFor(second)),
      isNull,
      reason: '取消后不再处理剩余目录',
    );
  });
}
