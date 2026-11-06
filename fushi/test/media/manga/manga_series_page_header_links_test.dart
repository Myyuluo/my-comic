import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_global_search_page.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// Manga 作品页头部（ticket 03）：移除「已入库」「外部来源」两枚 chip，保留
/// 「扩展源」；书名与作者可点击，跳「搜索全部来源」并自动执行搜索。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

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

/// 可控的在线 Source 运行时：记录每次搜索的来源与关键词，返回空结果（不触发
/// 封面取图，测试只关心「搜了哪个源、用什么词」）。
class _FakeMihonRuntime extends Fake implements MihonRuntime {
  final List<({String sourceName, String query})> searches =
      <({String sourceName, String query})>[];

  @override
  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    searches.add((sourceName: source.name, query: query));
    return const MihonMangaPage(items: <MihonManga>[], hasNextPage: false);
  }

  @override
  Future<void> dispose() async {}
}

class _TestAppModel extends AppModel {
  _TestAppModel(
    this._db,
    this._library,
    Directory root, {
    this.mihonManagerOverride,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;

  /// null = 「当前平台没有在线扩展运行时」，取 manager 会抛错（同生产 iOS）。
  final MihonManager? mihonManagerOverride;

  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  @override
  MihonManager get mihonManager {
    final MihonManager? manager = mihonManagerOverride;
    if (manager == null) {
      throw UnsupportedError('Mihon runtime is not available on this platform');
    }
    return manager;
  }

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
    opened.add(item);
  }
}

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((Ref ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
);

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry({
  String title = 'Fixture series',
  String? author = 'Fixture author',
  OnlineMangaRuntimeKind runtime = OnlineMangaRuntimeKind.mihon,
}) => OnlineMangaLibraryEntry(
  runtime: runtime,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: title,
    author: author,
    raw: const <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
);

MangaExtensionsCompanion _extension(
  String packageName, {
  bool enabled = true,
}) => MangaExtensionsCompanion.insert(
  packageName: packageName,
  name: '$packageName extension',
  versionCode: 1,
  versionName: '1.0.0',
  libVersion: '1.6',
  language: 'en',
  apkPath: 'extensions/$packageName.ext',
  apkSha256: '$packageName-apk-sha',
  signerSha256: '$packageName-signer-sha',
  enabled: Value<bool>(enabled),
  installedAt: 1,
);

MangaOnlineSourcesCompanion _source(
  String packageName,
  String sourceId,
  String name, {
  bool enabled = true,
}) => MangaOnlineSourcesCompanion.insert(
  extensionPackage: packageName,
  sourceId: sourceId,
  name: name,
  language: 'en',
  enabled: Value<bool>(enabled),
);

Future<MihonManager> _createManager(
  FushiDatabase db,
  Directory root, {
  bool withEnabledSource = true,
  _FakeMihonRuntime? runtime,
}) async {
  if (withEnabledSource) {
    await db.upsertMangaExtension(_extension('org.example.enabled'));
    await db.upsertMangaExtension(
      _extension('org.example.ext-disabled', enabled: false),
    );
    await db.replaceMangaOnlineSources(
      'org.example.enabled',
      <MangaOnlineSourcesCompanion>[
        _source('org.example.enabled', '1', 'Enabled source'),
        _source('org.example.enabled', '2', 'Disabled source', enabled: false),
      ],
    );
    await db.replaceMangaOnlineSources(
      'org.example.ext-disabled',
      <MangaOnlineSourcesCompanion>[
        _source('org.example.ext-disabled', '3', 'Extension disabled source'),
      ],
    );
  }
  final MihonManager manager = MihonManager(
    database: db,
    rootDirectory: Directory(p.join(root.path, 'mihon')),
    runtime: runtime ?? _FakeMihonRuntime(),
    ownsRuntime: false,
  );
  await manager.initialise();
  return manager;
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('never found $finder');
}

/// 等进场动画跑完：hero 的错峰进场用 Transform 位移，动画中内容在父级布局边界
/// 之外的部分不可命中（Flutter 的 RenderBox 尺寸裁剪），点击 / 悬停前先落定。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

const ValueKey<String> _titleKey = ValueKey<String>('manga_series_title');
const ValueKey<String> _authorChipKey = ValueKey<String>(
  'manga_series_author_chip',
);

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_header_');
    // 作品页读下载状态时会经 path_provider 找落盘目录；测试里给它一个临时目录。
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeAdapter(),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void sizeView(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('头部移除「已入库」「外部来源」，保留「扩展源」', (WidgetTester tester) async {
    sizeView(tester, const Size(1400, 1000));
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = (await library.add(_entry())).bookKey;
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(bookKey)),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('online-work-extension-source-chip')),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_in_library_chip')),
      findsNothing,
      reason: '「已入库」chip 已移除',
    );
    expect(
      find.byKey(const ValueKey<String>('online-work-external-source-chip')),
      findsNothing,
      reason: '「外部来源」chip 已移除',
    );
    expect(
      find.byKey(const ValueKey<String>('online-work-extension-source-chip')),
      findsOneWidget,
      reason: '「扩展源」chip 保留',
    );
    expect(find.text(t.video_discovery_in_library), findsNothing);
    expect(find.text(t.download_source_external), findsNothing);
    expect(find.text(t.download_method_extension), findsOneWidget);
  });

  testWidgets('点击书名：打开「搜索全部来源」，以书名自动搜索全部已启用在线源', (WidgetTester tester) async {
    // 窄窗口：header 在页面顶部（与宽屏左栏是同一个 header）。
    sizeView(tester, const Size(800, 1400));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    late MihonManager manager;
    late _TestAppModel appModel;
    await tester.runAsync(() async {
      manager = await _createManager(db, root, runtime: runtime);
      addTearDown(manager.dispose);
      appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      // 自动执行搜索：等结果区落定。
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));
    });

    expect(runtime.searches, <({String sourceName, String query})>[
      (sourceName: 'Enabled source', query: 'Fixture series'),
    ], reason: '只用书名搜全部已启用在线源（禁用的源与扩展都被排除）');
    expect(find.byType(MangaGlobalSearchPage), findsOneWidget);
    expect(find.text('Enabled source'), findsOneWidget);
  });

  testWidgets('点击作者 chip：以作者名打开搜索并自动执行', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        runtime: runtime,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_authorChipKey));
      await _settle(tester);
      await tester.tap(
        find.byKey(_authorChipKey),
        kind: PointerDeviceKind.mouse,
      );
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));
    });

    expect(runtime.searches, <({String sourceName, String query})>[
      (sourceName: 'Enabled source', query: 'Fixture author'),
    ]);
  });

  testWidgets('标题与作者只响应鼠标点击：触摸点击不打开搜索页', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        runtime: runtime,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);

      // 默认 tester.tap 是触摸指针：不应触发任何跳转。
      await tester.tap(find.byKey(_titleKey));
      await tester.tap(find.byKey(_authorChipKey));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });

    expect(find.byType(MangaGlobalSearchPage), findsNothing);
    expect(runtime.searches, isEmpty);
  });

  testWidgets('悬停提示：书名加下划线、作者 chip 提亮；指针保持默认', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = (await library.add(_entry())).bookKey;
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _pumpUntil(tester, find.byKey(_authorChipKey));
    });

    TextStyle titleStyle() => tester.widget<Text>(find.byKey(_titleKey)).style!;
    Color chipFill() =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: find.byKey(_authorChipKey),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color!;

    // 静止外观不变。
    expect(titleStyle().decoration, isNot(TextDecoration.underline));
    final Color restingFill = chipFill();

    // 鼠标指针保持默认（MouseRegion 不声明 click 光标）。
    expect(
      tester
          .widget<MouseRegion>(
            find
                .ancestor(
                  of: find.byKey(_titleKey),
                  matching: find.byType(MouseRegion),
                )
                .first,
          )
          .cursor,
      MouseCursor.defer,
    );
    expect(
      tester
          .widget<MouseRegion>(
            find
                .ancestor(
                  of: find.byKey(_authorChipKey),
                  matching: find.byType(MouseRegion),
                )
                .first,
          )
          .cursor,
      MouseCursor.defer,
    );

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();

    await mouse.moveTo(tester.getCenter(find.byKey(_titleKey)));
    await tester.pumpAndSettle();
    expect(
      titleStyle().decoration,
      TextDecoration.underline,
      reason: '书名悬停加下划线',
    );

    await mouse.moveTo(tester.getCenter(find.byKey(_authorChipKey)));
    await tester.pumpAndSettle();
    expect(
      titleStyle().decoration,
      isNot(TextDecoration.underline),
      reason: '移出书名后下划线消失',
    );
    expect(chipFill(), isNot(restingFill), reason: '作者 chip 悬停提亮');

    await mouse.moveTo(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(chipFill(), restingFill, reason: '移出后恢复静止外观');
  });

  // 本地卷与互联对端没有「在线 Source」上下文，但标题 / 作者仍按当前显示文字去
  // 全部已启用在线源搜索——行为与在线漫画完全一致。
  Future<String> pumpLocalVolume() => db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: 'local-manga-volume',
      title: 'Local Volume',
      author: const Value<String?>('Local Author'),
      epubPath: 'volume.cbz',
      extractDir: p.join(root.path, 'local-volume'),
      chapterCount: 3,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
    ),
  );

  testWidgets('本地卷：书名与作者同样可点击并自动搜索', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        runtime: runtime,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final String bookKey = await pumpLocalVolume();
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);
      expect(find.text('Local Volume'), findsWidgets);
      expect(find.text('Local Author'), findsOneWidget);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);
      await _pumpUntil(tester, find.byKey(_authorChipKey));
      await _settle(tester);
      await tester.tap(
        find.byKey(_authorChipKey),
        kind: PointerDeviceKind.mouse,
      );
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));
    });

    expect(
      runtime.searches.map((({String sourceName, String query}) s) => s.query),
      <String>['Local Volume', 'Local Author'],
    );
  });

  testWidgets('互联对端作品：书名与作者同样可点击并自动搜索', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        runtime: runtime,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(
        _entry(runtime: OnlineMangaRuntimeKind.interconnect),
      );
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);
      expect(find.text('Fixture author'), findsOneWidget);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _settle(tester);
      await _pumpUntil(tester, find.byKey(_authorChipKey));
      await _settle(tester);
      await tester.tap(
        find.byKey(_authorChipKey),
        kind: PointerDeviceKind.mouse,
      );
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));
    });

    expect(
      runtime.searches.map((({String sourceName, String query}) s) => s.query),
      <String>['Fixture series', 'Fixture author'],
    );
  });

  testWidgets('宽窗口左栏（side pane）：书名同样可点击', (WidgetTester tester) async {
    sizeView(tester, const Size(1400, 1000));
    final _FakeMihonRuntime runtime = _FakeMihonRuntime();
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        runtime: runtime,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('media-detail-side-pane')),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.mihon_source_no_results));
    });

    expect(
      runtime.searches.map((({String sourceName, String query}) s) => s.query),
      <String>['Fixture series'],
    );
  });

  testWidgets('没有可用在线源：打开搜索页自己的空态，不出现「去装来源」按钮', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    await tester.runAsync(() async {
      final MihonManager manager = await _createManager(
        db,
        root,
        withEnabledSource: false,
      );
      addTearDown(manager.dispose);
      final _TestAppModel appModel = _TestAppModel(
        db,
        library,
        root,
        mihonManagerOverride: manager,
      );
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await _pumpUntil(tester, find.byType(MangaGlobalSearchPage));
      await _pumpUntil(tester, find.text(t.manga_global_search_no_sources));
    });

    expect(
      find.byKey(const ValueKey<String>('manga_global_search_open_sources')),
      findsNothing,
      reason: '不接「去装来源」回调',
    );
  });

  testWidgets('平台不支持扩展运行时：点击书名 / 作者安全无操作', (WidgetTester tester) async {
    sizeView(tester, const Size(800, 1400));
    // 不提供 mihonManagerOverride：模型取 manager 时抛错，模拟不支持扩展运行时的平台。
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, find.byKey(_titleKey));
      await _settle(tester);

      await tester.tap(find.byKey(_titleKey), kind: PointerDeviceKind.mouse);
      await tester.tap(
        find.byKey(_authorChipKey),
        kind: PointerDeviceKind.mouse,
      );
      await _settle(tester);
    });

    expect(tester.takeException(), isNull);
    expect(find.byType(MangaGlobalSearchPage), findsNothing);
  });
}
