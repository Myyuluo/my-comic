import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/src/media/manga/manga_global_search_page.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_manager.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_models.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_runtime.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/book_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_platform_services.dart';

void main() {
  test('source image queue starts only four cover fetches at a time', () async {
    final MihonSourceImageLoadQueue queue = MihonSourceImageLoadQueue(
      maxConcurrent: 4,
    );
    final List<Completer<void>> gates = List<Completer<void>>.generate(
      10,
      (_) => Completer<void>(),
    );
    int active = 0;
    int maximumActive = 0;
    int started = 0;
    final List<Future<void>> tasks = <Future<void>>[
      for (int index = 0; index < gates.length; index++)
        queue.run<void>(() async {
          started++;
          active++;
          if (active > maximumActive) maximumActive = active;
          await gates[index].future;
          active--;
        }),
    ];

    await Future<void>.delayed(Duration.zero);
    expect(started, 4);
    expect(queue.active, 4);
    expect(queue.pending, 6);

    gates.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, 5);
    expect(maximumActive, 4);

    for (final Completer<void> gate in gates.skip(1)) {
      gate.complete();
    }
    await Future.wait<void>(tasks);
    expect(maximumActive, 4);
    expect(queue.active, 0);
    expect(queue.pending, 0);
  });

  late Directory root;
  late MyComicDatabase database;
  late _BrowseRuntime runtime;
  late MihonManager manager;
  late AppModel appModel;

  /// 作品页的 _load 会做真实文件 IO（下载目录身份扫描）。testWidgets 的
  /// FakeAsync 区里这些 Future 不会完成，必须用 runAsync 放行。
  Future<void> settleWithRealIo(WidgetTester tester) async {
    for (int i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget testApp(Widget home) => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
        ],
        child: MaterialApp(
          theme: ThemeData.light(useMaterial3: true),
          home: home,
        ),
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mycomic-mihon-browse-');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    database = MyComicDatabase.forTesting(NativeDatabase.memory());
    runtime = _BrowseRuntime();
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(database);
    // 作品页的 auto-refresh 会经 AppPaths 解析 downloads 根；widget 测试没有
    // path_provider 插件。把下载库派生到书根旁边，避免 ensureNonLibrary 挂起。
    EpubStorage.debugBaseDirectoryOverride =
        '${root.path}${Platform.pathSeparator}legacy';

    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: 'org.example.fixture',
        name: 'Raw Otaku fixture',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'en',
        apkPath: 'extensions/org.example.fixture.ext',
        apkSha256: 'fixture-apk-sha',
        signerSha256: 'fixture-signer-sha',
        installedAt: 1,
      ),
    );
    await database.replaceMangaOnlineSources(
      'org.example.fixture',
      <MangaOnlineSourcesCompanion>[
        MangaOnlineSourcesCompanion.insert(
          extensionPackage: 'org.example.fixture',
          sourceId: '9223372036854775807',
          name: 'Raw Otaku',
          language: 'en',
        ),
      ],
    );

    manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    await database.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (await root.exists()) await root.delete(recursive: true);
  });

  testWidgets(
    'opening a manga while its large chapter list resolves does not trip layout',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(2048, 1055));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        testApp(
          MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Raw Otaku fixture'), findsOneWidget);
      await tester.tap(
        find.byKey(
          const ValueKey<String>('mihon_browse_item_/manga/fixture'),
        ),
      );
      await tester.pump();
      await settleWithRealIo(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Add to manga shelf'), findsOneWidget);
    },
  );

  testWidgets(
    'a failed detail load surfaces the real cause and can be retried',
    (WidgetTester tester) async {
      // 原本这里只会渲染一行光秃的异常文本，既没重试也拿不到
      // 堆栈（BUG-1767）。这条用例盯住三件事：原因可见、诊断入口存在、
      // 重试真的会重新发请求并恢复正常页面。
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      runtime.detailsFailure = const MihonRuntimeException(
        'RUNTIME_FAILURE',
        'Mihon invoke/getDetailsManga failed: '
            'NoClassDefFoundError: kotlin.LazyKt',
        details: 'java.lang.NoClassDefFoundError\n\tat fixture.Stack',
      );

      await tester.pumpWidget(
        testApp(
          MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('mihon_browse_item_/manga/fixture'),
        ),
      );
      await tester.pump();
      await settleWithRealIo(tester);

      expect(tester.takeException(), isNull);
      expect(runtime.detailsCalls, 1);
      // 打开在线源作品页会先确保一条 membership=false 的库行（票 02），因此
      // 详情失败时页面不是空的：错误挂在 hero 下方的刷新提示条里，原始 cause
      // 与堆栈进「查看详情」对话框。
      expect(
        find.byKey(const ValueKey<String>('manga_series_refresh_banner')),
        findsOneWidget,
      );
      expect(find.text(t.manga_series_refresh_failed), findsOneWidget);

      // 诊断对话框里必须能拿到原生堆栈与失败原因。
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_error_details')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('NoClassDefFoundError: kotlin.LazyKt'),
        findsOneWidget,
      );
      await tester.tap(find.text('CLOSE'));
      await tester.pumpAndSettle();

      runtime.detailsFailure = null;
      await tester.tap(find.text(t.retry));
      await tester.pump();
      await settleWithRealIo(tester);

      expect(runtime.detailsCalls, 2);
      expect(
        find.byKey(const ValueKey<String>('manga_series_refresh_banner')),
        findsNothing,
      );
      expect(find.text('Chapter 1'), findsOneWidget);
    },
  );

  testWidgets(
    'wrapped detail challenge verifies explicitly then retries details',
    (WidgetTester tester) async {
      runtime.detailsFailure = MihonCloudflareChallengeException(
        Uri.parse('https://fixture.invalid/challenge'),
      );
      await tester.pumpWidget(
        testApp(
          MihonMangaDetailPage(
            manager: manager,
            sourceContext: await manager.contextForSource(
              manager.sources.single,
            ),
            manga: _BrowseRuntime.manga,
          ),
        ),
      );
      await tester.pump();
      await settleWithRealIo(tester);
      expect(runtime.solved, isEmpty);
      expect(find.text(t.manga_source_cloudflare_verify_title), findsOneWidget);
      await tester.ensureVisible(
        find.text(t.manga_source_cloudflare_verify_title),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.manga_source_cloudflare_verify_title));
      await tester.pump();
      await settleWithRealIo(tester);
      expect(
        runtime.solved.single,
        Uri.parse('https://fixture.invalid/challenge'),
      );
      expect(runtime.detailsCalls, 2);
      expect(find.text('Chapter 1'), findsOneWidget);
    },
  );

  testWidgets(
    'global search leaves challenge idle until user verifies and retries source',
    (WidgetTester tester) async {
      runtime.searchFailure = MihonCloudflareChallengeException(
        Uri.parse('https://fixture.invalid/search'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MangaGlobalSearchPage(
            mihonManager: manager,
            mihonSources: manager.sources,
            initialQuery: 'fixture',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(runtime.solved, isEmpty);
      expect(runtime.searchCalls, 1);
      await tester.tap(find.text(t.manga_source_cloudflare_verify_title));
      await tester.pumpAndSettle();
      expect(
        runtime.solved.single,
        Uri.parse('https://fixture.invalid/search'),
      );
      expect(runtime.searchCalls, 2);
      expect(find.text(t.manga_source_cloudflare_verify_title), findsNothing);
    },
  );

  testWidgets('a stale initial response cannot replace a newer search result', (
    WidgetTester tester,
  ) async {
    runtime.popularGate = Completer<MihonMangaPage>();
    runtime.searchGate = Completer<MihonMangaPage>();
    await tester.pumpWidget(
      MaterialApp(
        home: MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(manager.sources.single),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'new query');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    runtime.searchGate!.complete(
      const MihonMangaPage(
        items: <MihonManga>[
          MihonManga(url: '/manga/new', title: 'New search result'),
        ],
        hasNextPage: false,
      ),
    );
    await tester.pump();
    expect(find.text('New search result'), findsOneWidget);

    runtime.popularGate!.complete(
      const MihonMangaPage(
        items: <MihonManga>[
          MihonManga(url: '/manga/old', title: 'Stale popular result'),
        ],
        hasNextPage: false,
      ),
    );
    await tester.pump();
    expect(find.text('New search result'), findsOneWidget);
    expect(find.text('Stale popular result'), findsNothing);
  });

  testWidgets('a duplicate-only next page terminates pagination', (
    WidgetTester tester,
  ) async {
    runtime.popularPages = <int, MihonMangaPage>{
      1: const MihonMangaPage(
        items: <MihonManga>[_BrowseRuntime.manga],
        hasNextPage: true,
      ),
      2: const MihonMangaPage(
        items: <MihonManga>[_BrowseRuntime.manga],
        hasNextPage: true,
      ),
    };
    await tester.pumpWidget(
      MaterialApp(
        home: MihonSourceBrowsePage(
          manager: manager,
          target: MihonInstalledTarget(manager.sources.single),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Raw Otaku fixture'), findsOneWidget);

    // M3E：「加载更多」改成 filledTonal 图标按钮（MyComicIcons.add），按它的稳定
    // key 定位，不绑定具体图标码点。
    final Finder loadMore = find.byKey(
      const ValueKey<String>('mihon_browse_more'),
    );
    await tester.tap(loadMore);
    await tester.pump();
    await tester.pump();

    expect(find.text('Raw Otaku fixture'), findsOneWidget);
    expect(loadMore, findsNothing);
  });

  testWidgets(
    'open on website joins the source baseUrl with the manga url when the '
    'runtime cannot ask the extension',
    (WidgetTester tester) async {
      // 运行时是纯 Fake（没有 MihonWebUrlRuntime 能力）→ 走 baseUrl + url 兜底。
      await database.replaceMangaOnlineSources(
        'org.example.fixture',
        <MangaOnlineSourcesCompanion>[
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'org.example.fixture',
            sourceId: '9223372036854775807',
            name: 'Raw Otaku',
            language: 'en',
            baseUrl: const Value('https://fixture.invalid'),
          ),
        ],
      );
      await manager.reload();
      final List<Uri> launched = <Uri>[];
      await tester.pumpWidget(
        testApp(
          MihonMangaDetailPage(
            manager: manager,
            sourceContext: await manager.contextForSource(
              manager.sources.single,
            ),
            manga: _BrowseRuntime.manga,
            openExternal: (Uri url) async => launched.add(url),
          ),
        ),
      );
      await tester.pump();
      await settleWithRealIo(tester);
      // M3E 详情骨架：「在网站打开」在 hero 的「⋯」菜单里。
      await tester.tap(find.byKey(const ValueKey<String>('online_work_more')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_open_website')),
      );
      await tester.pumpAndSettle();
      expect(launched, <Uri>[
        Uri.parse('https://fixture.invalid/manga/fixture'),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  // ---- 04：来源浏览页的「初始关键词 + 自动搜索」入口 ----

  testWidgets(
    'an initial query fills the source search box and searches automatically',
    (WidgetTester tester) async {
      runtime.searchPages = <int, MihonMangaPage>{
        1: const MihonMangaPage(
          items: <MihonManga>[
            MihonManga(url: '/manga/hit', title: 'Fixture hit'),
          ],
          hasNextPage: false,
        ),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
            initialQuery: 'fixture',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'fixture',
      );
      expect(runtime.searchCalls, 1);
      expect(runtime.lastSearchQuery, 'fixture');
      expect(runtime.lastSearchPage, 1);
      expect(find.text('Fixture hit'), findsOneWidget);
    },
  );

  testWidgets(
    'an initial query result shows the full source page and paginates on demand',
    (WidgetTester tester) async {
      runtime.searchPages = <int, MihonMangaPage>{
        1: const MihonMangaPage(
          items: <MihonManga>[MihonManga(url: '/manga/one', title: 'Hit one')],
          hasNextPage: true,
        ),
        2: const MihonMangaPage(
          items: <MihonManga>[MihonManga(url: '/manga/two', title: 'Hit two')],
          hasNextPage: false,
        ),
      };
      await tester.pumpWidget(
        MaterialApp(
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
            initialQuery: 'fixture',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hit one'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey<String>('mihon_browse_more')));
      await tester.pumpAndSettle();

      expect(find.text('Hit two'), findsOneWidget);
      expect(runtime.lastSearchQuery, 'fixture');
      expect(runtime.lastSearchPage, 2);
    },
  );

  testWidgets(
    'without an initial query the source page keeps submit-to-search',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(runtime.searchCalls, 0, reason: '没有初始关键词时进页不搜索');
      expect(find.text('Raw Otaku fixture'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'manual query');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();

      expect(runtime.searchCalls, 1);
      expect(runtime.lastSearchQuery, 'manual query');
    },
  );

  // ---- 04：聚合搜索结果的「查看全部」 ----

  String viewAllKey(MangaOnlineSourceRow row) =>
      'manga_global_search_view_all_mihon:'
      '${row.extensionPackage}:${row.sourceId}';

  Widget globalSearchPage() => MaterialApp(
    home: MangaGlobalSearchPage(
      mihonManager: manager,
      mihonSources: manager.sources,
      initialQuery: 'fixture',
    ),
  );

  testWidgets(
    'every aggregate section shows view all while its source is loading',
    (WidgetTester tester) async {
      await database.replaceMangaOnlineSources(
        'org.example.fixture',
        <MangaOnlineSourcesCompanion>[
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'org.example.fixture',
            sourceId: '9223372036854775807',
            name: 'Raw Otaku',
            language: 'en',
          ),
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'org.example.fixture',
            sourceId: '42',
            name: 'Second source',
            language: 'en',
          ),
        ],
      );
      await manager.reload();
      runtime.searchGate = Completer<MihonMangaPage>();

      await tester.pumpWidget(globalSearchPage());
      await tester.pump();

      expect(manager.sources, hasLength(2));
      for (final MangaOnlineSourceRow row in manager.sources) {
        expect(
          find.byKey(ValueKey<String>(viewAllKey(row))),
          findsOneWidget,
          reason: '加载中也要有「查看全部」：${row.name}',
        );
      }

      runtime.searchGate!.complete(
        const MihonMangaPage(items: <MihonManga>[], hasNextPage: false),
      );
      await tester.pumpAndSettle();
    },
  );

  testWidgets('view all stays visible when a source returns no results', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(globalSearchPage());
    await tester.pumpAndSettle();

    expect(find.text(t.mihon_source_no_results), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>(viewAllKey(manager.sources.single))),
      findsOneWidget,
    );
  });

  testWidgets('view all stays visible when a source search fails', (
    WidgetTester tester,
  ) async {
    runtime.searchFailure = Exception('fixture failure');
    await tester.pumpWidget(globalSearchPage());
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>(viewAllKey(manager.sources.single))),
      findsOneWidget,
    );
  });

  testWidgets(
    'view all opens that source search prefilled and auto-run, and back keeps '
    'the aggregate results',
    (WidgetTester tester) async {
      runtime.searchPages = <int, MihonMangaPage>{
        1: const MihonMangaPage(
          items: <MihonManga>[
            MihonManga(url: '/manga/hit', title: 'Fixture hit'),
          ],
          hasNextPage: false,
        ),
      };
      await tester.pumpWidget(globalSearchPage());
      await tester.pumpAndSettle();

      expect(runtime.searchCalls, 1, reason: '聚合页自身先搜了一轮');
      await tester.tap(
        find.byKey(ValueKey<String>(viewAllKey(manager.sources.single))),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MihonSourceBrowsePage), findsOneWidget);
      expect(runtime.searchCalls, 2, reason: '来源页进页后要自动执行搜索');
      expect(runtime.lastSearchQuery, 'fixture');
      expect(runtime.lastSearchPage, 1);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'fixture',
      );
      expect(find.text('Fixture hit'), findsWidgets);

      Navigator.of(tester.element(find.byType(MihonSourceBrowsePage))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(MangaGlobalSearchPage), findsOneWidget);
      expect(
        find.byKey(ValueKey<String>(viewAllKey(manager.sources.single))),
        findsOneWidget,
      );
      expect(
        find.text('Fixture hit'),
        findsOneWidget,
        reason: '返回后聚合页原有结果必须还在',
      );
    },
  );
}

class _BrowseRuntime extends Fake
    implements MihonRuntime, ChallengeMihonRuntime {
  final List<Uri> solved = <Uri>[];
  Exception? searchFailure;
  int searchCalls = 0;
  String? lastSearchQuery;
  int? lastSearchPage;

  /// 非空时搜索第 N 页返回这里的结果；空时沿用 [searchGate] / 空结果。
  Map<int, MihonMangaPage>? searchPages;

  @override
  Future<void> solveCloudflare(Uri uri, {String? userAgent}) async {
    solved.add(uri);
    detailsFailure = null;
    searchFailure = null;
  }

  static const MihonManga manga = MihonManga(
    url: '/manga/fixture',
    title: 'Raw Otaku fixture',
  );
  Completer<MihonMangaPage>? popularGate;
  Completer<MihonMangaPage>? searchGate;
  Map<int, MihonMangaPage>? popularPages;

  /// 非空时 [getDetails] 抛它，用来驱动详情页的失败态。
  Exception? detailsFailure;
  int detailsCalls = 0;

  @override
  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => const <MihonFilter>[];

  @override
  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => popularGate != null
      ? popularGate!.future
      : popularPages?[page] ??
            const MihonMangaPage(
              items: <MihonManga>[manga],
              hasNextPage: false,
            );

  @override
  Future<MihonMangaPage> search(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    required String query,
    List<MihonFilter> filters = const <MihonFilter>[],
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    searchCalls++;
    lastSearchQuery = query;
    lastSearchPage = page;
    if (searchFailure != null) throw searchFailure!;
    return searchGate?.future ??
        searchPages?[page] ??
        const MihonMangaPage(items: <MihonManga>[], hasNextPage: false);
  }

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    detailsCalls++;
    final Exception? failure = detailsFailure;
    if (failure != null) throw failure;
    return const MihonManga(
      url: '/manga/fixture',
      title: 'Raw Otaku fixture',
      author: 'Fixture author',
      description: 'Fixture description',
      initialized: true,
    );
  }

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => List<MihonChapter>.generate(
    486,
    (int index) => MihonChapter(
      url: '/chapter/${index + 1}',
      name: 'Chapter ${index + 1}',
      uploadedAt: index,
      number: index + 1,
    ),
    growable: false,
  );

  @override
  Future<void> dispose() async {}
}
