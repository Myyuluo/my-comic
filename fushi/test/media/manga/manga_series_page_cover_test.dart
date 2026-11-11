import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_first_page_cover_service.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_cover_placeholder.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 02：Manga 作品页封面与书架同一套「本地优先、备份 series.coverUrl
/// 远程回退、失败/空值占位」规则。用页面级 seam：真实 Drift DB + 可控运行时
/// 适配器（本测试不联网），断言只落在用户可见的封面控件与占位块上。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// null = 来源未安装 / 停用（作品页按缺失来源降级）。
  String? sourceLabelValue = 'Fake';

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      sourceLabelValue;

  int refreshCalls = 0;

  /// 非空时替换默认的「原样返回」，用于手动刷新 / 章节失败用例。
  Future<OnlineMangaRefreshResult> Function(OnlineMangaLibraryEntry entry)?
  refreshResult;

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    refreshCalls++;
    final Future<OnlineMangaRefreshResult> Function(OnlineMangaLibraryEntry)?
    script = refreshResult;
    if (script != null) return script(entry);
    return OnlineMangaRefreshResult(
      series: entry.series,
      chapters: entry.chapters,
    );
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the series page must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the series page must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;
}

Finder _httpCover(String url) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Image &&
      widget.image is AppCachedHttpImage &&
      (widget.image as AppCachedHttpImage).url == url,
);

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
);

const List<OnlineMangaChapter> _oneChapter = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry({String? coverUrl}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'mihon.unavailable',
  sourceId: '524579092615598717',
  series: OnlineMangaSeries(
    key: '/series/imported',
    title: 'Imported series',
    coverUrl: coverUrl,
    raw: const <String, Object?>{},
  ),
  // 有缓存章节时作品页首屏不自动联网（刷新策略）；封面测试不依赖运行时。
  chapters: _oneChapter,
);

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_cover_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
  });

  tearDown(() async {
    MangaFirstPageCoverService.debugServiceOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<({String bookKey, String extractDir})> insertImportedSeries({
    required String? coverUrl,
    bool localCover = false,
  }) async {
    const String bookKey = 'imported-series';
    final String extractDir = p.join(root.path, 'downloads', bookKey);
    Directory(extractDir).createSync(recursive: true);
    if (localCover) {
      File(p.join(extractDir, 'cover.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    }
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Imported series',
        epubPath: p.join(extractDir, 'pages.json'),
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(_entry(coverUrl: coverUrl).encode()),
      ),
    );
    return (bookKey: bookKey, extractDir: extractDir);
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

  List<int> pngBytes() {
    final img.Image image = img.Image(width: 900, height: 1200)
      ..clear(img.ColorRgb8(255, 0, 0));
    return img.encodePng(image);
  }

  Future<void> pumpTarget(
    WidgetTester tester,
    AppModel appModel,
    MangaSeriesTarget target,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_harness(appModel, target));
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('manga_series_title')),
    );
  }

  Future<void> pumpSeriesPage(
    WidgetTester tester,
    AppModel appModel,
    String bookKey,
  ) => pumpTarget(tester, appModel, ShelfMangaSeriesTarget(bookKey));

  /// 「刷新章节」在空间足够时平铺在操作栏，空间不足时收进「⋯」。
  Future<void> tapRefresh(WidgetTester tester) async {
    final Finder refresh = find.byKey(
      const ValueKey<String>('manga_series_refresh'),
    );
    if (refresh.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey<String>('online_work_more')));
      await pumpUntilFound(tester, refresh);
    }
    await tester.tap(refresh);
  }

  testWidgets('本地没有封面文件时，作品页封面回退到 series.coverUrl', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.test/imported-series.jpg',
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);
      // 票 02：来源解析完成后才发远程封面请求。
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/imported-series.jpg'),
      );

      final Iterable<Image> images = tester.widgetList<Image>(
        find.byType(Image),
      );
      expect(
        images.any(
          (Image image) =>
              image.image is AppCachedHttpImage &&
              (image.image as AppCachedHttpImage).url ==
                  'https://example.test/imported-series.jpg',
        ),
        isTrue,
        reason: '无本地封面时作品页必须经现有 HTTP 图片缓存显示备份里的远程封面',
      );
      // 测试环境的 HttpClient 固定 400，远程图会走 errorBuilder 回到占位块；
      // 这里只断言「选中了远程封面路径」，渲染失败由下一个用例覆盖。
    });
  });

  testWidgets('远程封面加载失败时回到占位块，不留破图或未捕获异常', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.invalid/unreachable.jpg',
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);

      // 先确认确实走了远程封面路径（否则「一开始就是占位」会让本测试假绿）。
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Image && widget.image is AppCachedHttpImage,
        ),
      );
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isTrue,
        reason: '前置：页面应先尝试远程封面',
      );

      await pumpUntilFound(tester, find.byType(MangaCoverPlaceholder));
    });

    expect(
      tester.takeException(),
      isNull,
      reason: '远程封面加载失败必须被 errorBuilder 接住，退回现有占位块',
    );
    expect(find.byType(MangaCoverPlaceholder), findsOneWidget);
  });

  testWidgets('本地封面文件优先于远程 coverUrl（作品页）', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.invalid/remote.jpg',
            localCover: true,
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);

      final List<Image> images = tester
          .widgetList<Image>(find.byType(Image))
          .toList(growable: false);
      expect(
        images.any(
          (Image image) =>
              image.image is FileImage &&
              (image.image as FileImage).file.path ==
                  p.join(row.extractDir, 'cover.jpg'),
        ),
        isTrue,
        reason: '有本地封面文件时作品页必须继续显示它',
      );
      expect(
        images.any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '本地封面不得被远程 coverUrl 覆盖',
      );
      expect(find.byType(MangaCoverPlaceholder), findsNothing);
    });
  });

  testWidgets('coverUrl 为空时直接显示占位块，不发起远程取图', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(coverUrl: '   ');
      await pumpSeriesPage(tester, appModel, row.bookKey);

      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '空 coverUrl 不得伪造可加载的远程封面',
      );
      expect(find.byType(MangaCoverPlaceholder), findsOneWidget);
    });
  });

  testWidgets('打开源页面识别到已有记录：把当前封面 URL 合并回记录，不额外联网', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final Directory downloadsRoot = Directory(p.join(root.path, 'downloads'));
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: downloadsRoot,
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _entry(coverUrl: 'https://example.test/old-signature.jpg'),
      );
      await pumpTarget(
        tester,
        appModel,
        SourceMangaSeriesTarget(
          adapter: adapter,
          seed: _entry(coverUrl: 'https://example.test/fresh-signature.jpg'),
          service: library,
        ),
      );
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/fresh-signature.jpg'),
      );

      final EpubBookRow? after = await db.getEpubBook(row.bookKey);
      final OnlineMangaLibraryEntry kept =
          OnlineMangaLibraryEntry.tryParse(after!.sourceMetadata)!;
      expect(
        kept.series.coverUrl,
        'https://example.test/fresh-signature.jpg',
        reason: '源搜索/详情页当前返回的封面 URL 必须合并回已有记录',
      );
      expect(kept.chapters, hasLength(1), reason: '只合并系列描述，不动章节缓存');
      expect(adapter.refreshCalls, 0, reason: '合并不要求额外网络请求');
      expect(
        downloadsRoot.existsSync(),
        isFalse,
        reason: '合并封面 URL 不得创建 Download library 目录',
      );
    });
  });

  testWidgets('签名 URL 过期后：手动刷新把新 URL 落库并更新封面', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter()
      ..refreshResult = (OnlineMangaLibraryEntry entry) async =>
          OnlineMangaRefreshResult(
            series: OnlineMangaSeries(
              key: entry.series.key,
              title: entry.series.title,
              coverUrl: 'https://example.test/refreshed-signature.jpg',
              raw: entry.series.raw,
            ),
            chapters: _oneChapter,
          );
    final Directory downloadsRoot = Directory(p.join(root.path, 'downloads'));
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: downloadsRoot,
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _entry(coverUrl: 'https://example.test/expired-signature.jpg'),
      );
      await pumpSeriesPage(tester, appModel, row.bookKey);
      // 首屏只读缓存：先看到过期 URL，不自动联网。
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/expired-signature.jpg'),
      );
      expect(adapter.refreshCalls, 0);

      await tapRefresh(tester);
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/refreshed-signature.jpg'),
      );

      final EpubBookRow? after = await db.getEpubBook(row.bookKey);
      final OnlineMangaLibraryEntry kept =
          OnlineMangaLibraryEntry.tryParse(after!.sourceMetadata)!;
      expect(
        kept.series.coverUrl,
        'https://example.test/refreshed-signature.jpg',
        reason: '手动刷新成功后，新签名 URL 必须持久化，书架封面自愈',
      );
      expect(kept.chapters, hasLength(1));
      expect(adapter.refreshCalls, 1);
      expect(
        downloadsRoot.existsSync(),
        isFalse,
        reason: '刷新封面 URL 不得创建 Download library 目录',
      );
    });
  });

  testWidgets('章节抓取失败：封面仍更新、旧章节保留、横幅提示刷新未完成', (
    WidgetTester tester,
  ) async {
    const OnlineMangaSeries freshSeries = OnlineMangaSeries(
      key: '/series/imported',
      title: 'Imported series',
      coverUrl: 'https://example.test/refreshed-after-chapter-failure.jpg',
      raw: <String, Object?>{},
    );
    final _FakeAdapter adapter = _FakeAdapter()
      ..refreshResult = (OnlineMangaLibraryEntry entry) async =>
          throw const OnlineMangaUnavailable(
            OnlineMangaUnavailableReason.runtimeFailure,
            'Cloudflare challenge',
            stage: 'chapters',
            series: freshSeries,
          );
    final Directory downloadsRoot = Directory(p.join(root.path, 'downloads'));
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: downloadsRoot,
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _entry(coverUrl: 'https://example.test/expired-signature.jpg'),
      );
      await pumpSeriesPage(tester, appModel, row.bookKey);
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/expired-signature.jpg'),
      );

      await tapRefresh(tester);
      await pumpUntilFound(
        tester,
        _httpCover('https://example.test/refreshed-after-chapter-failure.jpg'),
      );

      expect(
        find.text('Chapter 1'),
        findsOneWidget,
        reason: '章节列表抓取失败时保留旧章节缓存，不清空页面',
      );
      expect(
        find.byKey(const ValueKey<String>('manga_series_refresh_banner')),
        findsOneWidget,
        reason: '章节没拉全仍要提示这次刷新未完成',
      );

      final EpubBookRow? after = await db.getEpubBook(row.bookKey);
      final OnlineMangaLibraryEntry kept =
          OnlineMangaLibraryEntry.tryParse(after!.sourceMetadata)!;
      expect(
        kept.series.coverUrl,
        'https://example.test/refreshed-after-chapter-failure.jpg',
        reason: '详情已成功：章节失败也要先把新封面 URL 落库',
      );
      expect(kept.chapters, hasLength(1), reason: '旧章节不清空');
    });
  });

  testWidgets('来源未安装 + 本地 CBZ：作品页显示第一页生成封面，不请求过期远程封面', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter()..sourceLabelValue = null;
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final MangaShelfCoverCache cache = MangaShelfCoverCache(
      Directory(p.join(root.path, 'cache', 'shelf_covers')),
    );
    MangaFirstPageCoverService.debugServiceOverride =
        MangaFirstPageCoverService(database: db, cache: cache);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.test/expired-signature.jpg',
          );
      writeCbz(p.join(row.extractDir, 'Ch 1.cbz'), <String, List<int>>{
        'ComicInfo.xml': utf8.encode('<ComicInfo/>'),
        '001.png': pngBytes(),
      });

      await pumpSeriesPage(tester, appModel, row.bookKey);
      final File cover = cache.coverPathFor(row.bookKey);
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Image &&
              widget.image is FileImage &&
              (widget.image as FileImage).file.path == cover.path,
        ),
      );

      expect(
        img.decodeJpg(cover.readAsBytesSync())!.width,
        600,
        reason: '作品页必须显示从第一页生成的封面字节',
      );
      expect(find.byType(MangaCoverPlaceholder), findsNothing);
      expect(
        File(p.join(row.extractDir, 'cover.jpg')).existsSync(),
        isFalse,
        reason: '生成封面只落 Program state 缓存，不写 Content root',
      );
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '来源未安装时不得请求过期远程封面',
      );
    });
  });

  testWidgets('来源未安装但已有持久封面字节：作品页先显示缓存，不回退占位', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter()..sourceLabelValue = null;
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    final MangaShelfCoverCache cache = MangaShelfCoverCache(
      Directory(p.join(root.path, 'cache', 'shelf_covers')),
    );
    MangaFirstPageCoverService.debugServiceOverride =
        MangaFirstPageCoverService(database: db, cache: cache);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.test/expired-signature.jpg',
          );
      await cache.store(
        bookKey: row.bookKey,
        sourceUrl: 'https://example.test/expired-signature.jpg',
        bytes: pngBytes(),
      );

      await pumpSeriesPage(tester, appModel, row.bookKey);
      final String coverPath = cache.coverPathFor(row.bookKey).path;
      await pumpUntilFound(
        tester,
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is Image &&
              widget.image is FileImage &&
              (widget.image as FileImage).file.path == coverPath,
        ),
      );

      expect(find.byType(MangaCoverPlaceholder), findsNothing);
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '来源未安装时先显示持久缓存，不发起远程封面请求',
      );
    });
  });
}
