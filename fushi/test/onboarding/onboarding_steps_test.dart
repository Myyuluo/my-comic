import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// Ticket 07：三步漫画版新手引导的纯逻辑契约。
///
/// 用户可见行为：
///  - 首次启动的步骤序列恒为「欢迎 → 内容文件夹 → 完成」；
///  - 新装用户（`first_time_setup` 默认 true、`onboarding_completed` 默认 false）
///    才会看到引导，已有用户升级上来不被打扰；
///  - 只有 Content root 真的变了，点「完成」才需要重启。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('步骤序列', () {
    test('恒为 welcome → storage → finish 三步', () {
      expect(onboardingStepSequence(), <OnboardingStepId>[
        OnboardingStepId.welcome,
        OnboardingStepId.storage,
        OnboardingStepId.finish,
      ]);
    });

    test('每次返回新列表，调用方改动不会污染下一次', () {
      final List<OnboardingStepId> first = onboardingStepSequence();
      first.removeLast();
      expect(onboardingStepSequence(), hasLength(3));
    });
  });

  group('首次启动门控', () {
    test('全新安装：first_time_setup=true 且未完成 → 显示', () {
      expect(
        shouldShowOnboarding(firstTimeSetup: true, onboardingCompleted: false),
        isTrue,
      );
    });

    test('已有用户：first_time_setup=false（即使没有完成偏好）→ 不显示', () {
      expect(
        shouldShowOnboarding(firstTimeSetup: false, onboardingCompleted: false),
        isFalse,
      );
    });

    test('已完成：无论 first_time_setup 如何都不再显示', () {
      for (final bool firstTimeSetup in <bool>[true, false]) {
        expect(
          shouldShowOnboarding(
            firstTimeSetup: firstTimeSetup,
            onboardingCompleted: true,
          ),
          isFalse,
        );
      }
    });
  });

  group('Content root 变化判定（完成时是否重启）', () {
    test('同一路径不需要重启', () {
      expect(
        onboardingRequiresRestart(
          initialContentRoot: r'C:\Users\me\Documents\MyComic',
          selectedContentRoot: r'C:\Users\me\Documents\MyComic',
        ),
        isFalse,
      );
    });

    test('大小写 / 尾部分隔符差异不触发重启（Windows 路径等价）', () {
      expect(
        onboardingRequiresRestart(
          initialContentRoot: r'C:\Users\me\Documents\MyComic',
          selectedContentRoot: r'c:\users\me\documents\mycomic\',
        ),
        isFalse,
      );
    });

    test('选择不同目录需要重启', () {
      expect(
        onboardingRequiresRestart(
          initialContentRoot: r'C:\Users\me\Documents\MyComic',
          selectedContentRoot: r'D:\Manga',
        ),
        isTrue,
      );
    });

    test('先改到新目录再改回原目录 → 不需要重启', () {
      final String initial = p.canonicalize(r'C:\Users\me\Documents\MyComic');
      // 中间的“改了”不影响最终判据：完成时只比较起点与当前选择。
      expect(
        onboardingRequiresRestart(
          initialContentRoot: initial,
          selectedContentRoot: r'C:\Users\me\Documents\MyComic',
        ),
        isFalse,
      );
    });
  });

  group('Onboarding 完成偏好', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;
    late Directory tmp;

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      prefs = PreferencesRepository(db);
      tmp = Directory.systemTemp.createTempSync('onboarding_prefs_');
      await prefs.loadFromDb();
    });

    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('新装默认：first_time_setup=true、onboarding_completed=false', () {
      expect(prefs.isFirstTimeSetup, isTrue);
      expect(prefs.onboardingCompleted, isFalse);
    });

    test('完成引导同事务落两个标记：completed=true、first_time_setup=false', () async {
      await prefs.setOnboardingCompleted(value: true);

      expect(prefs.onboardingCompleted, isTrue);
      expect(prefs.isFirstTimeSetup, isFalse);
      expect(
        await prefs.getPref('onboarding_completed'),
        isTrue,
        reason: '偏好必须真的落盘，重启后不能再弹引导',
      );
    });

    test('AppModel.needsOnboarding 跟随两个标记', () async {
      final AppModel appModel = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tmp);

      expect(appModel.needsOnboarding, isTrue, reason: '全新安装应显示引导');

      await prefs.setPref('first_time_setup', false);
      expect(
        appModel.needsOnboarding,
        isFalse,
        reason: '已有用户升级上来即使没有完成偏好也不被打扰',
      );

      await prefs.setPref('first_time_setup', true);
      await prefs.setOnboardingCompleted(value: true);
      expect(appModel.needsOnboarding, isFalse, reason: '完成后不再显示');
    });
  });
}
