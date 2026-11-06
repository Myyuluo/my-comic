import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）：
///
/// - 内容：现有简单漫画下载任务卡片、没有任务时的空态、没有视图页签（真实页面
///   + 真实 37 表数据库）；
/// - 外壳：挂真 [HomePage] 验证固定展开标题、列表从标题下方开始、切走再回来
///   保留滚动位置（页面级行为测试，不扫源码）。
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

  group('下载页外壳（真 HomePage）', () {
    testWidgets('标题固定展开：滚动任务列表后仍显示「下载」大标题', (WidgetTester tester) async {
      await _pumpHome(tester, db);
      await _openDownloads(tester);

      final Finder titleBar = find.byType(FushiShellLargeTitleBar);
      final Finder shellTitle = find.descendant(
        of: titleBar,
        matching: find.text(t.nav_downloads),
      );
      expect(shellTitle, findsOneWidget, reason: '下载页顶部只有外壳画的「下载」标题');
      expect(
        tester.widget<FushiShellLargeTitleBar>(titleBar).collapsed,
        isFalse,
        reason: '下载页标题固定展开，不随滚动收起',
      );
      expect(
        find.descendant(
          of: find.byType(DownloadsPage),
          matching: find.byType(TabBar),
        ),
        findsNothing,
        reason: '下载页不显示任何视图页签',
      );

      // 列表第一张卡片完整位于标题下方（旧遮挡 bug 的回归判据）。
      final double titleBottom = tester.getBottomLeft(titleBar).dy;
      expect(
        tester.getTopLeft(find.byType(DownloadTaskCard).first).dy,
        greaterThanOrEqualTo(titleBottom),
        reason: '下载列表从标题下方开始，第一张卡片不被标题遮挡',
      );

      await tester.drag(
        find.descendant(
          of: find.byType(DownloadsPage),
          matching: find.byType(Scrollable),
        ),
        const Offset(0, -600),
      );
      await _settle(tester);

      expect(shellTitle, findsOneWidget, reason: '向下滚动时标题仍然可见');
      expect(
        tester.widget<FushiShellLargeTitleBar>(titleBar).collapsed,
        isFalse,
        reason: '向下滚动时标题仍保持展开',
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
  _HostAppModel(this._dir) : super(testPlatformServices());

  final Directory _dir;

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
Future<_HostAppModel> _pumpHome(WidgetTester tester, FushiDatabase db) async {
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
  final _HostAppModel appModel = _HostAppModel(tmpDir)
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
