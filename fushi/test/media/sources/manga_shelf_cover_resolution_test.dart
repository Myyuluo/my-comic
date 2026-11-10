import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// Ticket 07：书架封面的持久字节缓存解析链。
///
/// seam 是书架数据管线（[ReaderFushiSource.getBooksFromDb]）：真实 Drift 数据库
/// + 临时目录 + 可控的运行时适配器，断言用户可见的 `MediaItem.imageUrl` 与磁盘
/// 上的缓存文件，不触碰私有方法。
class _FakeAdapter
    implements OnlineMangaRuntimeAdapter, OnlineMangaSourceAvailability {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// 来源是否已安装且启用。false = 缺失来源，书架不得发起运行时抓取。
  bool sourceAvailable = true;

  final List<String> fetchedCoverUrls = <String>[];

  /// 非空时替换默认的成功返回，用于失败 / headers-cookie 场景。
  Future<List<int>> Function(String url)? fetchCoverBytes;

  @override
  Future<bool> isSourceAvailable(OnlineMangaLibraryEntry entry) async =>
      sourceAvailable;

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    fetchedCoverUrls.add(url);
    final Future<List<int>> Function(String url)? script = fetchCoverBytes;
    if (script != null) return script(url);
    return _pngBytes;
  }

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) =>
      throw StateError('the shelf must not refresh metadata');

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the shelf must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the shelf must not fetch pages');
}

/// 一个最小可用的 PNG 头部 + IEND 尾，代表扩展网络栈返回的字节。
///
/// 持久缓存经 `MediaCoverService.applyCoverBytes` 落盘，写侧统一校验
/// 「完整可解码图片」（PNG 必须以 IEND chunk 收尾）；夹具必须过同一道门。
const List<int> _pngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x01,
  0x02,
  0x03,
  0x49, // I
  0x45, // E
  0x4E, // N
  0x44, // D
  0xAE,
  0x42,
  0x60,
  0x82,
];

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library) : super(testPlatformServices());

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory cacheDir;
  late Directory downloadsDir;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late _TestAppModel appModel;
  late MangaShelfCoverCache cache;

  setUp(() async {
    ReaderFushiSource.debugResetCoverCache();
    root = await Directory.systemTemp.createTemp('manga_shelf_cover_');
    cacheDir = Directory(
      p.join(root.path, 'userdata', 'cache', 'shelf_covers'),
    );
    downloadsDir = Directory(p.join(root.path, 'downloads'));
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    appModel = _TestAppModel(db, library);
    cache = MangaShelfCoverCache(cacheDir);
    ReaderFushiSource.debugShelfCoverService = MangaShelfCoverService(
      cache: cache,
      serviceFor: (OnlineMangaRuntimeKind _) => library,
    );
  });

  tearDown(() async {
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    ReaderFushiSource.debugShelfCoverService = null;
    ReaderFushiSource.debugResetCoverCache();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<String> insertOnlineBook({
    String bookKey = 'book-1',
    String? coverUrl = 'https://example.test/expired-signature.jpg',
    bool localCover = false,
  }) async {
    final Directory extractDir = Directory(p.join(root.path, 'books', bookKey))
      ..createSync(recursive: true);
    if (localCover) {
      File(p.join(extractDir.path, 'cover.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    }
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'com.example.ext',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/$bookKey',
        title: 'Series',
        coverUrl: coverUrl,
        raw: const <String, Object?>{},
      ),
      chapters: const <OnlineMangaChapter>[],
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Series',
        epubPath: p.join(extractDir.path, 'pages.json'),
        extractDir: extractDir.path,
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(entry.encode()),
      ),
    );
    return extractDir.path;
  }

  Future<void> updateCoverUrl(String bookKey, String coverUrl) async {
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    )!;
    await (db.update(
      db.epubBooks,
    )..where((EpubBooks tbl) => tbl.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        sourceMetadata: Value<String?>(
          entry
              .copyWith(
                series: OnlineMangaSeries(
                  key: entry.series.key,
                  title: entry.series.title,
                  coverUrl: coverUrl,
                  raw: entry.series.raw,
                ),
              )
              .encode(),
        ),
      ),
    );
  }

  Future<MediaItem> resolveShelfBook(String bookKey) async {
    final List<MediaItem> items = await ReaderFushiSource.instance
        .getBooksFromDb(appModel: appModel);
    return items.singleWhere(
      (MediaItem item) => item.mediaIdentifier.endsWith(bookKey),
    );
  }

  test('持久封面缓存优先于本地封面文件，签名 URL 过期后书架仍显示', () async {
    final String extractDir = await insertOnlineBook(
      localCover: true,
      coverUrl: 'https://example.test/expired-signature.jpg',
    );
    await cache.store(
      bookKey: 'book-1',
      sourceUrl: 'https://example.test/expired-signature.jpg',
      bytes: _pngBytes,
    );

    final MediaItem item = await resolveShelfBook('book-1');

    expect(item.imageUrl, startsWith('file://'));
    expect(
      Uri.parse(item.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
      reason: '书架必须先命中按 bookKey 的持久封面缓存，而不是本地封面文件',
    );
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _pngBytes,
      reason: '持久缓存必须保存运行时取回的完整封面字节',
    );
    expect(adapter.fetchedCoverUrls, isEmpty, reason: '缓存已命中且 URL 未变时不应再次请求来源');
    expect(
      downloadsDir.existsSync(),
      isFalse,
      reason: '封面缓存不得创建 Download library 目录',
    );
    expect(
      Directory(extractDir).existsSync(),
      isTrue,
      reason: '本地封面文件仍保留原位，不被缓存删除或搬移',
    );
  });

  test('无持久缓存时经 Extension runtime 取封面字节（headers/cookies 由扩展处理）', () async {
    await insertOnlineBook(coverUrl: 'https://example.test/auth-protected.jpg');

    final MediaItem first = await resolveShelfBook('book-1');
    expect(
      first.imageUrl,
      'https://example.test/auth-protected.jpg',
      reason: '后台取字节完成前，书架先按既有远程 URL 回退',
    );

    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(
      adapter.fetchedCoverUrls,
      <String>['https://example.test/auth-protected.jpg'],
      reason:
          '封面字节必须走适配器（扩展自己的 headers / cookies / 站点鉴权），'
          '不能由应用 HTTP 客户端直连',
    );
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _pngBytes,
      reason: '扩展返回的字节必须原样写入按 bookKey 的持久缓存',
    );

    final MediaItem second = await resolveShelfBook('book-1');
    expect(
      Uri.parse(second.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
      reason: '持久字节落盘后，后续书架解析直接命中本地缓存',
    );
    expect(
      adapter.fetchedCoverUrls,
      hasLength(1),
      reason: '同一 URL 已缓存，不应重复请求来源',
    );
    expect(downloadsDir.existsSync(), isFalse);
  });

  test('获得新签名 URL 后后台刷新失败：保留旧持久缓存，不删除已有封面', () async {
    const String oldUrl = 'https://example.test/old-signature.jpg';
    const String newUrl = 'https://example.test/new-signature.jpg';
    await insertOnlineBook(coverUrl: oldUrl);
    await cache.store(bookKey: 'book-1', sourceUrl: oldUrl, bytes: _pngBytes);
    await updateCoverUrl('book-1', newUrl);
    adapter.fetchCoverBytes = (String url) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'expired signature',
        );

    final MediaItem item = await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(adapter.fetchedCoverUrls, <String>[
      newUrl,
    ], reason: '描述符里出现新封面 URL 后，后台应尝试刷新持久字节');
    expect(
      Uri.parse(item.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
      reason: '刷新失败时书架继续显示旧持久缓存，而不是变空占位',
    );
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _pngBytes,
      reason: '刷新失败不得删除或截断已有封面字节',
    );
    expect(
      await cache.storedSourceUrl('book-1'),
      oldUrl,
      reason: '侧车来源 URL 保持旧值，下次书架重建仍会重试新 URL',
    );

    final MediaItem afterFailure = await resolveShelfBook('book-1');
    expect(
      Uri.parse(afterFailure.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
    );
    expect(downloadsDir.existsSync(), isFalse);
  });

  test('清除缓存后书架回退到远程 URL；没有远程 URL 时回退到占位', () async {
    await insertOnlineBook(
      coverUrl: 'https://example.test/remote-after-clear.jpg',
    );
    await cache.store(
      bookKey: 'book-1',
      sourceUrl: 'https://example.test/remote-after-clear.jpg',
      bytes: _pngBytes,
    );
    await insertOnlineBook(bookKey: 'book-2', coverUrl: null);

    final MediaItem cached = await resolveShelfBook('book-1');
    expect(
      Uri.parse(cached.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
    );
    // 第一次解析触发的后台检查先收尾，避免它的残留请求混进下面的断言。
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    adapter.fetchedCoverUrls.clear();

    await cache.clear();
    expect(await cache.hasCover('book-1'), isFalse);
    // 清空后不再让后台抓取把缓存立刻补回来——断言的是用户清缓存后的回退。
    adapter.sourceAvailable = false;

    final List<MediaItem> items = await ReaderFushiSource.instance
        .getBooksFromDb(appModel: appModel);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    final MediaItem fallback = items.singleWhere(
      (MediaItem item) => item.mediaIdentifier.endsWith('book-1'),
    );
    final MediaItem placeholder = items.singleWhere(
      (MediaItem item) => item.mediaIdentifier.endsWith('book-2'),
    );

    expect(
      fallback.imageUrl,
      'https://example.test/remote-after-clear.jpg',
      reason: '持久缓存清空后，书架回退到已保存的远程封面 URL（现有 HTTP 图片缓存）',
    );
    expect(placeholder.imageUrl, isNull, reason: '既无缓存、无本地封面、也无远程 URL 时交给占位封面');
    expect(adapter.fetchedCoverUrls, isEmpty, reason: '清除缓存本身不应触发来源请求');
  });

  test('来源未安装/未启用时不做运行时抓取；已有持久缓存或本地封面仍显示', () async {
    adapter.sourceAvailable = false;
    const String remote = 'https://example.test/missing-source.jpg';
    await insertOnlineBook(bookKey: 'no-cache', coverUrl: remote);
    await insertOnlineBook(bookKey: 'with-cache', coverUrl: remote);
    await cache.store(
      bookKey: 'with-cache',
      sourceUrl: 'https://example.test/old-before-missing-source.jpg',
      bytes: _pngBytes,
    );
    await updateCoverUrl('with-cache', remote);
    final String localDir = await insertOnlineBook(
      bookKey: 'with-local',
      coverUrl: remote,
      localCover: true,
    );

    final MediaItem noCacheBook = await resolveShelfBook('no-cache');
    final MediaItem cachedBook = await resolveShelfBook('with-cache');
    final MediaItem localBook = await resolveShelfBook('with-local');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(adapter.fetchedCoverUrls, isEmpty, reason: '来源缺失时不得向扩展运行时请求封面字节');
    expect(noCacheBook.imageUrl, remote, reason: '没有持久缓存时书架仍可用已保存的远程 URL 兜底');
    expect(
      await cache.hasCover('no-cache'),
      isFalse,
      reason: '来源缺失时不得凭空产生持久缓存',
    );
    expect(
      Uri.parse(cachedBook.imageUrl!).toFilePath(),
      cache.coverPathFor('with-cache').path,
      reason: '来源缺失不影响已有持久缓存继续显示',
    );
    expect(
      cache.coverPathFor('with-cache').readAsBytesSync(),
      _pngBytes,
      reason: '来源缺失不得删除或改写旧缓存字节',
    );
    expect(
      Uri.parse(localBook.imageUrl!).toFilePath(),
      p.join(localDir, 'cover.jpg'),
      reason: '来源缺失时已有本地封面继续显示',
    );
    expect(downloadsDir.existsSync(), isFalse);
  });

  test('封面缓存按条数上限淘汰最旧条目，对应侧车一起清理', () async {
    final Directory boundedDir = Directory(p.join(root.path, 'bounded_cache'));
    final MangaShelfCoverCache unbounded = MangaShelfCoverCache(
      boundedDir,
      maxEntries: 10,
    );
    for (final String key in <String>['oldest', 'middle', 'newest']) {
      await unbounded.store(
        bookKey: key,
        sourceUrl: 'https://example.test/$key.jpg',
        bytes: _pngBytes,
      );
    }
    final MangaShelfCoverCache bounded = MangaShelfCoverCache(
      boundedDir,
      maxEntries: 2,
    );
    // 写盘顺序在部分文件系统上时间戳相同；显式定序，让淘汰结果可断言。
    await bounded.coverPathFor('oldest').setLastModified(DateTime(2020, 1, 1));
    await bounded.coverPathFor('middle').setLastModified(DateTime(2021, 1, 1));
    await bounded.coverPathFor('newest').setLastModified(DateTime(2022, 1, 1));

    await bounded.trim();

    expect(await bounded.hasCover('oldest'), isFalse);
    expect(await bounded.hasCover('middle'), isTrue);
    expect(await bounded.hasCover('newest'), isTrue);
    expect(await bounded.storedSourceUrl('oldest'), isNull);
    expect(await bounded.storedSourceUrl('middle'), isNotNull);
    expect(downloadsDir.existsSync(), isFalse);
  });
}
