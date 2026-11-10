import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/download_library_scanner.dart';
import 'package:fushi/src/media/manga/download/download_manga_recovery.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 「检索已下载」（票 03）要复用的发现 / 恢复辅助模块。
///
/// 行为与 Rebuild 曾经的内联 orphan recovery 完全一致：按 `pages.json` 身份建
/// 在线条目、源未安装 / 无 manifest 时登记为指向 `downloads` 目录的本地条目；
/// 只收完整章节，尊重 tombstone 与已有 Manga 行；不移动 / 复制 / 删除文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory downloadsRoot;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download_manga_recovery_');
    downloadsRoot = Directory(p.join(root.path, 'downloads'))
      ..createSync(recursive: true);
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

  Future<File> writeArchiveChapter({
    required Directory mangaDir,
    required String fileName,
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
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

  /// 模拟票 03 的调用方式：扫描 `downloads`，逐个目录恢复。
  Future<DownloadMangaRecoveryOutcome> recoverAll({
    Set<String> tombstones = const <String>{},
  }) async {
    final DownloadMangaInstalledSources installed =
        await DownloadMangaInstalledSources.load(db);
    final Set<String> existingBookKeys = <String>{
      for (final EpubBookRow row in await db.getAllEpubBooks()) row.bookKey,
    };
    final DownloadMangaRecovery recovery = DownloadMangaRecovery(
      database: db,
      downloadsRoot: downloadsRoot,
    );
    DownloadMangaRecoveryOutcome total = const DownloadMangaRecoveryOutcome();
    for (final DownloadMangaFolderOnDisk folder
        in await scanDownloadLibraryFolders(
          downloadsRoot,
          readComplete: true,
        )) {
      total = total.merge(
        await recovery.recover(
          folder,
          installedSources: installed,
          tombstonedBookKeys: tombstones,
          existingBookKeys: existingBookKeys,
        ),
      );
    }
    return total;
  }

  test('源已安装：按 pages.json 身份建在线条目，只收完整章节，重复运行幂等', () async {
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
      complete: false,
    );

    final DownloadMangaRecoveryOutcome first = await recoverAll();

    expect(first.added, 1);
    expect(first.addedOnline, 1);
    expect(first.addedLocal, 0);
    expect(first.chaptersAdded, 1, reason: '半成品章节不进下载索引');
    expect(first.chaptersSkipped, 0);
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
    expect(recovered.series.title, entry.series.title);
    expect(
      recovered.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/c/1'],
    );
    expect(p.equals(row.extractDir, mangaDir.path), isTrue);
    expect(
      (await db.getMangaChapterDir(bookKey, '/c/1'))?.folderName,
      'Chapter 1',
    );
    expect(await db.getMangaChapterDir(bookKey, '/c/2'), isNull);

    final DownloadMangaRecoveryOutcome second = await recoverAll();
    expect(second.added, 0, reason: '已存在的身份不再重复建条目');
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('源未安装：降级为指向 downloads 目录的本地条目并报告', () async {
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
    await writeArchiveChapter(
      mangaDir: mangaDir,
      fileName: 'Chapter 2.cbz',
      entry: entry,
      chapter: entry.chapters[1],
    );

    final DownloadMangaRecoveryOutcome outcome = await recoverAll();

    expect(outcome.added, 1);
    expect(outcome.addedOnline, 0);
    expect(outcome.addedLocal, 1);
    expect(outcome.addedLocalSourceMissing, 1);
    expect(outcome.chaptersAdded, 2);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.bookKey, localSourceBookKeyFor(mangaDir.path));
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
      <String>['Chapter 1', 'Chapter 2.cbz'],
    );
    expect(
      File(p.join(mangaDir.path, 'Chapter 2.cbz')).existsSync(),
      isTrue,
      reason: '不移动、不复制、不删除文件',
    );
  });

  test('没有 pages.json 的目录：按图片扫描登记为本地条目', () async {
    final Directory mangaDir = Directory(
      p.join(downloadsRoot.path, 'Manual Source', 'Manual manga'),
    );
    for (final String chapter in <String>['Ch 1', 'Ch 2']) {
      final Directory chapterDir = Directory(p.join(mangaDir.path, chapter))
        ..createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsStringSync('page-1');
      File(p.join(chapterDir.path, '002.jpg')).writeAsStringSync('page-2');
    }

    final DownloadMangaRecoveryOutcome outcome = await recoverAll();

    expect(outcome.added, 1);
    expect(outcome.addedOnline, 0);
    expect(outcome.addedLocal, 1);
    expect(outcome.addedLocalSourceMissing, 0);
    expect(outcome.chaptersAdded, 2);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.bookKey, localSourceBookKeyFor(mangaDir.path));
    expect(row.title, 'Manual manga');
    expect(
      decodeLocalSourceChapters(
        row.chaptersJson,
      ).map((LocalSourceChapterRecord chapter) => chapter.key),
      <String>['Ch 1', 'Ch 2'],
    );
    expect(
      File(p.join(mangaDir.path, 'Ch 1', '002.jpg')).readAsStringSync(),
      'page-2',
    );
  });

  test('共享目录里多个作品身份：各建条目并只登记自己的章节', () async {
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

    final DownloadMangaRecoveryOutcome outcome = await recoverAll();

    expect(outcome.added, 2, reason: '共享目录里的每个身份各建一条');
    expect(outcome.addedOnline, 2);
    expect(outcome.skipped, 0);
    expect(outcome.chaptersAdded, 2);
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(2));
    final EpubBookRow firstRow = rows.firstWhere((EpubBookRow row) {
      return OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!.series.key ==
          '/series/first';
    });
    final EpubBookRow secondRow = rows.firstWhere((EpubBookRow row) {
      return OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!.series.key ==
          '/series/second';
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
  });

  test('tombstone 与已有 Manga 行：跳过、不复活、不改写', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final String onlineBookKey = onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );
    final Directory tombstonedDir = Directory(
      p.join(downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    await writeChapter(
      mangaDir: tombstonedDir,
      folderName: 'Chapter 1',
      entry: entry,
      chapter: entry.chapters[0],
    );
    // 没有 manifest 的手工目录：按本地身份立碑也要跳过。
    final Directory manualDir = Directory(
      p.join(downloadsRoot.path, 'Manual Source', 'Manual manga'),
    );
    final Directory manualChapter = Directory(p.join(manualDir.path, 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(manualChapter.path, '001.jpg')).writeAsStringSync('page');

    final DownloadMangaRecoveryOutcome outcome = await recoverAll(
      tombstones: <String>{
        onlineBookKey,
        localSourceBookKeyFor(manualDir.path),
      },
    );

    expect(outcome.added, 0);
    expect(outcome.skipped, 2);
    expect(outcome.skippedTombstoned, 2);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(
      File(p.join(tombstonedDir.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '只跳过登记，不删除文件',
    );
    expect(File(p.join(manualChapter.path, '001.jpg')).existsSync(), isTrue);
  });

  test('已有 Manga 行覆盖的身份不重复登记', () async {
    final OnlineMangaLibraryEntry entry = entryFor();
    await installSource(
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
    );
    final String bookKey = onlineMangaBookKeyFor(
      runtime: entry.runtime,
      extensionPackage: entry.extensionPackage,
      sourceId: entry.sourceId,
      seriesKey: entry.series.key,
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        epubPath: kDownloadPagesFileName,
        extractDir: p.join(downloadsRoot.path, 'elsewhere'),
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: 1,
        format: const Value<String>('manga'),
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

    final DownloadMangaRecoveryOutcome outcome = await recoverAll();

    expect(outcome.added, 0);
    expect(outcome.chaptersAdded, 0);
    expect(await db.getAllEpubBooks(), hasLength(1));
    expect(
      (await db.getEpubBook(bookKey))!.extractDir,
      p.join(downloadsRoot.path, 'elsewhere'),
      reason: '已有行走重建索引的重链路径，恢复模块不改写它',
    );
  });
}
