// 复习模块（ModuleId.srs）的出厂默认与门控。
//
// my-comic 只保留漫画域（ModuleId.isInMyComicScope）：复习的枚举值、持久化键与
// 映射表仍在（旧备份 / 旧数据解析不炸），但可见性合成永远排除它。安装判定
// `settleSrsMiningTargetInstallDefault` 已不被 `AppModel.initialise()` 调用——
// 它要读的 mined_sentences / pending_mine_queue 不在漫画-only schema 里。
//
// - 出厂默认：ModuleId.defaultEnabled 全开（值域契约，不代表可见）；
// - 底栏 / 侧栏：无论模块开关是什么，都没有「复习」tab；
// - 挂真的 HomePage：旧偏好写着开也不出现复习、不弹任何引导 / 提示。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/settings/settings_schema_appearance.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../helpers/test_platform_services.dart';

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

  // isFirstTimeSetup / onboardingCompleted 不覆写：读真偏好，HomePage 首帧据它们决定
  // 弹不弹引导——「老用户不提醒」的断言要的正是这条真实路径。
}

class _Harness {
  _Harness(this.app, this.prefs);

  final _HostAppModel app;
  final PreferencesRepository prefs;
}

/// 挂真 HomePage：内存库 + 可选的旧偏好播种。
///
/// my-comic：`AppModel.initialise()` 不再调用
/// `settleSrsMiningTargetInstallDefault`（它要读的 mined_sentences /
/// pending_mine_queue 不在漫画-only schema 里），所以这里也不再跑那次判定。
Future<_Harness> _pumpHome(
  WidgetTester tester, {
  Future<void> Function(PreferencesRepository prefs)? seed,
}) async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await tester.runAsync(() async {
    await prefsRepo.loadFromDb();
    await seed?.call(prefsRepo);
  });
  final Directory tmpDir = Directory.systemTemp.createTempSync(
    'fushi_srs_gating_',
  );
  addTearDown(() {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  });
  final _HostAppModel appModel = _HostAppModel(tmpDir)
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tmpDir)
    ..wireDatabaseForTesting(db);
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
        appProvider.overrideWith((ref) => appModel),
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
  return _Harness(appModel, prefsRepo);
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    UpdateChecker.disableAutoCheckForTesting = true;
    DesktopLookupService.instance.debugReset();
  });

  tearDown(() {
    UpdateChecker.disableAutoCheckForTesting = false;
    DesktopLookupService.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  group('出厂默认', () {
    test('出厂默认全开（含复习），复习五端都存在（不是商店受限能力）', () {
      for (final ModuleId m in ModuleId.values) {
        expect(m.defaultEnabled, isTrue, reason: '$m');
      }
      for (final (bool w, bool d, bool i, bool a) p
          in <(bool, bool, bool, bool)>[
            (true, true, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
          ]) {
        expect(
          ModuleId.srs.availableOn(
            isWindows: p.$1,
            isDesktop: p.$2,
            isIOS: p.$3,
            isAndroid: p.$4,
          ),
          isTrue,
        );
      }
    });

    test('my-comic 不接线安装判定：复习开关可读写，但可见性永远排除它', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      // 安装判定（settle*）已随非漫画域移除：它要读的两张表不在漫画-only
      // schema 里。判定前仍按关读，显式写入后按写入值读。
      expect(repo.moduleEnabled(ModuleId.srs), isFalse, reason: '判定前按关');
      await repo.setModuleEnabled(ModuleId.srs, true);
      expect(repo.moduleEnabled(ModuleId.srs), isTrue);
      final ModuleVisibility visibility = ModuleVisibility.resolve(
        prefOf: repo.moduleEnabled,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
      );
      expect(
        visibility.isEnabled(ModuleId.srs),
        isFalse,
        reason: 'isInMyComicScope 只保留 manga / browse，开关开着也不可见',
      );
      repo.dispose();
      await db.close();
    });

    test('偏好未就绪的 AppModel 同样判关（不 fail-open 露出复习）', () {
      final AppModel app = AppModel(testPlatformServices());
      expect(app.moduleEnabled(ModuleId.srs), isFalse);
      expect(app.moduleEnabled(ModuleId.books), isTrue);
    });

    // 复习有底栏 tab，所以它的开关在「导航模块」拖拽列表里（#2198 起有 tab 的
    // 模块不再是独立开关行）；列表行副标题与无 tab 开关行共用 moduleSwitchHint。
    test('外观 → 功能模块：复习在导航模块列表里，并说明它是什么', () {
      expect(homeTabOfModule(ModuleId.srs), HomeTab.srs);
      expect(moduleNavIdentity(ModuleId.srs).label, t.nav_srs);
      expect(moduleSwitchHint(ModuleId.srs), t.srs_module_switch_hint);
      expect(moduleSwitchHint(ModuleId.books), isNull);
    });

    test('新手引导不提供复习方格（由「复习方式」一步写入）', () {
      expect(onboardingFeatureOfModule(ModuleId.srs), isNull);
    });
  });

  group('导航', () {
    test('关着没有复习 tab；打开后紧跟查词（值域映射仍在）', () {
      final ModuleVisibility off = ModuleVisibility(
        ModuleId.values.toSet()..remove(ModuleId.srs),
      );
      expect(homeActiveTabs(off), isNot(contains(HomeTab.srs)));
      final ModuleVisibility on = ModuleVisibility(ModuleId.values.toSet());
      final List<HomeTab> tabs = homeActiveTabs(on);
      expect(tabs.indexOf(HomeTab.srs), tabs.indexOf(HomeTab.dictionaries) + 1);
      // 映射表仍保留（值域 / 备份解析不炸），只是可见性合成时不启用。
      expect(moduleOfHomeTab(HomeTab.srs), ModuleId.srs);
      expect(homeTabOfModule(ModuleId.srs), HomeTab.srs);
      expect(homeNavItemFor(HomeTab.srs).label, t.nav_srs);
    });

    testWidgets('真 HomePage：老用户升级后看不到复习、不弹任何引导或提示（my-comic）', (
      WidgetTester tester,
    ) async {
      final _Harness h = await _pumpHome(
        tester,
        seed: (PreferencesRepository prefs) async {
          // 老用户：首页跑过、引导完成过；旧库里还存着「复习开着」。
          await prefs.setPref('first_time_setup', false);
          await prefs.setOnboardingCompleted(value: true);
          await prefs.setModuleEnabled(ModuleId.srs, true);
        },
      );
      expect(
        find.text(t.nav_srs),
        findsNothing,
        reason: 'my-comic 只保留漫画域：旧偏好开着也不能把复习塞进导航',
      );
      // 「老用户不提醒」：不弹引导、对话框 / 底部弹层 / 横幅，也不把引导重新
      // 标回待完成。
      expect(find.byType(OnboardingWizardPage), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(h.prefs.getPref('onboarding_completed'), isTrue);
      expect(h.prefs.getPref('first_time_setup'), isFalse);
      expect(h.app.srsMiningTarget, SrsMiningTarget.anki);

      // 运行期再写一次开关，导航仍然不出现复习。
      await tester.runAsync(() => h.app.setModuleEnabled(ModuleId.srs, true));
      await _settle(tester);
      expect(find.text(t.nav_srs), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
    });
  });
}
