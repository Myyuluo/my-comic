import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/pages.dart';
import 'package:my_comic/src/media/import/real_path_directory_picker.dart';
import 'package:my_comic/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/content_root_switch.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_platform_services.dart';

/// Ticket 07：三步漫画版新手引导的真页面行为。
///
/// 只验证用户看到/做到的事：三步顺序、欢迎步复用语言与明暗选择器、存储步展示
/// 三个最终路径、完成步只有说明与「完成」、以及「有变化才重启」的时机。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late AppPaths paths;
  late FakeLifecycleService lifecycle;
  late _TestOnboardingAppModel appModel;
  late GlobalKey<NavigatorState> navigatorKey;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('onboarding_wizard_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
    };
    lifecycle = FakeLifecycleService()..supportsRestartValue = true;
    debugRealDirectoryPathOverride = null;
    debugSwitchOnboardingContentRoot = null;
    navigatorKey = GlobalKey<NavigatorState>();
    LocaleSettings.setLocale(AppLocale.en);
  });

  tearDown(() {
    AppPaths.debugTestEnvironment = null;
    debugRealDirectoryPathOverride = null;
    debugSwitchOnboardingContentRoot = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpWizard(WidgetTester tester) async {
    await tester.runAsync(() async {
      paths = await AppPaths.resolve();
    });
    appModel = _TestOnboardingAppModel(paths, lifecycle: lifecycle);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async => call.method == 'isFocused' ? true : null,
    );
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((Ref ref) => appModel),
          platformServicesProvider.overrideWithValue(
            fakePlatformServices(
              lifecycle: lifecycle,
              isWindows: true,
              isDesktop: true,
            ),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pump();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const OnboardingWizardPage()),
    );
    await settle(tester);
  }

  Future<void> tapNext(WidgetTester tester) async {
    await tester.tap(find.text(t.onboarding_action_next));
    await settle(tester);
  }

  testWidgets('三步顺序：欢迎（语言/明暗）→ 内容文件夹 → 完成说明', (WidgetTester tester) async {
    await pumpWizard(tester);

    // 第一步：欢迎。复用外观设置的语言 / 明暗选择器。
    expect(find.text(t.onboarding_welcome_title), findsOneWidget);
    expect(find.text(t.onboarding_welcome_intro), findsOneWidget);
    expect(find.text(t.options_language), findsOneWidget);
    expect(find.text(t.dark_mode), findsOneWidget);
    expect(find.text('Welcome to MyComic'), findsNothing, reason: '引导不得再出现上游品牌');

    await tapNext(tester);

    // 第二步：只选一个 Content root，并展示三个最终路径。
    expect(find.text(t.onboarding_storage_title), findsOneWidget);
    expect(find.text(t.onboarding_storage_content_root_label), findsOneWidget);
    expect(find.text(paths.contentRoot.path), findsOneWidget);
    for (final String name in <String>[
      AppPaths.downloadsDirName,
      AppPaths.autobackupDirName,
      AppPaths.localComicDirName,
    ]) {
      expect(
        find.text(p.join(paths.contentRoot.path, name)),
        findsOneWidget,
        reason: '必须展示 $name 的最终路径',
      );
    }
    expect(find.text(t.onboarding_storage_choose_button), findsOneWidget);

    await tapNext(tester);

    // 第三步：只有 Mihon 兼容说明与「完成」；不出现下一步 / 跳过 / 操作按钮。
    expect(find.text(t.onboarding_finish_title), findsOneWidget);
    expect(find.text(t.onboarding_finish_mihon_body), findsOneWidget);
    expect(
      t.onboarding_finish_mihon_body,
      contains('Mihon-compatible'),
      reason: '完成页文案必须是「Mihon 兼容」，不能写成官方桌面版',
    );
    expect(find.text(t.onboarding_action_finish), findsOneWidget);
    expect(find.text(t.onboarding_action_next), findsNothing);
    expect(find.text(t.onboarding_action_skip), findsNothing);
  });

  testWidgets('不换 Content root：点「完成」不重启，并落完成偏好', (WidgetTester tester) async {
    await pumpWizard(tester);
    await tapNext(tester);
    await tapNext(tester);

    await tester.tap(find.text(t.onboarding_action_finish));
    await settle(tester);

    expect(lifecycle.restartCalled, isFalse, reason: '目录没变就不该重启');
    expect(appModel.onboardingCompleted, isTrue);
    expect(appModel.isFirstTimeSetup, isFalse);
    expect(find.byType(OnboardingWizardPage), findsNothing, reason: '完成后关闭引导');
  });

  testWidgets('换 Content root：存储步即时展示新路径，点「完成」才重启', (
    WidgetTester tester,
  ) async {
    await pumpWizard(tester);
    final Directory target = Directory(p.join(tmp.path, 'NewContent'));
    debugRealDirectoryPathOverride = target.path;
    debugSwitchOnboardingContentRoot =
        (AppModel appModel, String picked) async {
          // 生产路径由 ContentRootSwitch 创建三个空目录并写偏好；它的校验/建目录
          // 行为已有独立测试，这里只验证向导的接线与重启时机。
          return ContentRootSwitchResult.success(Directory(picked));
        };

    await tapNext(tester);
    await tester.tap(find.text(t.onboarding_storage_choose_button));
    await settle(tester);

    // 选择后只更新展示与偏好，不立即重启。
    expect(lifecycle.restartCalled, isFalse);
    expect(find.text(target.path), findsOneWidget);
    for (final String name in <String>[
      AppPaths.downloadsDirName,
      AppPaths.autobackupDirName,
      AppPaths.localComicDirName,
    ]) {
      expect(find.text(p.join(target.path, name)), findsOneWidget);
    }

    await tapNext(tester);
    await tester.tap(find.text(t.onboarding_action_finish));
    await settle(tester);

    expect(lifecycle.restartCalled, isTrue, reason: 'Content root 变了，完成时必须重启');
    expect(appModel.onboardingCompleted, isTrue);
  });

  testWidgets('选择后又改回原目录：完成时不重启', (WidgetTester tester) async {
    await pumpWizard(tester);
    final Directory target = Directory(p.join(tmp.path, 'NewContent'));
    debugRealDirectoryPathOverride = target.path;
    debugSwitchOnboardingContentRoot =
        (AppModel appModel, String picked) async =>
            ContentRootSwitchResult.success(Directory(picked));

    await tapNext(tester);
    await tester.tap(find.text(t.onboarding_storage_choose_button));
    await settle(tester);
    expect(find.text(target.path), findsOneWidget);

    // 再选回原目录：最终选择 == 起始目录，不应重启。
    debugRealDirectoryPathOverride = paths.contentRoot.path;
    await tester.tap(find.text(t.onboarding_storage_choose_button));
    await settle(tester);
    expect(find.text(paths.contentRoot.path), findsOneWidget);

    await tapNext(tester);
    await tester.tap(find.text(t.onboarding_action_finish));
    await settle(tester);

    expect(lifecycle.restartCalled, isFalse);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _TestOnboardingAppModel extends AppModel {
  _TestOnboardingAppModel(
    this._paths, {
    required FakeLifecycleService lifecycle,
  }) : super(
         fakePlatformServices(
           lifecycle: lifecycle,
           isWindows: true,
           isDesktop: true,
         ),
       );

  final AppPaths _paths;

  bool _onboardingCompleted = false;
  bool _firstTimeSetup = true;

  @override
  AppPaths get appPaths => _paths;

  @override
  AppPaths? get appPathsOrNull => _paths;

  @override
  bool get isFirstTimeSetup => _firstTimeSetup;

  @override
  bool get onboardingCompleted => _onboardingCompleted;

  @override
  Future<void> setOnboardingCompleted({required bool value}) async {
    _onboardingCompleted = value;
    if (value) _firstTimeSetup = false;
  }

  @override
  Locale get appLocale => const Locale('en');

  @override
  Future<void> setAppLocale(String localeTag) async {}

  @override
  String get brightnessMode => 'system';

  @override
  Future<void> setBrightnessMode(String mode) async {}
}
