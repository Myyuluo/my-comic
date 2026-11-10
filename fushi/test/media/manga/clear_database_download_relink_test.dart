import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// Ticket 05 的服务层证据：清除数据库只删记录，重新打开同一作品时按磁盘
/// `pages.json` 身份（或容器名）自动恢复 `extractDir` 与章节映射，不需要用户
/// 手动运行「重建下载索引」；批量删除走的身份回退不碰 `local` 原件。
void main() {
  late Directory root;
  late FushiDatabase db;
  late _FixtureAdapter adapter;
  late OnlineMangaLibraryService library;

  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: '/chapter/2',
      name: 'Chapter 2',
      number: 2,
      raw: <String, Object?>{'url': '/chapter/2'},
    ),
    OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    ),
  ];

  OnlineMangaLibraryEntry entryWith(List<OnlineMangaChapter> items) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: const OnlineMangaSeries(
          key: '/series/fixture',
          title: 'Fixture series',
          raw: <String, Object?>{'url': '/series/fixture'},
        ),
        chapters: items,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('manga_clear_relink_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FixtureAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 在漫画目录里写一章：`pages.json` 可选（无 manifest = 只靠容器名回退）。
  Future<Directory> writeChapter(
    String mangaDir,
    String containerName,
    String chapterKey,
    String chapterName, {
    bool writeManifest = true,
  }) async {
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      containerName,
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    if (writeManifest) {
      await writePagesManifestAtomically(
        chapterDir,
        MangaPagesManifest(
          sourceRuntime: 'mihon',
          sourceId: '1',
          sourceName: 'Fixture',
          extensionPackage: 'org.example.fixture',
          mangaKey: '/series/fixture',
          mangaTitle: 'Fixture series',
          chapterKey: chapterKey,
          chapterName: chapterName,
          payload: const MokuroPayload(
            images: <MokuroImage>[
              MokuroImage(
                url: '001.jpg',
                size: MokuroSize(100, 150),
                blocks: <MokuroBlock>[],
              ),
            ],
          ),
          downloadedAt: DateTime.utc(2026, 11, 10),
        ),
      );
    }
    return chapterDir;
  }

  test('清库只删记录并保留文件；重开同作品自动恢复目录与章节映射', () async {
    final EpubBookRow original = await library.ensureNonLibrary(
      entryWith(chapters),
    );
    // 模拟已下载：两章完整容器 + 数据库映射（清库后这些记录应一并消失）。
    final Directory chapter2 = await writeChapter(
      original.extractDir,
      'Chapter 2',
      '/chapter/2',
      'Chapter 2',
    );
    final Directory chapter1 = await writeChapter(
      original.extractDir,
      'Chapter 1',
      '/chapter/1',
      'Chapter 1',
    );
    for (final OnlineMangaChapter chapter in chapters) {
      await db.upsertMangaChapterDir(
        bookKey: original.bookKey,
        chapterKey: chapter.key,
        folderName: chapter.name,
        updatedAt: 1,
      );
    }

    final MangaDatabaseClearService clear = MangaDatabaseClearService(
      database: db,
    );
    final List<MangaDatabaseClearSource> sources = await clear.measureSources();
    expect(sources, hasLength(1));
    final MangaDatabaseClearCounts counts = await clear.run(
      sourceKeys: <String>{sources.single.key},
      keepRead: false,
    );

    expect(counts.works, 1);
    expect(await db.getEpubBook(original.bookKey), isNull, reason: '只删记录');
    expect(
      await db.getMangaChapterDir(original.bookKey, '/chapter/1'),
      isNull,
      reason: '章节映射随记录一起清掉',
    );
    expect(File(p.join(chapter1.path, '001.jpg')).existsSync(), isTrue);
    expect(File(p.join(chapter2.path, '001.jpg')).existsSync(), isTrue);
    expect(Directory(original.extractDir).existsSync(), isTrue);

    // 源网格 seed 通常只有标题没有章节；重开时靠磁盘 pages.json 找回目录。
    final OnlineMangaLibraryEntry seed = entryWith(
      const <OnlineMangaChapter>[],
    );
    final EpubBookRow reopened = await library.ensureNonLibrary(seed);
    expect(reopened.isInLibrary, isFalse);
    expect(
      reopened.extractDir,
      original.extractDir,
      reason: '按 pages.json 身份恢复 extractDir，不生成 (2)',
    );
    expect(
      Directory(
        p.join(p.dirname(original.extractDir), 'Fixture series (2)'),
      ).existsSync(),
      isFalse,
    );

    // 详情页拉回章节表后自动重链，映射立即可用（无需手动重建索引）。
    adapter.fetchedChapters = chapters;
    final OnlineMangaLibraryEntry refreshed = await library.refreshFromSource(
      bookKey: reopened.bookKey,
      entry: seed,
    );
    expect(refreshed.chapters, hasLength(2));
    expect(
      (await db.getMangaChapterDir(reopened.bookKey, '/chapter/1'))?.folderName,
      'Chapter 1',
    );
    expect(
      (await db.getMangaChapterDir(reopened.bookKey, '/chapter/2'))?.folderName,
      'Chapter 2',
    );

    final DownloadLibraryIndex index = DownloadLibraryIndex(
      db,
      downloadsRoot: Directory(p.join(root.path, 'downloads')),
    );
    expect(
      await index.downloadedChapterKeys(reopened.bookKey, <String>[
        '/chapter/1',
        '/chapter/2',
      ]),
      <String>{'/chapter/1', '/chapter/2'},
      reason: '重开后章节列表应显示已下载',
    );
    expect(File(p.join(chapter1.path, '001.jpg')).existsSync(), isTrue);
    expect(File(p.join(chapter2.path, '001.jpg')).existsSync(), isTrue);
  });

  test('根 manifest 单章作品旁有 saved/ 子目录：清库重开仍复用原目录，不建 (2)', () async {
    final EpubBookRow original = await library.ensureNonLibrary(
      entryWith(chapters),
    );
    final Directory mangaDir = Directory(original.extractDir)
      ..createSync(recursive: true);
    // 单章作品：pages.json + 页图在漫画目录根。
    await File(p.join(mangaDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(
      mangaDir,
      MangaPagesManifest(
        sourceRuntime: 'mihon',
        sourceId: '1',
        sourceName: 'Fixture',
        extensionPackage: 'org.example.fixture',
        mangaKey: '/series/fixture',
        mangaTitle: 'Fixture series',
        chapterKey: '/chapter/1',
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
        downloadedAt: DateTime.utc(2026, 11, 10),
      ),
    );
    // 阅读器「保存页面」会在漫画目录根写 saved/：它没有章节身份，不能把根
    // manifest 挡在扫描之外。
    final Directory saved = Directory(p.join(mangaDir.path, 'saved'))
      ..createSync(recursive: true);
    File(p.join(saved.path, 'page.jpg')).writeAsBytesSync(<int>[9]);
    await db.deleteEpubBook(original.bookKey);

    final OnlineMangaLibraryEntry seed = entryWith(
      const <OnlineMangaChapter>[],
    );
    final EpubBookRow reopened = await library.ensureNonLibrary(seed);

    expect(
      reopened.extractDir,
      original.extractDir,
      reason: '根 manifest 身份仍能证明目录属于这部作品',
    );
    expect(
      Directory(
        p.join(p.dirname(original.extractDir), 'Fixture series (2)'),
      ).existsSync(),
      isFalse,
      reason: 'saved/ 子目录不能导致另建 (2) 目录',
    );
    expect(
      File(p.join(mangaDir.path, 'pages.json')).existsSync(),
      isTrue,
      reason: '用户目录与单章下载负载原样保留',
    );
  });

  test('重链同时按容器名回退：没有 pages.json 的容器也写映射', () async {
    final EpubBookRow original = await library.ensureNonLibrary(
      entryWith(chapters),
    );
    await writeChapter(
      original.extractDir,
      'Chapter 1',
      '/chapter/1',
      'Chapter 1',
    );
    // 容器名能对上章节、但没有 pages.json 可证明身份。
    final Directory byName = await writeChapter(
      original.extractDir,
      'Chapter 2',
      '/chapter/2',
      'Chapter 2',
      writeManifest: false,
    );
    await db.deleteEpubBook(original.bookKey);

    final OnlineMangaLibraryEntry seed = entryWith(
      const <OnlineMangaChapter>[],
    );
    final EpubBookRow reopened = await library.ensureNonLibrary(seed);
    adapter.fetchedChapters = chapters;
    await library.refreshFromSource(bookKey: reopened.bookKey, entry: seed);

    final MangaChapterDirRow? mapped = await db.getMangaChapterDir(
      reopened.bookKey,
      '/chapter/2',
    );
    expect(mapped?.folderName, 'Chapter 2', reason: 'pages.json 缺失时按容器名恢复映射');
    expect(File(p.join(byName.path, '001.jpg')).existsSync(), isTrue);
  });

  test('清库重开后单章删除行为不变：只删目标章与其他作品的容器', () async {
    final EpubBookRow original = await library.ensureNonLibrary(
      entryWith(chapters),
    );
    final Directory chapter2 = await writeChapter(
      original.extractDir,
      'Chapter 2',
      '/chapter/2',
      'Chapter 2',
    );
    final Directory chapter1 = await writeChapter(
      original.extractDir,
      'Chapter 1',
      '/chapter/1',
      'Chapter 1',
    );
    await db.deleteEpubBook(original.bookKey);

    final OnlineMangaLibraryEntry seed = entryWith(
      const <OnlineMangaChapter>[],
    );
    final EpubBookRow reopened = await library.ensureNonLibrary(seed);
    adapter.fetchedChapters = chapters;
    await library.refreshFromSource(bookKey: reopened.bookKey, entry: seed);
    final EpubBookRow row = (await db.getEpubBook(reopened.bookKey))!;

    final DownloadLibraryIndex index = DownloadLibraryIndex(
      db,
      downloadsRoot: Directory(p.join(root.path, 'downloads')),
    );
    await index.deleteChapterForEntry(
      entry: entryWith(chapters),
      chapterKey: '/chapter/1',
      row: row,
    );

    expect(chapter1.existsSync(), isFalse, reason: '单章删除仍按映射删目标章');
    expect(chapter2.existsSync(), isTrue, reason: '其他章不动');
    expect(await db.getMangaChapterDir(row.bookKey, '/chapter/1'), isNull);
    expect(
      (await db.getMangaChapterDir(row.bookKey, '/chapter/2'))?.folderName,
      'Chapter 2',
    );
    expect(
      Directory(row.extractDir).existsSync(),
      isTrue,
      reason: '还有其他章时保留漫画目录',
    );
  });

  test('批量删除的身份回退只作用于 downloads，local 原件不动', () async {
    final EpubBookRow original = await library.ensureNonLibrary(
      entryWith(chapters),
    );
    final Directory downloaded = await writeChapter(
      original.extractDir,
      'Chapter 1',
      '/chapter/1',
      'Chapter 1',
    );
    // 同一身份在 local 根下的用户原件（同名目录 + pages.json）。
    final Directory localRoot = Directory(p.join(root.path, 'local'));
    final Directory localOriginal = await writeChapter(
      localRoot.path,
      'Chapter 1',
      '/chapter/1',
      'Chapter 1',
    );
    await db.deleteEpubBook(original.bookKey);

    final DownloadLibraryIndex index = DownloadLibraryIndex(
      db,
      downloadsRoot: Directory(p.join(root.path, 'downloads')),
      localComicRoot: localRoot,
    );
    await index.deleteChapterForEntry(
      entry: entryWith(chapters),
      chapterKey: '/chapter/1',
      row: null,
    );

    expect(downloaded.existsSync(), isFalse, reason: '删掉 downloads 管理的容器');
    expect(localOriginal.existsSync(), isTrue, reason: 'local 根下的用户原件永不删除');
    expect(File(p.join(localOriginal.path, '001.jpg')).existsSync(), isTrue);
  });
}

class _FixtureAdapter implements OnlineMangaRuntimeAdapter {
  /// 详情页 / 刷新时从「来源」拉回的章节表。
  List<OnlineMangaChapter> fetchedChapters = const <OnlineMangaChapter>[];

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fixture';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async => OnlineMangaRefreshResult(
    series: entry.series,
    chapters: fetchedChapters.isEmpty ? entry.chapters : fetchedChapters,
  );

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the test must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the test must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}
