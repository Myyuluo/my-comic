import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 08：「存储与下载 → 下载 → 保存为CBZ压缩包」。
///
/// 守用户可见的几件事：开关位于「备份索引」下方、默认开启（新安装与
/// 升级后的存量用户都读 true）、开关值真的落进偏好表；副标题说明关闭后的
/// 保存形式（简中/繁中准确文案，英文及其它 locale 用英文基线）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test('保存为CBZ压缩包默认开启：没写过键的新安装与升级用户都读到 true', () async {
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    expect(prefs.downloadSaveAsCbz, isTrue);

    // 重新加载同库：键仍不存在，默认值仍是开启（升级用户首次见到该设置）。
    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.downloadSaveAsCbz, isTrue);
  });

  test('开关关闭后落库：重新加载读到 false', () async {
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setDownloadSaveAsCbz(false);
    expect(prefs.downloadSaveAsCbz, isFalse);

    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.downloadSaveAsCbz, isFalse);
  });

  test('「存储与下载」在备份索引下方出现「下载」分组', () {
    final SettingsDestination destination = buildDownloadsDestination();

    expect(
      destination.sections.map((SettingsSection section) => section.id),
      <String?>[
        'storage.location.section',
        'system.section.backup',
        'downloads.section.download',
      ],
      reason: 'ticket 06 分组顺序：数据存储位置 → 备份索引 → 下载',
    );

    final SettingsSection section = destination.sections[2];
    expect(section.title, '下载');
    expect(section.items, hasLength(1));

    final SettingsSwitchItem toggle =
        section.items.single as SettingsSwitchItem;
    expect(toggle.id, 'downloads.save_as_cbz');
    expect(toggle.title, '保存为CBZ压缩包');
    expect(
      toggle.subtitle,
      '关闭后，下载的漫画将以文件夹+图片形式保存。',
      reason: '副标题必须说明关闭后的保存形式',
    );
    expect(toggle.defaultValue, isTrue, reason: '默认开启');
  });

  test('CBZ 开关副标题：繁中准确文案，英文及其它 locale 使用英文基线', () {
    const String englishBaseline =
        'When off, downloaded manga are saved as folders with image files.';
    expect(
      AppLocale.zhHk.translations.download_save_as_cbz_subtitle,
      '關閉後，下載的漫畫將以資料夾+圖片形式保存。',
      reason: '繁中副标题必须准确表达关闭后的保存形式',
    );
    expect(
      AppLocale.en.translations.download_save_as_cbz_subtitle,
      englishBaseline,
      reason: '英文基线必须准确表达关闭后的保存形式',
    );
    for (final AppLocale locale in AppLocale.values) {
      if (locale == AppLocale.zhCn || locale == AppLocale.zhHk) {
        continue;
      }
      expect(
        locale.translations.download_save_as_cbz_subtitle,
        englishBaseline,
        reason: '${locale.name}：其它 locale 使用英文基线',
      );
    }
  });

  testWidgets('开关默认开启、关闭后写穿偏好', (WidgetTester tester) async {
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_cbz_setting',
    );
    addTearDown(() {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final AppModel appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);

    late SettingsContext settingsContext;
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

    final SettingsSwitchItem toggle =
        buildDownloadsDestination().sections[2].items.single
            as SettingsSwitchItem;
    expect(toggle.value(settingsContext), isTrue, reason: '默认开启');

    await toggle.onChanged(settingsContext, false);
    expect(toggle.value(settingsContext), isFalse);
    expect(prefs.downloadSaveAsCbz, isFalse);

    final PreferencesRepository reloaded = PreferencesRepository(db);
    await reloaded.loadFromDb();
    expect(reloaded.downloadSaveAsCbz, isFalse, reason: '必须真落库');
  });
}
