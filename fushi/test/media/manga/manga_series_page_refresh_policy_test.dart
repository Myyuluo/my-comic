import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// 作品页刷新策略（ticket 02）：已入库的在线漫画打开时只读本地缓存，不自动
/// 联网；未入库的来源作品仍自动拉一次；已入库但缓存没有章节时兜底拉一次；
/// 现有「⋯ → 刷新章节」手动刷新保持可用。Mihon 与互联对端同一规则。
///
/// 用页面级 seam：真实 37 表 `FushiDatabase` + 可控 adapter（记录 `refresh`
/// 调用次数）+ 真实偏好库。断言只落在用户可见行为与网络调用次数上。
class _CountingAdapter implements OnlineMangaRuntimeAdapter {
  _CountingAdapter({
    this.kind = OnlineMangaRuntimeKind.mihon,
    this.refreshedChapters = const <OnlineMangaChapter>[],
  });

  @override
  final OnlineMangaRuntimeKind kind;

  /// 每次 [refresh] 返回的章节列表。
  final List<OnlineMangaChapter> refreshedChapters;

  int refreshCalls = 0;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    refreshCalls++;
    return OnlineMangaRefreshResult(
      series: entry.series,
      chapters: refreshedChapters,
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

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    // 本测试只验证作品页的刷新策略，不让它真的 push 阅读页。
  }
}

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
);

const List<OnlineMangaChapter> _cachedChapters = <OnlineMangaChapter>[
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

const List<OnlineMangaChapter> _freshChapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{'url': '/chapter/3'},
  ),
];

OnlineMangaLibraryEntry _entry({
  OnlineMangaRuntimeKind runtime = OnlineMangaRuntimeKind.mihon,
  List<OnlineMangaChapter> chapters = _cachedChapters,
}) => OnlineMangaLibraryEntry(
  runtime: runtime,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: const OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: chapters,
);

/// 等页面首屏与所有后台尾活（下载状态、来源名解析）落定。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_refresh_');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    _TestAppModel appModel,
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

  for (final OnlineMangaRuntimeKind runtime in <OnlineMangaRuntimeKind>[
    OnlineMangaRuntimeKind.mihon,
    OnlineMangaRuntimeKind.interconnect,
  ]) {
    testWidgets('已入库且有缓存章节：打开不请求来源，直接显示缓存（${runtime.name}）', (
      WidgetTester tester,
    ) async {
      final _CountingAdapter adapter = _CountingAdapter(
        kind: runtime,
        refreshedChapters: _freshChapters,
      );
      final OnlineMangaLibraryService library = OnlineMangaLibraryService(
        database: db,
        rootDirectory: Directory(p.join(root.path, 'legacy')),
        adapter: adapter,
      );
      final _TestAppModel appModel = _TestAppModel(db, library, root);

      await tester.runAsync(() async {
        final EpubBookRow row = await library.add(_entry(runtime: runtime));
        await pumpPage(tester, appModel, ShelfMangaSeriesTarget(row.bookKey));
        await _settle(tester);
      });

      expect(adapter.refreshCalls, 0, reason: '首屏只读本地描述符与章节缓存');
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 2'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('manga_series_refresh_banner')),
        findsNothing,
      );
    });
  }

  testWidgets('未入库的来源作品：打开自动拉取一次详情与章节', (WidgetTester tester) async {
    final _CountingAdapter adapter = _CountingAdapter(
      refreshedChapters: _freshChapters,
    );
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      await pumpPage(
        tester,
        appModel,
        SourceMangaSeriesTarget(
          adapter: adapter,
          seed: _entry(chapters: const <OnlineMangaChapter>[]),
          service: library,
        ),
      );
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    expect(adapter.refreshCalls, 1, reason: '未入库作品仍自动拉一次');
    expect(find.text('Chapter 3'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
      reason: '仍处于未入库态',
    );
  });

  testWidgets('来源入口打开已入库作品：同样不自动刷新', (WidgetTester tester) async {
    final _CountingAdapter adapter = _CountingAdapter(
      refreshedChapters: _freshChapters,
    );
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      await library.add(_entry());
      await pumpPage(
        tester,
        appModel,
        SourceMangaSeriesTarget(
          adapter: adapter,
          seed: _entry(),
          service: library,
        ),
      );
      await _settle(tester);
    });

    expect(adapter.refreshCalls, 0, reason: '已在库 = 只读缓存，不因入口不同而联网');
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
      reason: '已切换成书架条目',
    );
  });

  testWidgets('已入库但缓存章节为空：打开兜底拉取一次', (WidgetTester tester) async {
    final _CountingAdapter adapter = _CountingAdapter(
      refreshedChapters: _freshChapters,
    );
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late List<OnlineMangaChapter> stored;

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _entry(chapters: const <OnlineMangaChapter>[]),
      );
      await pumpPage(tester, appModel, ShelfMangaSeriesTarget(row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 3'));
      final EpubBookRow? updated = await db.getEpubBook(row.bookKey);
      stored =
          OnlineMangaLibraryEntry.tryParse(updated?.sourceMetadata)?.chapters ??
          const <OnlineMangaChapter>[];
    });

    expect(adapter.refreshCalls, 1, reason: '缓存没有章节时兜底拉一次');
    expect(find.text('Chapter 3'), findsOneWidget);
    expect(stored.map((OnlineMangaChapter c) => c.key), <String>['/chapter/3']);
  });

  testWidgets('「⋯ → 刷新章节」仍能手动拉取并更新页面', (WidgetTester tester) async {
    final _CountingAdapter adapter = _CountingAdapter(
      refreshedChapters: _freshChapters,
    );
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      await pumpPage(tester, appModel, ShelfMangaSeriesTarget(row.bookKey));
      await _settle(tester);
      expect(adapter.refreshCalls, 0, reason: '打开时不联网');
      expect(find.text('Chapter 1'), findsOneWidget);

      // 「刷新章节」在空间足够时平铺在操作栏，空间不足时收进「⋯」。
      final Finder refresh = find.byKey(
        const ValueKey<String>('manga_series_refresh'),
      );
      if (refresh.evaluate().isEmpty) {
        await tester.tap(
          find.byKey(const ValueKey<String>('online_work_more')),
        );
        await pumpUntilFound(tester, refresh);
      }
      await tester.tap(refresh);
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    expect(adapter.refreshCalls, 1, reason: '手动刷新仍可用且只发一次');
    expect(find.text('Chapter 3'), findsOneWidget);
    expect(find.text('Chapter 1'), findsNothing, reason: '页面已更新为最新章节');
  });
}
