import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/src/storage/app_paths.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 08：设置 →「存储与下载」显示「漫画数据位置」（Content root，可切换）与
/// 「程序数据位置」（Program state root，只读），并提供 downloads / localcomic /
/// autobackup 三个文件夹的打开入口。切换只创建三个空文件夹，不搬移文件、不弹
/// 迁移/重建提示。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('storage_location_settings_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
  });

  tearDown(() {
    AppPaths.debugTestEnvironment = null;
    debugRealDirectoryPathOverride = null;
    debugOpenContentRootDirectory = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<SettingsContext> captureContext(
    WidgetTester tester, {
    PlatformServices? services,
  }) async {
    late SettingsContext captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              captured = SettingsContext(
                context: context,
                appModel: AppModel(services ?? testPlatformServices()),
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
    return captured;
  }

  SettingsSection locationSection() =>
      buildDownloadsDestination().sections.singleWhere(
        (SettingsSection section) => section.id == 'storage.location.section',
      );

  SettingsItem itemNamed(SettingsSection section, String id) =>
      section.items.singleWhere((SettingsItem item) => item.id == id);

  testWidgets('存储与下载显示漫画数据位置、程序数据位置与三个文件夹入口', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = locationSection();

    expect(section.isVisible(settings), isTrue);
    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'storage.content_root',
      'storage.program_state_root',
      'storage.open_downloads',
      'storage.open_local_comic',
      'storage.open_autobackup',
    ]);

    final SettingsStatusItem contentRoot =
        itemNamed(section, 'storage.content_root') as SettingsStatusItem;
    expect(contentRoot.title, t.data_storage_content_root_title);
    expect(t.data_storage_content_root_title, '漫画数据位置');
    expect(contentRoot.actionLabel, t.data_storage_change_button);
    expect(contentRoot.resolveAction(settings), isNotNull);

    final SettingsStatusItem programState =
        itemNamed(section, 'storage.program_state_root') as SettingsStatusItem;
    expect(programState.title, t.data_storage_program_state_root_title);
    expect(t.data_storage_program_state_root_title, '程序数据位置');
    expect(programState.actionLabel, isNull);
    expect(
      programState.resolveAction(settings),
      isNull,
      reason: '程序数据位置只读，不提供更改入口',
    );

    for (final String id in <String>[
      'storage.open_downloads',
      'storage.open_local_comic',
      'storage.open_autobackup',
    ]) {
      final SettingsStatusItem open =
          itemNamed(section, id) as SettingsStatusItem;
      expect(open.actionLabel, t.data_storage_open_button);
      expect(open.resolveAction(settings), isNotNull);
    }

    // 旧的整目录迁移设置项已移除。
    expect(
      section.items.where(
        (SettingsItem item) => item.id == 'sync.data_storage_location',
      ),
      isEmpty,
    );
    expect(section.footer, t.data_storage_content_root_footer);
  });

  testWidgets('三个打开入口分别打在 downloads / localcomic / autobackup', (
    WidgetTester tester,
  ) async {
    final SettingsContext settings = await captureContext(tester);
    final Directory content = Directory(p.join(tmp.path, 'content'))
      ..createSync(recursive: true);
    final Map<String, String> opened = <String, String>{};
    debugOpenContentRootDirectory = (String path) async {
      opened.addAll(<String, String>{'path': path});
      return true;
    };
    for (final String name in <String>[
      'downloads',
      'localcomic',
      'autobackup',
    ]) {
      Directory(p.join(content.path, name)).createSync(recursive: true);
    }

    final SettingsSection section = locationSection();
    for (final MapEntry<String, String> entry in <String, String>{
      'storage.open_downloads': 'downloads',
      'storage.open_local_comic': 'localcomic',
      'storage.open_autobackup': 'autobackup',
    }.entries) {
      opened.clear();
      final SettingsStatusItem item =
          itemNamed(section, entry.key) as SettingsStatusItem;
      await item.resolveAction(settings)!(settings);
      expect(opened['path'], p.join(content.path, entry.value));
    }
  });

  testWidgets('切换漫画数据位置只建三个空文件夹并重启，不弹迁移提示', (WidgetTester tester) async {
    final FakeLifecycleService lifecycle = FakeLifecycleService()
      ..supportsRestartValue = true;
    final SettingsContext settings = await captureContext(
      tester,
      services: fakePlatformServices(lifecycle: lifecycle),
    );
    final Directory current = Directory(p.join(tmp.path, 'content'))
      ..createSync(recursive: true);
    expect(settings.appModel.platformServices.lifecycle, same(lifecycle));

    final Directory target = Directory(p.join(tmp.path, 'NewContent'));
    debugRealDirectoryPathOverride = target.path;
    // 旧位置放一份文件，切换后必须原地保留。
    final File oldFile = File(p.join(current.path, 'downloads', 'old.jpg'))
      ..createSync(recursive: true);
    oldFile.writeAsStringSync('old');

    final SettingsStatusItem item =
        itemNamed(locationSection(), 'storage.content_root')
            as SettingsStatusItem;
    // 真实文件系统 IO 必须走 runAsync：testWidgets 的 FakeAsync 区里真实 IO 的
    // Future 不会完成（仓库既有测试同款约定）。
    await tester.runAsync(() async {
      await item.resolveAction(settings)!(settings);
    });

    for (final String name in <String>[
      'downloads',
      'autobackup',
      'localcomic',
    ]) {
      final Directory dir = Directory(p.join(target.path, name));
      expect(dir.existsSync(), isTrue, reason: '$name 必须创建');
      expect(dir.listSync(), isEmpty);
    }
    expect(oldFile.existsSync(), isTrue);
    expect(oldFile.readAsStringSync(), 'old');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AppPaths.contentRootPrefKey),
      p.canonicalize(target.path),
    );
    expect(lifecycle.restartCalled, isTrue);
  });

  testWidgets('旧迁移器与迁移提示不再接入设置页', (WidgetTester tester) async {
    final String locations = File(
      'lib/src/settings/settings_schema_storage_locations.dart',
    ).readAsStringSync();
    final String downloads = File(
      'lib/src/settings/settings_schema_downloads.dart',
    ).readAsStringSync();
    final String schema = File(
      'lib/src/sync/sync_settings_schema.dart',
    ).readAsStringSync();
    for (final String source in <String>[locations, downloads, schema]) {
      for (final String forbidden in <String>[
        'DataRootMigrator',
        'runDataRootMigration',
        'planDataRootMigration',
        'data_storage_change_confirm',
        'sync.data_storage_location',
      ]) {
        expect(
          source.contains(forbidden),
          isFalse,
          reason: '设置页不得再接入旧迁移流程：$forbidden',
        );
      }
    }
    expect(
      locations.contains('showDialog') || locations.contains('showAppDialog'),
      isFalse,
      reason: '切换 Content root 不弹迁移/重建提示',
    );
    expect(
      File(
        'lib/src/sync/sync_settings_schema/data_root.part.dart',
      ).existsSync(),
      isFalse,
      reason: '旧的数据位置设置/迁移 part 已随整目录迁移器删除（ticket 12）',
    );
    expect(
      File('lib/src/storage/data_root_migrator.dart').existsSync(),
      isFalse,
      reason: '旧整目录迁移器已删除（ticket 12）',
    );
  });
}
