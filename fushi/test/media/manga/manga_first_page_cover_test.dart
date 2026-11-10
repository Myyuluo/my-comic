import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_first_page_cover_service.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_revision.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Ticket 02：第一页生成封面的持久化 seam。
///
/// 真实 Drift 数据库 + 真实 CBZ / 文件夹容器 + Program state 缓存目录，断言
/// 用户可见的缓存字节与 sentinel；不触碰 Content root 的 `cover.jpg`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FushiDatabase db;
  late MangaShelfCoverCache cache;
  late MangaFirstPageCoverService service;

  setUp(() async {
    MangaShelfCoverRevision.debugReset();
    root = await Directory.systemTemp.createTemp('manga_first_page_cover_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    cache = MangaShelfCoverCache(
      Directory(p.join(root.path, 'userdata', 'cache', 'shelf_covers')),
    );
    service = MangaFirstPageCoverService(database: db, cache: cache);
  });

  tearDown(() async {
    MangaShelfCoverRevision.debugReset();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  List<int> pngBytes({
    required img.Color color,
    int width = 80,
    int height = 120,
  }) {
    final img.Image image = img.Image(width: width, height: height)
      ..clear(color);
    return img.encodePng(image);
  }

  File writeCbz(String relative, Map<String, List<int>> entries) {
    final Archive archive = Archive();
    entries.forEach((String name, List<int> bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return file;
  }

  void writePage(String relative, {required img.Color color}) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(pngBytes(color: color));
  }

  OnlineMangaLibraryEntry entry({
    required List<OnlineMangaChapter> chapters,
    String? coverUrl,
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: kUnavailableMihonExtensionPackage,
    sourceId: '123',
    series: OnlineMangaSeries(
      key: '/series/1',
      title: 'Manga',
      coverUrl: coverUrl,
      raw: const <String, Object?>{},
    ),
    chapters: chapters,
  );

  Future<EpubBookRow> insertBook({
    required String bookKey,
    required String extractDir,
    required String? sourceMetadata,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Manga',
        epubPath: p.join(extractDir, 'pages.json'),
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(sourceMetadata),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  img.Pixel coverPixel(File cover) =>
      img.decodeJpg(cover.readAsBytesSync())!.getPixel(10, 10);

  test('在线条目 + CBZ 映射：生成字节只写 Program state 缓存，不写 cover.jpg', () async {
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final File cbz = writeCbz(
      p.join('downloads', 'Source', 'Manga', 'Ch 1.cbz'),
      <String, List<int>>{
        'ComicInfo.xml': utf8.encode('<ComicInfo/>'),
        '001.png': pngBytes(
          color: img.ColorRgb8(255, 0, 0),
          width: 900,
          height: 1200,
        ),
      },
    );
    const String bookKey = 'book-cbz';
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{},
          ),
        ],
      ).encode(),
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );
    final int before = MangaShelfCoverRevision.value;

    final String? url = await service.ensureGeneratedCover(row);

    expect(url, isNotNull);
    final File cover = File(Uri.parse(url!).toFilePath());
    expect(cover.path, cache.coverPathFor(bookKey).path);
    final img.Image decoded = img.decodeJpg(cover.readAsBytesSync())!;
    expect(decoded.width, 600);
    expect(decoded.height, 800);
    expect(coverPixel(cover).r, greaterThan(200));
    expect(
      isLocalSourceGeneratedCoverSentinel(await cache.storedSourceUrl(bookKey)),
      isTrue,
      reason: '生成封面 sidecar 必须是本地容器 sentinel',
    );
    expect(
      MangaShelfCoverRevision.value,
      before + 1,
      reason: '生成成功后必须 bump ticket 01 的 revision，书架立即刷新',
    );
    expect(
      File(p.join(extractDir, 'cover.jpg')).existsSync(),
      isFalse,
      reason: '生成封面不得写 Content root / Download library',
    );
    expect(cbz.existsSync(), isTrue, reason: '不得移动或解压原 CBZ');
  });

  test('文件夹章节：自然排序第一张图片，容器变化后重新生成', () async {
    writePage(
      'downloads/Source/Manga/Ch 1/10.png',
      color: img.ColorRgb8(0, 0, 255),
    );
    writePage(
      'downloads/Source/Manga/Ch 1/2.png',
      color: img.ColorRgb8(255, 0, 0),
    );
    const String bookKey = 'book-folder';
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{},
          ),
        ],
      ).encode(),
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Ch 1',
      updatedAt: 1,
    );

    final String? firstUrl = await service.ensureGeneratedCover(row);
    final File cover = File(Uri.parse(firstUrl!).toFilePath());
    expect(coverPixel(cover).r, greaterThan(200), reason: '自然序 2.png 是红色');
    final String firstSentinel = (await cache.storedSourceUrl(bookKey))!;
    final int firstRevision = MangaShelfCoverRevision.value;

    // 容器未变：再次解析只读页表与 stat，不重新编码、不 bump revision。
    expect(await service.ensureGeneratedCover(row), firstUrl);
    expect(MangaShelfCoverRevision.value, firstRevision);

    await Future<void>.delayed(const Duration(seconds: 1));
    writePage(
      'downloads/Source/Manga/Ch 1/2.png',
      color: img.ColorRgb8(0, 0, 255),
    );

    final String? secondUrl = await service.ensureGeneratedCover(row);

    expect(secondUrl, firstUrl);
    expect(coverPixel(cover).b, greaterThan(200), reason: '容器更新后必须重新生成');
    expect(await cache.storedSourceUrl(bookKey), isNot(firstSentinel));
    expect(MangaShelfCoverRevision.value, firstRevision + 1);
  });

  test('规范阅读顺序下第一个完整容器：跳过未下载章，按 reading order 取封面', () async {
    writePage(
      'downloads/Source/Manga/Ch 2/001.png',
      color: img.ColorRgb8(0, 0, 255),
    );
    writePage(
      'downloads/Source/Manga/Ch 1/001.png',
      color: img.ColorRgb8(255, 0, 0),
    );
    const String bookKey = 'book-order';
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/2',
            name: 'Chapter 2',
            number: 2,
            raw: <String, Object?>{},
          ),
          OnlineMangaChapter(
            key: '/chapter/1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{},
          ),
        ],
      ).encode(),
    );
    // Chapter 2 已下载；Chapter 1（阅读顺序第一）也有映射，应优先 Chapter 1。
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/2',
      folderName: 'Ch 2',
      updatedAt: 1,
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Ch 1',
      updatedAt: 2,
    );

    final String? url = await service.ensureGeneratedCover(row);

    expect(coverPixel(File(Uri.parse(url!).toFilePath())).r, greaterThan(200));
  });

  test('无映射时回退扫描漫画目录，仍从第一个完整容器生成', () async {
    writeCbz('downloads/Source/Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    const String bookKey = 'book-unmapped';
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(chapters: const <OnlineMangaChapter>[]).encode(),
    );

    final String? url = await service.ensureGeneratedCover(row);

    expect(url, isNotNull);
    expect(coverPixel(File(Uri.parse(url!).toFilePath())).r, greaterThan(200));
  });

  test('Local source 条目：扫描作品目录第一个章节的第一页', () async {
    writePage('local/Manga/Ch 1/001.png', color: img.ColorRgb8(255, 0, 0));
    const String bookKey = 'local-book';
    final String extractDir = p.join(root.path, 'local', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: const LocalSourceMetadata(relativePath: 'Manga').encode(),
    );

    final String? url = await service.ensureGeneratedCover(row);

    expect(url, isNotNull);
    expect(coverPixel(File(Uri.parse(url!).toFilePath())).r, greaterThan(200));
    expect(File(p.join(extractDir, 'cover.jpg')).existsSync(), isFalse);
  });

  test('第一页损坏 / 容器不完整：保留占位、不抛异常、不写缓存', () async {
    final File broken = File(
      p.join(root.path, 'downloads', 'Source', 'Manga', 'Ch 1', '001.jpg'),
    )..createSync(recursive: true);
    broken.writeAsBytesSync(<int>[1, 2, 3]);
    writePage(
      'downloads/Source/Manga/Ch 1/002.png',
      color: img.ColorRgb8(255, 0, 0),
    );
    const String bookKey = 'book-broken';
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{},
          ),
        ],
      ).encode(),
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Ch 1',
      updatedAt: 1,
    );

    expect(await service.ensureGeneratedCover(row), isNull);
    expect(await cache.hasCover(bookKey), isFalse);
    expect(MangaShelfCoverRevision.value, 0);
    expect(File(p.join(extractDir, 'cover.jpg')).existsSync(), isFalse);
  });

  test('真实来源封面写入缓存后优先于生成封面，sentinels 互相区分', () async {
    writePage(
      'downloads/Source/Manga/Ch 1/001.png',
      color: img.ColorRgb8(255, 0, 0),
    );
    const String bookKey = 'book-real';
    final String extractDir = p.join(root.path, 'downloads', 'Source', 'Manga');
    final EpubBookRow row = await insertBook(
      bookKey: bookKey,
      extractDir: extractDir,
      sourceMetadata: entry(
        chapters: const <OnlineMangaChapter>[
          OnlineMangaChapter(
            key: '/chapter/1',
            name: 'Chapter 1',
            number: 1,
            raw: <String, Object?>{},
          ),
        ],
      ).encode(),
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Ch 1',
      updatedAt: 1,
    );
    await service.ensureGeneratedCover(row);
    expect(await service.cachedGeneratedCoverUrl(bookKey), isNotNull);
    expect(await service.cachedRealCoverUrl(bookKey), isNull);

    await cache.store(
      bookKey: bookKey,
      sourceUrl: 'https://example.test/real.jpg',
      bytes: pngBytes(color: img.ColorRgb8(0, 255, 0)),
    );

    expect(await service.cachedGeneratedCoverUrl(bookKey), isNull);
    expect(await service.cachedRealCoverUrl(bookKey), isNotNull);
  });
}
