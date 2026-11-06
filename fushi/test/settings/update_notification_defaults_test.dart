import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

import '../helpers/test_platform_services.dart';

/// 「设置 → 系统与关于 → 更新提醒」两个域开关的默认值：漫画新章默认关、
/// 漫画扩展维持默认开，且与 `UpdateFeedService.isKindEnabled` 读同一份默认。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext settingsContext;

  SettingsSection section() => buildSystemDestination().sections.singleWhere(
        (SettingsSection candidate) =>
            candidate.id == 'system.section.update_notifications',
      );

  SettingsSwitchItem item(UpdateFeedKind kind) =>
      section().items.singleWhere(
            (SettingsItem candidate) =>
                candidate.id == 'system.updates.${kind.dbValue}',
          )
          as SettingsSwitchItem;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_update_notify_defaults_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() => db.close());

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

  testWidgets('从未存过开关：漫画新章显示关闭，漫画扩展显示开启', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);

    expect(
      item(UpdateFeedKind.mangaChapter).value(settingsContext),
      isFalse,
      reason: '漫画新章提醒默认关闭（不在未经开启的情况下后台检查）',
    );
    expect(
      item(UpdateFeedKind.mangaExtension).value(settingsContext),
      isTrue,
      reason: '漫画扩展更新提醒保持原来的默认开启',
    );
    expect(item(UpdateFeedKind.mangaChapter).defaultValue, isFalse,
        reason: '「恢复默认」显示的就是这个默认值');
    expect(item(UpdateFeedKind.mangaExtension).defaultValue, isTrue);
    expect(
      prefs.containsKey('updates_notify_manga_chapter'),
      isFalse,
      reason: '读默认值不该顺手把偏好写进去',
    );
  });

  testWidgets('开关写穿偏好；用户的选择优先于默认值', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);

    await item(UpdateFeedKind.mangaChapter).onChanged(settingsContext, true);
    expect(prefs.getPref('updates_notify_manga_chapter'), isTrue);
    expect(item(UpdateFeedKind.mangaChapter).value(settingsContext), isTrue);
    expect(appModel.updateFeedService.isKindEnabled(UpdateFeedKind.mangaChapter),
        isTrue,
        reason: '设置 UI 与服务层必须读到同一个开关值');

    await item(UpdateFeedKind.mangaChapter).onChanged(settingsContext, false);
    expect(item(UpdateFeedKind.mangaChapter).value(settingsContext), isFalse);
    expect(appModel.updateFeedService.isKindEnabled(UpdateFeedKind.mangaChapter),
        isFalse);
  });

  testWidgets('扩展开关写穿，默认行为不变', (WidgetTester tester) async {
    await pumpContext(tester);

    await item(UpdateFeedKind.mangaExtension).onChanged(settingsContext, false);
    expect(prefs.getPref('updates_notify_manga_extension'), isFalse);
    expect(item(UpdateFeedKind.mangaExtension).value(settingsContext), isFalse);
    expect(
      appModel.updateFeedService.isKindEnabled(UpdateFeedKind.mangaExtension),
      isFalse,
    );
  });
}
