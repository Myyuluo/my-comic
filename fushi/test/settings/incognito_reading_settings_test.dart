import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/sync/pref_redaction_policy.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// ticket 04：设置 → 系统与关于 → 更新提醒组末尾的「无痕阅读」开关。
///
/// 这里守用户可见的三件事：开关在正确分组末尾、默认关、文案来自 i18n；
/// 开关值真的落进设备本地偏好（默认 / 开 / 关都能往返）；该键绝不随
/// Profile 快照与备份出境（无痕是这台设备上的隐私选择，换设备按新设备走）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late SettingsContext settingsContext;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    resetSettingsSchemaCache();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_incognito_settings');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              settingsContext = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  SettingsSection updateNotificationsSection() =>
      buildSystemDestination().sections.firstWhere(
        (SettingsSection section) =>
            section.id == 'system.section.update_notifications',
      );

  testWidgets('更新提醒组末尾显示无痕阅读开关：默认关、文案正确', (WidgetTester tester) async {
    await pumpContext(tester);

    final SettingsItem item = updateNotificationsSection().items.last;
    expect(item, isA<SettingsSwitchItem>(), reason: '无痕阅读必须是更新提醒组的最后一行开关');
    final SettingsSwitchItem toggle = item as SettingsSwitchItem;
    expect(toggle.id, 'system.incognito_reading');
    expect(toggle.title, '无痕阅读');
    expect(toggle.subtitle, '暂停记录阅读历史');
    expect(toggle.defaultValue, isFalse, reason: '默认关闭 = 默认记录 History');
    expect(toggle.icon, FushiIcons.visibilityOff);
    expect(toggle.value(settingsContext), isFalse);
  });

  testWidgets('开关值写穿设备本地偏好，关闭后恢复记录 History', (WidgetTester tester) async {
    await pumpContext(tester);
    final SettingsSwitchItem toggle =
        updateNotificationsSection().items.last as SettingsSwitchItem;

    await toggle.onChanged(settingsContext, true);
    expect(toggle.value(settingsContext), isTrue);
    expect(prefs.incognitoReading, isTrue);
    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.incognitoReading, isTrue, reason: '必须真落库');

    await toggle.onChanged(settingsContext, false);
    expect(toggle.value(settingsContext), isFalse);
    expect(prefs.incognitoReading, isFalse);
  });

  test('偏好键已登记且是设备本地：Profile 快照与备份都不得携带', () {
    expect(kKnownPreferenceKeys, contains(kIncognitoReadingPrefKey));
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains(kIncognitoReadingPrefKey),
    );
    expect(
      PrefRedactionPolicy.isDeviceLocalOrCredential(kIncognitoReadingPrefKey),
      isTrue,
      reason: '备份导出 / Profile 分享按该谓词剔除',
    );
    expect(
      ProfileKeys.isExcludedPref(kIncognitoReadingPrefKey),
      isTrue,
      reason: 'Profile 快照不得复制这个设备本地选择',
    );
  });
}
