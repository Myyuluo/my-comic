import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/downloads/download_source_method.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart' show buildFushiThemeData;
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart'
    show FushiSectionTabBar;
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）：
///
/// - 内容：现有简单漫画下载任务卡片、没有任务时的空态、没有视图页签（真实页面
///   + 真实 37 表数据库）；
/// - 标题：挂真 [HomePage] 验证下载页标题是浏览页同款的页内浮动标题胶囊——
///   下滚隐藏、上滚 / 回顶显示，首张卡片从标题下方开始；MD3 窄窗不显示标题，
///   Apple / 玻璃设计交给外壳大标题收起（页面级行为测试，不扫源码）；
/// - 保活：切走再回来保留滚动位置。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late MangaDownloadService downloads;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    downloads = MangaDownloadService(
      database: db,
      // 本测试只读任务列表，不会触发下载 worker。
      serviceFor: (OnlineMangaRuntimeKind _) =>
          throw UnimplementedError('下载 worker 不应在本测试中运行'),
    );
  });

  tearDown(() {
    downloads.dispose();
    return db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadsPage(downloadsOverride: downloads)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> insertTask({
    FushiDatabase? database,
    String jobId = 'job-1',
    String title = '某作品',
    String chapterTitle = '第 1 话',
    String status = MangaDownloadJobStatus.queued,
    int createdAt = 1,
  }) async {
    await (database ?? db).upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: jobId,
        kind: MangaDownloadJobKind.chapter,
        bookKey: 'book-1',
        chapterKey: 'chapter-$jobId',
        runtime: 'mihon',
        title: title,
        chapterTitle: chapterTitle,
        status: Value<String>(status),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: createdAt,
        updatedAt: createdAt,
      ),
    );
  }

  group('下载页内容', () {
    testWidgets('没有下载任务时显示空态提示', (WidgetTester tester) async {
      await pumpPage(tester);

      expect(find.text(t.downloads_page_no_tasks), findsOneWidget);
      expect(find.byType(DownloadTaskCard), findsNothing);
    });

    testWidgets('有任务时显示与原先相同的任务卡片', (WidgetTester tester) async {
      await insertTask();
      await pumpPage(tester);

      expect(find.byType(DownloadTaskCard), findsOneWidget);
      expect(find.text('第 1 话'), findsOneWidget);
      expect(find.textContaining('某作品'), findsOneWidget);
      expect(find.text(t.downloads_page_no_tasks), findsNothing);
    });

    testWidgets('页面内不显示视图页签', (WidgetTester tester) async {
      await insertTask();
      await pumpPage(tester);

      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
    });
  });

  group('下载页简化的任务卡', () {
    testWidgets('不显示来源标签', (WidgetTester tester) async {
      // runtime 'mihon' 原本会渲染「扩展源」+「外部来源」两枚标签。
      await insertTask();
      await pumpPage(tester);

      expect(find.byType(DownloadTaskCard), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('download-method-extension')),
        findsNothing,
        reason: '下载页不再显示传输方式标签',
      );
      expect(
        find.byKey(const ValueKey<String>('download-source-external')),
        findsNothing,
        reason: '下载页不再显示外部来源标签',
      );
      expect(find.text(t.download_method_extension), findsNothing);
      expect(find.text(t.download_source_external), findsNothing);
    });

    testWidgets('不可展开：没有展开箭头，整行点击不展开', (WidgetTester tester) async {
      await insertTask();
      await pumpPage(tester);

      final Finder card = find.byType(DownloadTaskCard);
      expect(
        find.descendant(of: card, matching: find.byIcon(FushiIcons.expandMore)),
        findsNothing,
        reason: '简化卡片不画展开箭头',
      );

      // 折叠态只有卡片标题（章节名）与副标题（作品名）；展开后的详情行标题是
      // 「作品 · 章节」。
      expect(find.text('某作品 · 第 1 话'), findsNothing);
      await tester.tap(find.text('第 1 话'));
      await tester.pumpAndSettle();
      expect(find.text('某作品 · 第 1 话'), findsNothing, reason: '点整行不应展开出详情');
    });

    testWidgets('排队中与下载中的行尾可直接取消', (WidgetTester tester) async {
      await insertTask(
        jobId: 'job-queued',
        status: MangaDownloadJobStatus.queued,
        createdAt: 1,
      );
      await insertTask(
        jobId: 'job-running',
        status: MangaDownloadJobStatus.running,
        createdAt: 2,
      );
      await pumpPage(tester);

      final Finder cancel = find.byTooltip(t.dialog_cancel);
      expect(cancel, findsNWidgets(2), reason: '排队中与下载中的行尾都有取消图标');

      await tester.tap(cancel.first);
      await tester.pumpAndSettle();

      expect(
        (await db.getMangaDownloadJob('job-queued'))?.status,
        MangaDownloadJobStatus.cancelled,
        reason: '点取消直接调用现有取消能力',
      );
      expect(
        find.byTooltip(t.dialog_cancel),
        findsOneWidget,
        reason: '已取消的行换成重试图标',
      );

      await tester.tap(find.byTooltip(t.dialog_cancel));
      await tester.pumpAndSettle();

      expect(
        (await db.getMangaDownloadJob('job-running'))?.status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(find.byTooltip(t.dialog_cancel), findsNothing);
      expect(find.byTooltip(t.retry), findsNWidgets(2));
    });

    testWidgets('失败与已取消的行尾可直接重试', (WidgetTester tester) async {
      await insertTask(
        jobId: 'job-failed',
        status: MangaDownloadJobStatus.failed,
        createdAt: 1,
      );
      await insertTask(
        jobId: 'job-cancelled',
        status: MangaDownloadJobStatus.cancelled,
        createdAt: 2,
      );
      await pumpPage(tester);

      final Finder retry = find.byTooltip(t.retry);
      expect(retry, findsNWidgets(2), reason: '失败与已取消的行尾都有重试图标');

      await tester.tap(retry.first);
      await tester.pumpAndSettle();

      expect(
        (await db.getMangaDownloadJob('job-failed'))?.status,
        MangaDownloadJobStatus.queued,
        reason: '点重试直接调用现有重试能力',
      );
      expect(
        (await db.getMangaDownloadJob('job-cancelled'))?.status,
        MangaDownloadJobStatus.cancelled,
      );
      expect(
        find.byTooltip(t.dialog_cancel),
        findsOneWidget,
        reason: '重试后该行变回排队中，行尾换成取消图标',
      );
      expect(find.byTooltip(t.retry), findsOneWidget);
    });

    testWidgets('已完成的行不显示行尾操作', (WidgetTester tester) async {
      await insertTask(status: MangaDownloadJobStatus.done);
      await pumpPage(tester);

      expect(find.byType(DownloadTaskCard), findsOneWidget);
      expect(find.byTooltip(t.retry), findsNothing);
      expect(find.byTooltip(t.dialog_cancel), findsNothing);
      expect(
        find.descendant(
          of: find.byType(DownloadTaskCard),
          matching: find.byIcon(Icons.close),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(DownloadTaskCard),
          matching: find.byIcon(Icons.refresh),
        ),
        findsNothing,
      );
    });
  });

  group('共享任务卡默认模式（其它调用点）', () {
    testWidgets('仍显示来源标签、可展开且展开后显示详情', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadTaskCard(
              taskId: 'shared-task',
              title: 'Shared task',
              status: 'Downloading',
              method: DownloadTransferMethod.extension,
              externalSource: true,
              details: const Text('shared-details'),
            ),
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey<String>('download-method-extension')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('download-source-external')),
        findsOneWidget,
      );
      expect(find.byIcon(FushiIcons.expandMore), findsOneWidget);

      await tester.tap(find.text('Shared task'));
      await tester.pumpAndSettle();
      expect(
        find.text('shared-details'),
        findsOneWidget,
        reason: '默认模式仍可展开；简化模式只影响下载页',
      );
    });
  });

  group('下载页外壳（真 HomePage）', () {
    testWidgets('标题是浏览页同款浮动标题胶囊：首卡从标题下方开始，页内无视图页签', (
      WidgetTester tester,
    ) async {
      await _pumpHome(tester, db);
      await _openDownloads(tester);

      final Finder page = find.byType(DownloadsPage);
      final Finder bar = find.descendant(
        of: page,
        matching: find.byType(FushiFloatingChromeBar),
      );
      final Finder titleCapsule = find.descendant(
        of: page,
        matching: find.byKey(
          const ValueKey<String>('floating-chrome-shell-title'),
        ),
      );
      expect(bar, findsOneWidget, reason: '下载页有自己的页内浮动工具区条');
      expect(titleCapsule, findsOneWidget, reason: '工具区条里画「下载」标题胶囊');
      expect(
        find.descendant(of: titleCapsule, matching: find.text(t.nav_downloads)),
        findsOneWidget,
      );
      expect(
        find.byType(FushiShellLargeTitleBar),
        findsNothing,
        reason: '不再使用外壳固定展开的大标题',
      );
      expect(
        find.descendant(of: page, matching: find.byType(TabBar)),
        findsNothing,
        reason: '下载页不显示任何视图页签',
      );
      expect(
        find.descendant(
          of: page,
          matching: find.byWidgetPredicate(
            (Widget widget) => widget is FushiSectionTabBar,
            description: 'FushiSectionTabBar',
          ),
        ),
        findsNothing,
        reason: '浮动工具区里只有标题胶囊，没有视图页签',
      );

      // 列表第一张卡片完整位于标题（工具区条）下方（旧遮挡 bug 的回归判据）。
      final double titleBottom = tester.getBottomLeft(titleCapsule).dy;
      final double barBottom = tester.getBottomLeft(bar).dy;
      final double cardTop = tester
          .getTopLeft(find.byType(DownloadTaskCard).first)
          .dy;
      expect(
        cardTop,
        greaterThanOrEqualTo(titleBottom),
        reason: '下载列表从标题下方开始，第一张卡片不被标题遮挡',
      );
      expect(
        cardTop,
        greaterThanOrEqualTo(barBottom),
        reason: '首卡在浮动工具区条下方，不钻到条底下',
      );
      await _unmount(tester);
    });

    testWidgets('向下滚动隐藏标题，向上滚动或回到顶部重新显示', (WidgetTester tester) async {
      await _pumpHome(tester, db);
      await _openDownloads(tester);

      final Finder list = find
          .descendant(
            of: find.byType(DownloadsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      Finder titleText() => find.descendant(
        of: find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
        matching: find.text(t.nav_downloads),
      );
      final double cardTopAtRest = tester
          .getTopLeft(find.byType(DownloadTaskCard).first)
          .dy;

      expect(titleText().hitTestable(), findsOneWidget, reason: '初始标题可见');

      // 下滚：标题随工具区收起；列表内容继续上移，原来的标题位置不留空白条。
      await tester.drag(list, const Offset(0, -600));
      await _settle(tester);
      expect(titleText().hitTestable(), findsNothing, reason: '向下滚动时标题隐藏');
      expect(
        tester.getTopLeft(titleText()).dy,
        lessThan(0),
        reason: '标题滑出视口顶部，而不是原地留一条空白',
      );
      expect(
        tester.getTopLeft(find.byType(DownloadTaskCard).first).dy,
        lessThan(cardTopAtRest),
        reason: '标题隐藏后列表内容继续上移',
      );
      expect(
        find.byType(DownloadTaskCard).hitTestable(),
        findsWidgets,
        reason: '标题原来占据的顶部区域由列表内容覆盖',
      );

      // 上滚：标题重新出现。
      await tester.drag(list, const Offset(0, 300));
      await _settle(tester);
      expect(titleText().hitTestable(), findsOneWidget, reason: '向上滚动时标题重新显示');
      expect(tester.getTopLeft(titleText()).dy, greaterThanOrEqualTo(0));

      // 再下滚隐藏，然后回到顶部：标题重新显示。
      await tester.drag(list, const Offset(0, -600));
      await _settle(tester);
      expect(titleText().hitTestable(), findsNothing);
      await tester.drag(list, const Offset(0, 2000));
      await _settle(tester);
      expect(
        titleText().hitTestable(),
        findsOneWidget,
        reason: '回到列表顶部时标题重新显示',
      );
      await _unmount(tester);
    });

    testWidgets('MD3 窄窗口与浏览页一样不显示页面标题', (WidgetTester tester) async {
      await _pumpHome(
        tester,
        db,
        physicalSize: const Size(500, 900),
        devicePixelRatio: 1,
      );
      await _openDownloads(tester);

      final Finder page = find.byType(DownloadsPage);
      expect(
        find.descendant(
          of: page,
          matching: find.byKey(
            const ValueKey<String>('floating-chrome-shell-title'),
          ),
        ),
        findsNothing,
        reason: '窄窗口没有页面标题胶囊',
      );
      expect(
        find.descendant(of: page, matching: find.text(t.nav_downloads)),
        findsNothing,
        reason: '标题只在底部导航里，页内不再画',
      );
      expect(find.byType(DownloadTaskCard), findsWidgets);
      await _unmount(tester);
    });

    testWidgets('Apple / 玻璃设计：隐藏页内工具区，标题随外壳大标题收起', (WidgetTester tester) async {
      await _pumpHome(
        tester,
        db,
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4F5B92)),
          textTheme: Typography.material2021().black,
          glassDesign: true,
        ),
      );
      await _openDownloads(tester);

      expect(
        find.descendant(
          of: find.byType(DownloadsPage),
          matching: find.byType(FushiFloatingChromeBar),
        ),
        findsNothing,
        reason: '玻璃设计与浏览页一样不画页内工具区',
      );

      final Finder titleBar = find.byType(FushiShellLargeTitleBar);
      expect(titleBar, findsOneWidget);
      expect(
        find.descendant(of: titleBar, matching: find.text(t.nav_downloads)),
        findsOneWidget,
        reason: '标题交给外壳大标题',
      );
      expect(
        tester.widget<FushiShellLargeTitleBar>(titleBar).collapsed,
        isFalse,
        reason: '初始展开',
      );

      await tester.drag(
        find
            .descendant(
              of: find.byType(DownloadsPage),
              matching: find.byType(Scrollable),
            )
            .first,
        const Offset(0, -600),
      );
      await _settle(tester);
      expect(
        tester.widget<FushiShellLargeTitleBar>(titleBar).collapsed,
        isTrue,
        reason: '向下滚动时外壳大标题收起',
      );
      await _unmount(tester);
    });

    testWidgets('切到其它一级页再回来：保留下载列表滚动位置', (WidgetTester tester) async {
      await _pumpHome(tester, db);
      await _openDownloads(tester);

      final Finder list = find
          .descendant(
            of: find.byType(DownloadsPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.drag(list, const Offset(0, -500));
      await _settle(tester);
      final double offset = tester.state<ScrollableState>(list).position.pixels;
      expect(offset, greaterThan(0), reason: '前置：列表确实滚下去了');

      HomePage.debugSelectTab!(HomeTab.manga);
      await _settle(tester);
      expect(find.byType(DownloadsPage), findsNothing);

      HomePage.debugSelectTab!(HomeTab.downloads);
      await _settle(tester);
      expect(
        tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(DownloadsPage),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position
            .pixels,
        closeTo(offset, 0.5),
        reason: '下载页保活：切走再回来保留滚动位置与任务列表状态',
      );
      await _unmount(tester);
    });
  });
}

/// 真 HomePage 测试的 AppModel：内存库 + 跳过首启引导 + 最少的平台桩。
class _HostAppModel extends AppModel {
  _HostAppModel(this._dir, this._paths) : super(testPlatformServices());

  final Directory _dir;
  final AppPaths _paths;

  // HomePage 的 initState 读 appPaths；测试壳不走 initialise()，必须显式注入
  // 解析好的路径（与其它 HomePage / 设置页测试同法）。
  @override
  AppPaths get appPaths => _paths;

  @override
  PackageInfo get packageInfo => PackageInfo(
    appName: 'Fushi',
    packageName: 'app.hibiki.reader',
    version: '1.0.0',
    buildNumber: '1',
  );

  @override
  Directory get appDirectory => _dir;

  @override
  Directory get temporaryDirectory => _dir;

  @override
  Directory get dictionaryResourceDirectory => _dir;

  @override
  Locale get appLocale => const Locale('en');

  @override
  void startUpdateChecks() {}

  @override
  bool get isDatabaseOpen => true;

  @override
  bool get isFirstTimeSetup => false;

  @override
  bool get onboardingCompleted => true;
}

/// 挂真 [HomePage]（与 `srs_module_gating_test` 同一套壳体测试环境），
/// 向下载页的任务列表预置足够多已完成的章节任务。
///
/// [physicalSize] / [devicePixelRatio] 用来切窗口尺寸档（窄窗验证 MD3 不画页面
/// 标题）；[theme] 用来切 Apple / 玻璃设计系统。
Future<_HostAppModel> _pumpHome(
  WidgetTester tester,
  FushiDatabase db, {
  Size? physicalSize,
  double devicePixelRatio = 1,
  ThemeData? theme,
}) async {
  if (physicalSize != null) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = devicePixelRatio;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_downloads_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  AppPaths.debugTestEnvironment = <String, String>{
    'FUSHI_TEST_ROOT': tmpDir.path,
  };
  addTearDown(() => AppPaths.debugTestEnvironment = null);
  // AppPaths.resolve() 做真实文件系统 IO；widget 测试体跑在 FakeAsync 里，必须
  // 用 runAsync 放回真实事件循环，否则 await 永远不返回。
  final AppPaths? resolvedPaths = await tester.runAsync(AppPaths.resolve);
  if (resolvedPaths == null) {
    throw StateError('AppPaths.resolve() 在测试环境中失败');
  }
  final _HostAppModel appModel = _HostAppModel(tmpDir, resolvedPaths)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db);
  for (int i = 0; i < 30; i++) {
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'job-$i',
        kind: MangaDownloadJobKind.chapter,
        bookKey: 'book-1',
        chapterKey: 'chapter-$i',
        runtime: 'mihon',
        title: 'Fixture series',
        chapterTitle: 'Chapter $i',
        // done：任务列表不启动 worker（本测试只验证列表与保活）。
        status: const Value<String>(MangaDownloadJobStatus.done),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: i,
        updatedAt: i,
      ),
    );
  }

  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('window_manager'),
    (MethodCall call) {
      if (call.method == 'isFocused') return Future<bool>.value(true);
      return Future<void>.value();
    },
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        platformServicesProvider.overrideWithValue(testPlatformServices()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: appModel.navigatorKey,
          theme: theme,
          home: const HomePage(),
        ),
      ),
    ),
  );
  await _settle(tester);
  // HomePage 启动后台更新检查会挂周期 Timer；挂载完成后显式停掉（幂等）。
  await appModel.stopUpdateChecks();
  expect(
    HomePage.debugSelectTab,
    isNotNull,
    reason: 'HomePage 必须已挂载并注册 debugSelectTab 生产钩子',
  );
  return appModel;
}

Future<void> _openDownloads(WidgetTester tester) async {
  HomePage.debugSelectTab!(HomeTab.downloads);
  await _settle(tester);
  expect(find.byType(DownloadsPage), findsOneWidget, reason: '下载页应作为一级导航页挂载');
  expect(find.byType(DownloadTaskCard), findsWidgets);
}

/// 有界推帧。整页 HomePage 挂着同步横幅 / 仪表盘动画与周期定时器，
/// `pumpAndSettle` 等不到静止，只能按固定帧数推进。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 断言做完后主动卸载：drift `.watch()` 在 ProviderScope dispose 时排零时长
/// Timer，留到测试结束会撞 `!timersPending` 不变式。
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(Duration.zero);
  await tester.pump(const Duration(milliseconds: 10));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
}
