import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/painting.dart'
    show ImageProvider, ImageStreamCompleter, PaintingBinding;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/media/manga/library/manga_first_page_cover_service.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_renewal.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_revision.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:image/image.dart' as img;
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

  /// 详情刷新调用次数。书架默认**不得**刷新元数据；只有封面续签可以。
  int refreshCalls = 0;

  /// 非空时替换默认的「书架不得刷新元数据」异常。
  Future<OnlineMangaRefreshResult> Function(OnlineMangaLibraryEntry entry)?
  refreshScript;

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
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    refreshCalls++;
    final Future<OnlineMangaRefreshResult> Function(OnlineMangaLibraryEntry)?
    script = refreshScript;
    if (script != null) return script(entry);
    throw StateError('the shelf must not refresh metadata');
  }

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

/// 续签后新 URL 返回的字节：另一份可解码图片，用来区分「旧字节原样保留」与
/// 「新字节已落盘」。JPEG 头 + EOI 尾，过写侧同一道完整性校验。
const List<int> _renewedCoverBytes = <int>[
  0xFF,
  0xD8,
  0xFF,
  0xE0,
  0x00,
  0x10,
  0x4A,
  0x46,
  0x49,
  0x46,
  0x00,
  0x01,
  0xFF,
  0xD9,
];

/// 只占用 ImageCache 键、不真正解码的占位 completer。
class _PendingImageCompleter extends ImageStreamCompleter {}

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
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // `AppCachedHttpImage` 构造即起磁盘缓存管理器，需要 path_provider 应答。
  late Directory imageCacheDir;
  setUpAll(() {
    imageCacheDir = Directory.systemTemp.createTempSync(
      'manga_shelf_cover_image_cache_',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => imageCacheDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (imageCacheDir.existsSync()) {
      try {
        imageCacheDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late Directory root;
  late Directory cacheDir;
  late Directory downloadsDir;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late _TestAppModel appModel;
  late MangaShelfCoverCache cache;
  late MangaShelfCoverService service;

  setUp(() async {
    ReaderFushiSource.debugResetCoverCache();
    MangaShelfCoverRevision.debugReset();
    MangaShelfCoverRenewalThrottle.debugReset();
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
    service = MangaShelfCoverService(
      cache: cache,
      serviceFor: (OnlineMangaRuntimeKind _) => library,
    );
    ReaderFushiSource.debugShelfCoverService = service;
  });

  tearDown(() async {
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    ReaderFushiSource.debugShelfCoverService = null;
    ReaderFushiSource.debugResetCoverCache();
    MangaShelfCoverRevision.debugReset();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<String> insertOnlineBook({
    String bookKey = 'book-1',
    String? coverUrl = 'https://example.test/expired-signature.jpg',
    bool localCover = false,
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
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
      chapters: chapters,
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Series',
        epubPath: p.join(extractDir.path, 'pages.json'),
        extractDir: extractDir.path,
        chapterCount: chapters.length,
        chaptersJson: jsonEncode(<Map<String, Object?>>[
          for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
        ]),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(entry.encode()),
      ),
    );
    return extractDir.path;
  }

  File writeCbz(String path, Map<String, List<int>> entries) {
    final Archive archive = Archive();
    entries.forEach((String name, List<int> bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    final File file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return file;
  }

  List<int> pngBytes({required img.Color color}) {
    final img.Image image = img.Image(width: 900, height: 1200)
      ..clear(color);
    return img.encodePng(image);
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

  Future<OnlineMangaLibraryEntry> readEntry(String bookKey) async {
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    return OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
  }

  OnlineMangaSeries seriesWithCover(
    OnlineMangaLibraryEntry entry,
    String coverUrl,
  ) => OnlineMangaSeries(
    key: entry.series.key,
    title: entry.series.title,
    coverUrl: coverUrl,
    raw: entry.series.raw,
  );

  test('旧封面 URL 取字节 403：自动详情续签，新 URL 落库、字节刷新、书架立即显示', () async {
    const String oldUrl = 'https://example.test/expired-signature.jpg';
    const String newUrl = 'https://example.test/renewed-signature.jpg';
    await insertOnlineBook(coverUrl: oldUrl);
    adapter.fetchCoverBytes = (String url) async {
      if (url == newUrl) return _renewedCoverBytes;
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'HTTP 403',
        stage: 'cover',
      );
    };
    adapter.refreshScript = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: seriesWithCover(entry, newUrl),
          chapters: const <OnlineMangaChapter>[],
        );
    final int before = MangaShelfCoverRevision.value;

    await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(adapter.refreshCalls, 1, reason: '封面字节失败且来源可用时必须做一次详情-only 刷新');
    expect(
      (await readEntry('book-1')).series.coverUrl,
      newUrl,
      reason: '详情刷新拿到的新封面 URL 必须落库',
    );
    expect(
      await cache.storedSourceUrl('book-1'),
      newUrl,
      reason: '持久字节的源 URL 侧车必须切到新签名',
    );
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _renewedCoverBytes,
      reason: '自动续签必须刷新持久封面字节',
    );
    expect(
      MangaShelfCoverRevision.value,
      before + 1,
      reason: '新字节写入后必须 bump revision，书架 provider 立即重算',
    );

    final MediaItem refreshed = await resolveShelfBook('book-1');
    expect(
      Uri.parse(refreshed.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
      reason: '续签后书架卡片必须改用新的持久缓存封面',
    );
  });

  test('详情成功但章节刷新失败：新封面 URL 照常落库，旧章节列表保留', () async {
    const String oldUrl = 'https://example.test/expired-signature.jpg';
    const String newUrl = 'https://example.test/renewed-signature.jpg';
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      raw: <String, Object?>{},
    );
    await insertOnlineBook(
      coverUrl: oldUrl,
      chapters: const <OnlineMangaChapter>[chapter],
    );
    adapter.fetchCoverBytes = (String url) async {
      if (url == newUrl) return _renewedCoverBytes;
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'HTTP 403',
        stage: 'cover',
      );
    };
    adapter.refreshScript = (OnlineMangaLibraryEntry entry) async {
      throw OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.runtimeFailure,
        'chapter list failed',
        stage: 'chapters',
        // 详情阶段已成功：错误里带着新封面 URL。
        series: seriesWithCover(entry, newUrl),
      );
    };

    await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    final OnlineMangaLibraryEntry entry = await readEntry('book-1');
    expect(entry.series.coverUrl, newUrl, reason: '章节失败不得阻止详情阶段的新封面 URL 落库');
    expect(entry.chapters.map((OnlineMangaChapter it) => it.key), <String>[
      '/chapter/1',
    ], reason: '章节刷新失败时必须保留旧章节列表，不能清空');
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _renewedCoverBytes,
      reason: '详情成功即可刷新持久字节，不要求章节刷新成功',
    );
  });

  test('旧 URL 返回不可解码字节（解码失败）也触发自动续签', () async {
    const String oldUrl = 'https://example.test/html-error-page.jpg';
    const String newUrl = 'https://example.test/renewed-signature.jpg';
    await insertOnlineBook(coverUrl: oldUrl);
    adapter.fetchCoverBytes = (String url) async {
      if (url == newUrl) return _renewedCoverBytes;
      // 扩展把 HTML 错误页当封面字节返回：写侧完整性校验会拒绝。
      return utf8.encode('<html>expired signature</html>');
    };
    adapter.refreshScript = (OnlineMangaLibraryEntry entry) async =>
        OnlineMangaRefreshResult(
          series: seriesWithCover(entry, newUrl),
          chapters: const <OnlineMangaChapter>[],
        );

    await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(adapter.refreshCalls, 1, reason: '解码失败与 HTTP 失败一样属于封面字节获取失败，应触发续签');
    expect(await cache.storedSourceUrl('book-1'), newUrl);
    expect(cache.coverPathFor('book-1').readAsBytesSync(), _renewedCoverBytes);
  });

  test('自动续签每本书每次启动最多一次：连续失败不循环请求', () async {
    await insertOnlineBook(coverUrl: 'https://example.test/always-403.jpg');
    adapter.fetchCoverBytes = (String _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'HTTP 403',
          stage: 'cover',
        );
    adapter.refreshScript = (OnlineMangaLibraryEntry _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'details unavailable',
          stage: 'details',
        );
    final OnlineMangaLibraryEntry entry = await readEntry('book-1');

    for (int i = 0; i < 3; i++) {
      expect(
        await service.refreshIfNeeded(entry, 'book-1'),
        isFalse,
        reason: '续签失败必须报告失败并保留旧缓存 / 占位',
      );
    }

    expect(adapter.refreshCalls, 1, reason: '同一本书每次启动最多自动续签一次，失败不得形成请求循环');
    expect(
      await cache.lastRenewalAttempt('book-1'),
      isNotNull,
      reason: '失败也算一次尝试：尝试时间必须落盘，跨启动 24 小时冷却才能生效',
    );
  });

  test('自动续签有 24 小时冷却：冷却窗内不请求，超过 24 小时可再尝试一次', () async {
    const String url = 'https://example.test/always-403.jpg';
    await insertOnlineBook(bookKey: 'cooled', coverUrl: url);
    await insertOnlineBook(bookKey: 'expired', coverUrl: url);
    adapter.fetchCoverBytes = (String _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'HTTP 403',
          stage: 'cover',
        );
    adapter.refreshScript = (OnlineMangaLibraryEntry _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'details unavailable',
          stage: 'details',
        );
    final DateTime now = DateTime.now();
    // 上次已续签（失败也算一次尝试），冷却时间写入 Program state 缓存。
    await cache.markRenewalAttempt('cooled', now);
    await cache.markRenewalAttempt(
      'expired',
      now.subtract(const Duration(hours: 25)),
    );

    await service.refreshIfNeeded(await readEntry('cooled'), 'cooled');
    expect(adapter.refreshCalls, 0, reason: '24 小时冷却窗内不得再次向源请求详情');

    await service.refreshIfNeeded(await readEntry('expired'), 'expired');
    expect(adapter.refreshCalls, 1, reason: '冷却过期后允许下一次尝试，但仍只请求一次');
  });

  test('封面字节写入成功：refreshIfNeeded 报告成功并 bump 进程级封面 revision', () async {
    const String url = 'https://example.test/signed-cover.jpg';
    await insertOnlineBook(coverUrl: url);
    final OnlineMangaLibraryEntry entry = await readEntry('book-1');
    final List<int> revisions = <int>[];
    final StreamSubscription<int> subscription = MangaShelfCoverRevision.events
        .listen(revisions.add);
    addTearDown(subscription.cancel);
    final int before = MangaShelfCoverRevision.value;

    final bool stored = await service.refreshIfNeeded(entry, 'book-1');
    await pumpEventQueue();

    expect(stored, isTrue, reason: '字节成功写入 Program state 缓存时必须报告成功');
    expect(
      MangaShelfCoverRevision.value,
      before + 1,
      reason: '成功写入后必须 bump 进程级封面 revision，书架据此重算',
    );
    expect(revisions, <int>[before + 1], reason: '订阅者应恰好收到一次递增后的 revision');
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _pngBytes,
      reason: 'revision 只应在持久字节真正落盘后 bump',
    );
  });

  test('封面字节刷新失败或没有新字节：报告失败且不 bump revision', () async {
    await insertOnlineBook(coverUrl: 'https://example.test/failing-cover.jpg');
    final OnlineMangaLibraryEntry entry = await readEntry('book-1');
    final List<int> revisions = <int>[];
    final StreamSubscription<int> subscription = MangaShelfCoverRevision.events
        .listen(revisions.add);
    addTearDown(subscription.cancel);
    final int before = MangaShelfCoverRevision.value;

    adapter.fetchCoverBytes = (String url) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'expired signature',
        );
    expect(
      await service.refreshIfNeeded(entry, 'book-1'),
      isFalse,
      reason: '运行时取字节失败时必须报告失败',
    );

    // 空字节同样视为失败：缓存层已有契约「空字节不覆盖旧封面」。
    adapter.fetchCoverBytes = (String _) async => <int>[];
    expect(
      await service.refreshIfNeeded(entry, 'book-1'),
      isFalse,
      reason: '没有新字节时必须报告失败',
    );
    await pumpEventQueue();

    expect(
      MangaShelfCoverRevision.value,
      before,
      reason: '失败或空字节不得 bump revision',
    );
    expect(revisions, isEmpty, reason: '失败不得触发书架 provider 重建');
    expect(await cache.hasCover('book-1'), isFalse);
  });

  ProviderContainer createShelfContainer() {
    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('字节写入成功后书架 provider 重新解析，卡片改用持久缓存封面', () async {
    const String url = 'https://example.test/revision-cover.jpg';
    await insertOnlineBook(coverUrl: url);
    // 用 Completer 卡住后台取字节，确保首轮书架解析先以远程 URL 完成，
    // 再让字节写入成功触发 revision——避免加载中的 provider 被 invalidate 的竞态。
    final Completer<List<int>> pendingBytes = Completer<List<int>>();
    adapter.fetchCoverBytes = (String _) => pendingBytes.future;
    final ProviderContainer container = createShelfContainer();
    final provider = fushiBooksProvider(JapaneseLanguage.instance);
    // 书架页面始终有监听者；无监听时 provider 在加载中被 invalidate 不会重发值。
    final ProviderSubscription<AsyncValue<List<MediaItem>>> subscription =
        container.listen<AsyncValue<List<MediaItem>>>(provider, (_, __) {});
    addTearDown(subscription.close);

    final List<MediaItem> first = await container.read(provider.future);
    expect(first.single.imageUrl, url, reason: '持久字节落盘前，书架先按已保存的远程 URL 回退');

    // 书架解析触发的后台刷新成功后 bump revision；provider 必须重新解析。
    pendingBytes.complete(_pngBytes);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    final List<MediaItem> refreshed = await container.read(provider.future);

    expect(
      Uri.parse(refreshed.single.imageUrl!).toFilePath(),
      cache.coverPathFor('book-1').path,
      reason: 'revision 变化后书架必须重新解析 MediaItem，卡片读取新的持久缓存封面',
    );
  });

  test('封面刷新失败不 bump revision，书架 provider 不重算', () async {
    const String url = 'https://example.test/always-403.jpg';
    await insertOnlineBook(coverUrl: url);
    adapter.fetchCoverBytes = (String _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'expired signature',
        );
    final ProviderContainer container = createShelfContainer();
    final provider = fushiBooksProvider(JapaneseLanguage.instance);
    final List<AsyncValue<List<MediaItem>>> states =
        <AsyncValue<List<MediaItem>>>[];
    final ProviderSubscription<AsyncValue<List<MediaItem>>> subscription =
        container.listen<AsyncValue<List<MediaItem>>>(provider, (
          AsyncValue<List<MediaItem>>? previous,
          AsyncValue<List<MediaItem>> next,
        ) {
          states.add(next);
        }, fireImmediately: true);
    addTearDown(subscription.close);

    final List<MediaItem> first = await container.read(provider.future);
    expect(first.single.imageUrl, url);
    // 初始 Drift 集合流事件落定后再取基线，避免把正常的首次加载算成重建。
    await pumpEventQueue();
    final int settledStates = states.length;

    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    await pumpEventQueue();

    expect(
      states.length,
      settledStates,
      reason: '刷新失败不得 invalidate 书架 provider（无意义的重算）',
    );
    expect(MangaShelfCoverRevision.value, 0);
    expect(container.read(provider).valueOrNull!.single.imageUrl, url);
  });

  test('本地封面文件优先于持久封面缓存；真实远程字节保留在 Program state', () async {
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
      p.join(extractDir, 'cover.jpg'),
      reason: 'ticket 02 的优先级：本地 cover.* 文件先于持久字节缓存',
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

  test('切换封面 URL 后书架卡片不再命中旧网络封面缓存条目', () async {
    const String oldUrl = 'https://example.test/old-signature.jpg';
    const String newUrl = 'https://example.test/new-signature.jpg';
    await insertOnlineBook(coverUrl: oldUrl);
    // 取字节失败 → 没有持久字节缓存，书架继续显示远程 URL（正是旧缓存会
    // 压制新封面的场景）。
    adapter.fetchCoverBytes = (String _) async =>
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'expired signature',
        );
    final MediaItem first = await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    expect(first.imageUrl, oldUrl);

    // 模拟书架卡片已经用旧 URL 渲染过：旧失败 / 旧图条目占住该 provider 键。
    final ImageProvider<Object> oldThumbnail = MangaFushiSource.instance
        .getDisplayThumbnailFromMediaItem(
          appModel: appModel,
          item: first,
          noOverride: true,
        );
    expect(oldThumbnail, isA<AppCachedHttpImage>());
    PaintingBinding.instance.imageCache.putIfAbsent(
      oldThumbnail,
      () => _PendingImageCompleter(),
    );
    expect(
      PaintingBinding.instance.imageCache.containsKey(oldThumbnail),
      isTrue,
      reason: '先构造出「旧 URL 的图片缓存条目仍在」的状态',
    );

    await updateCoverUrl('book-1', newUrl);
    final MediaItem second = await resolveShelfBook('book-1');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(second.imageUrl, newUrl, reason: '书架应按新的签名 URL 回退');
    final ImageProvider<Object> newThumbnail = MangaFushiSource.instance
        .getDisplayThumbnailFromMediaItem(
          appModel: appModel,
          item: second,
          noOverride: true,
        );
    expect(
      newThumbnail,
      isNot(equals(oldThumbnail)),
      reason: 'URL 切换后卡片的图片缓存键必须变化，旧条目不得压制新封面',
    );
    expect(
      PaintingBinding.instance.imageCache.containsKey(newThumbnail),
      isFalse,
      reason: '新 URL 的缓存键不得命中旧的失败 / 旧图条目，必须重新取图',
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
    // 来源仍可用：后台会按新 URL 重试，但返回空字节视为失败，不得重建缓存；
    // 断言的是用户清缓存后的展示回退。
    adapter.fetchCoverBytes = (_) async => <int>[];

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
      reason: '持久缓存清空且来源可用时，书架回退到已保存的远程封面 URL（现有 HTTP 图片缓存）',
    );
    expect(placeholder.imageUrl, isNull, reason: '既无缓存、无本地封面、也无远程 URL 时交给占位封面');
    expect(
      await cache.hasCover('book-1'),
      isFalse,
      reason: '后台刷新失败（空字节）不得重建持久缓存',
    );
  });

  test('来源未安装/未启用时不做运行时抓取；不回退远程 URL，已有缓存或本地封面仍显示', () async {
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
    expect(adapter.refreshCalls, 0, reason: '来源未安装/未启用时不得做详情刷新（自动续签必须跳过）');
    expect(
      noCacheBook.imageUrl,
      isNull,
      reason: '来源未安装/未启用时不得使用已保存的远程 URL，应交给占位封面',
    );
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
      reason: '来源缺失时已有本地封面继续显示，且不读取远程 URL',
    );
    expect(downloadsDir.existsSync(), isFalse);
  });

  test('本地封面存在但没有持久缓存：仍按当前 URL 后台刷新字节，显示仍优先本地封面', () async {
    const String url = 'https://example.test/new-signature-with-local.jpg';
    final String localDir = await insertOnlineBook(
      bookKey: 'book-1',
      coverUrl: url,
      localCover: true,
    );

    final MediaItem first = await resolveShelfBook('book-1');
    expect(
      Uri.parse(first.imageUrl!).toFilePath(),
      p.join(localDir, 'cover.jpg'),
      reason: '有本地封面时显示仍优先本地文件',
    );
    expect(
      await cache.hasCover('book-1'),
      isFalse,
      reason: '刷新是后台进行的，书架解析当下还没有持久字节',
    );

    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(adapter.fetchedCoverUrls, <String>[
      url,
    ], reason: '本地封面存在 + 无持久缓存 + 新 URL 时也必须调度后台刷新');
    expect(
      cache.coverPathFor('book-1').readAsBytesSync(),
      _pngBytes,
      reason: '后台刷新成功后持久缓存立即可用',
    );

    final MediaItem second = await resolveShelfBook('book-1');
    expect(
      Uri.parse(second.imageUrl!).toFilePath(),
      p.join(localDir, 'cover.jpg'),
      reason: '本地 cover.* 始终优先于持久字节缓存（ticket 02 封面优先级）',
    );
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

  test('源未安装 + CBZ：书架懒生成第一页封面，revision 后立即显示', () async {
    adapter.sourceAvailable = false;
    const String bookKey = 'generated-book';
    const String chapterKey = '/chapter/1';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: null,
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    final File cbz = writeCbz(
      p.join(extractDir, 'Ch 1.cbz'),
      <String, List<int>>{
        'ComicInfo.xml': utf8.encode('<ComicInfo/>'),
        '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
      },
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );
    final int before = MangaShelfCoverRevision.value;

    final MediaItem first = await resolveShelfBook(bookKey);
    expect(first.imageUrl, isNull, reason: '生成完成前书架显示占位，不阻塞渲染');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    expect(
      MangaShelfCoverRevision.value,
      before + 1,
      reason: '生成封面写入缓存后必须 bump revision，书架 provider 重算',
    );

    final MediaItem second = await resolveShelfBook(bookKey);
    expect(second.imageUrl, startsWith('file://'));
    expect(
      Uri.parse(second.imageUrl!).toFilePath(),
      cache.coverPathFor(bookKey).path,
      reason: '书架卡必须使用 Program state 的第一页生成封面缓存',
    );
    final File cover = cache.coverPathFor(bookKey);
    expect(img.decodeJpg(cover.readAsBytesSync())!.width, 600);
    expect(
      File(p.join(extractDir, 'cover.jpg')).existsSync(),
      isFalse,
      reason: '不得往 Content root / Download library 写 cover.jpg',
    );
    expect(cbz.existsSync(), isTrue, reason: '不得移动或解压原 CBZ');
  });

  test('本地 cover.* 优先于生成封面：有本地封面时不生成、不写缓存', () async {
    adapter.sourceAvailable = false;
    const String bookKey = 'local-priority';
    const String chapterKey = '/chapter/1';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: null,
      localCover: true,
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    writeCbz(p.join(extractDir, 'Ch 1.cbz'), <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    final MediaItem item = await resolveShelfBook(bookKey);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(
      Uri.parse(item.imageUrl!).toFilePath(),
      p.join(extractDir, 'cover.jpg'),
      reason: '本地 cover.* 必须优先于第一页生成封面',
    );
    expect(
      await cache.hasCover(bookKey),
      isFalse,
      reason: '已有本地封面时不应生成/缓存第一页封面',
    );
    expect(MangaShelfCoverRevision.value, 0);
  });

  test('来源可用且当前封面 URL 存在：使用来源封面，不生成第一页封面', () async {
    adapter.sourceAvailable = true;
    const String bookKey = 'remote-priority';
    const String chapterKey = '/chapter/1';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: 'https://example.test/current.jpg',
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    writeCbz(p.join(extractDir, 'Ch 1.cbz'), <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    final MediaItem item = await resolveShelfBook(bookKey);
    expect(item.imageUrl, 'https://example.test/current.jpg');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(
      await cache.storedSourceUrl(bookKey),
      'https://example.test/current.jpg',
      reason: '来源当前封面优先；持久缓存侧车应是 URL 而不是本地 sentinel',
    );
    expect(
      await (MangaFirstPageCoverService(
        database: db,
        cache: cache,
      )).cachedGeneratedCoverUrl(bookKey),
      isNull,
    );
    expect(
      File(p.join(extractDir, 'cover.jpg')).existsSync(),
      isFalse,
    );
  });

  test('容器更新后重新生成封面，revision 让书架拿到新图', () async {
    adapter.sourceAvailable = false;
    const String bookKey = 'container-change';
    const String chapterKey = '/chapter/1';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: null,
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    final File cbz = writeCbz(
      p.join(extractDir, 'Ch 1.cbz'),
      <String, List<int>>{
        '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
      },
    );
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    await resolveShelfBook(bookKey);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    final File cover = cache.coverPathFor(bookKey);
    expect(img.decodeJpg(cover.readAsBytesSync())!.getPixel(10, 10).r,
        greaterThan(200));
    final int firstRevision = MangaShelfCoverRevision.value;
    final String firstSentinel = (await cache.storedSourceUrl(bookKey))!;

    await Future<void>.delayed(const Duration(seconds: 1));
    writeCbz(p.join(extractDir, 'Ch 1.cbz'), <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(0, 0, 255)),
    });
    expect(cbz.existsSync(), isTrue);

    await resolveShelfBook(bookKey);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(MangaShelfCoverRevision.value, greaterThan(firstRevision));
    expect(await cache.storedSourceUrl(bookKey), isNot(firstSentinel));
    expect(
      img.decodeJpg(cover.readAsBytesSync())!.getPixel(10, 10).b,
      greaterThan(200),
      reason: '容器变化后书架必须显示重新生成的第一页封面',
    );
  });

  test('坏页 / 坏容器保留占位：不崩溃、不写缓存、不 bump revision', () async {
    adapter.sourceAvailable = false;
    const String bookKey = 'broken-page';
    const String chapterKey = '/chapter/1';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: null,
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    File(p.join(extractDir, 'Ch 1.cbz'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    final MediaItem item = await resolveShelfBook(bookKey);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(item.imageUrl, isNull, reason: '坏容器不得让书架崩溃，保持占位');
    expect(await cache.hasCover(bookKey), isFalse);
    expect(MangaShelfCoverRevision.value, 0);
  });

  test('来源恢复可用并成功取得真实封面后替换生成封面', () async {
    adapter.sourceAvailable = false;
    const String bookKey = 'source-recovered';
    const String chapterKey = '/chapter/1';
    const String remoteUrl = 'https://example.test/recovered.jpg';
    final String extractDir = await insertOnlineBook(
      bookKey: bookKey,
      coverUrl: remoteUrl,
      chapters: const <OnlineMangaChapter>[
        OnlineMangaChapter(
          key: chapterKey,
          name: 'Chapter 1',
          number: 1,
          raw: <String, Object?>{},
        ),
      ],
    );
    writeCbz(p.join(extractDir, 'Ch 1.cbz'), <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: 'Ch 1.cbz',
      containerKind: MangaChapterContainerKind.archive,
      updatedAt: 1,
    );

    await resolveShelfBook(bookKey);
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();
    final MediaItem generated = await resolveShelfBook(bookKey);
    expect(
      Uri.parse(generated.imageUrl!).toFilePath(),
      cache.coverPathFor(bookKey).path,
    );
    expect(
      isLocalSourceGeneratedCoverSentinel(await cache.storedSourceUrl(bookKey)),
      isTrue,
    );

    // 来源恢复：设备上来源可用，当前封面 URL 能取到真实字节。可用性判定在
    // 一次书架解析内按来源缓存；重新装配服务模拟下一次解析 / 重启。
    adapter.sourceAvailable = true;
    service = MangaShelfCoverService(
      cache: cache,
      serviceFor: (OnlineMangaRuntimeKind _) => library,
    );
    ReaderFushiSource.debugShelfCoverService = service;
    final MediaItem withRemote = await resolveShelfBook(bookKey);
    expect(withRemote.imageUrl, remoteUrl, reason: '来源当前封面重新高于生成封面');
    await ReaderFushiSource.debugWaitForShelfCoverRefreshes();

    expect(
      await cache.storedSourceUrl(bookKey),
      remoteUrl,
      reason: '成功取得真实封面后替换生成封面的 sentinel',
    );
    expect(
      await (MangaFirstPageCoverService(
        database: db,
        cache: cache,
      )).cachedGeneratedCoverUrl(bookKey),
      isNull,
    );
    final MediaItem real = await resolveShelfBook(bookKey);
    expect(
      Uri.parse(real.imageUrl!).toFilePath(),
      cache.coverPathFor(bookKey).path,
      reason: '真实封面字节落盘后书架命中同一缓存文件的新内容',
    );
  });

  test('生成封面不影响真实封面缓存的读取；来源缺失时使用生成封面', () async {
    final String extractDir = await insertOnlineBook(
      bookKey: 'no-remote',
      coverUrl: null,
    );
    await cache.store(
      bookKey: 'no-remote',
      sourceUrl: 'https://example.test/stale.jpg',
      bytes: _pngBytes,
    );
    final MediaItem item = await resolveShelfBook('no-remote');
    expect(
      Uri.parse(item.imageUrl!).toFilePath(),
      cache.coverPathFor('no-remote').path,
      reason: '来源缺失但已有真实持久缓存时继续显示缓存，不生成第一页',
    );
    expect(Directory(extractDir).existsSync(), isTrue);
  });
}
