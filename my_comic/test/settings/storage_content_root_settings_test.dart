import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/import/real_path_directory_picker.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/platform/platform_services.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/settings/settings_destination.dart';
import 'package:my_comic/src/settings/settings_schema_downloads.dart';
import 'package:my_comic/src/settings/settings_schema_storage_locations.dart';
import 'package:my_comic/src/settings/settings_schema_widgets.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/utils/misc/my_comic_toast.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 03：设置 →「存储与下载」的存储位置小节。
///
/// 「存储位置」（原「漫画数据位置」）整行只读，行尾两个按钮「变更文件夹」与
/// 「打开文件夹」；「程序数据位置」保持只读。三个重复的子文件夹入口
/// （下载 / 本地漫画 / 备份）已移除——它们来自共享构建器，SRS 备份页同步消失。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('storage_location_settings_');
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
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
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    late SettingsContext captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              captured = SettingsContext(
                context: context,
                appModel: AppModel(services ?? testPlatformServices()),
                ref: ref,
                readerSource: ReaderMyComicSource.instance,
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

  testWidgets('存储与下载显示存储位置、程序数据位置与清除缓存', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = locationSection();

    expect(section.isVisible(settings), isTrue);
    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'storage.content_root',
      'storage.program_state_root',
      'storage.clear_cache',
      'storage.clear_database',
    ]);

    final SettingsStatusItem contentRoot =
        itemNamed(section, 'storage.content_root') as SettingsStatusItem;
    expect(contentRoot.title, t.data_storage_content_root_title);
    expect(t.data_storage_content_root_title, '存储位置');
    expect(contentRoot.actionLabel, t.data_storage_change_button);
    expect(t.data_storage_change_button, '变更文件夹');
    expect(contentRoot.resolveAction(settings), isNotNull);

    // 行尾第二个按钮「打开文件夹」。
    expect(contentRoot.secondaryActionLabel, t.data_storage_open_button);
    expect(t.data_storage_open_button, '打开文件夹');
    expect(contentRoot.secondaryOnAction, isNotNull);

    final SettingsStatusItem programState =
        itemNamed(section, 'storage.program_state_root') as SettingsStatusItem;
    expect(programState.title, t.data_storage_program_state_root_title);
    expect(t.data_storage_program_state_root_title, '程序数据位置');
    expect(programState.actionLabel, isNull);
    expect(programState.secondaryActionLabel, isNull);
    expect(
      programState.resolveAction(settings),
      isNull,
      reason: '程序数据位置只读，不提供更改入口',
    );

    // 三个重复的子文件夹入口已移除。
    for (final String id in <String>[
      'storage.open_downloads',
      'storage.open_local_comic',
      'storage.open_autobackup',
    ]) {
      expect(
        section.items.where((SettingsItem item) => item.id == id),
        isEmpty,
        reason: '$id 必须从共享 Content root 段移除',
      );
    }
    expect(contentRoot.actionLabel, isNot('更改位置'));

    // 旧的整目录迁移设置项已移除。
    expect(
      section.items.where(
        (SettingsItem item) => item.id == 'sync.data_storage_location',
      ),
      isEmpty,
    );
    expect(section.footer, t.data_storage_content_root_footer);
  });

  testWidgets('存储位置整行不可点，只有「变更文件夹」与「打开文件夹」两个按钮可点', (WidgetTester tester) async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    // 测试宿主默认按 Android（SAF）走目录选择；本用例验证桌面路径上的
    // FilePicker.getDirectoryPath 调用，显式声明桌面平台。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final SettingsStatusItem item =
        itemNamed(locationSection(), 'storage.content_root')
            as SettingsStatusItem;

    final FilePicker? previous = _currentFilePicker();
    final _RecordingDirectoryPicker picker = _RecordingDirectoryPicker();
    FilePicker.platform = picker;
    addTearDown(() {
      if (previous != null) FilePicker.platform = previous;
    });

    late SettingsContext settings;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) {
                settings = SettingsContext(
                  context: context,
                  appModel: AppModel(testPlatformServices()),
                  ref: ref,
                  readerSource: ReaderMyComicSource.instance,
                  refresh: () {},
                );
                return SettingsSchemaItem(
                  item: item,
                  settingsContext: settings,
                  showIcons: false,
                  routeBuilder: (BuildContext context, WidgetBuilder builder) =>
                      MaterialPageRoute<void>(builder: builder),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(find.text('存储位置'), findsOneWidget);
    expect(find.text('变更文件夹'), findsOneWidget);
    expect(find.text('打开文件夹'), findsOneWidget);

    // 整行（标题）不再响应点击——不会弹出目录选择器。
    await tester.tap(find.text('存储位置'));
    await tester.pump();
    expect(picker.directoryPickCalls, 0, reason: '点击「存储位置」行本身不得触发文件夹选择');

    // 「变更文件夹」按钮仍然可点。
    await tester.tap(find.text('变更文件夹'));
    await tester.pump();
    expect(picker.directoryPickCalls, 1);

    // Flutter 在 test body 结束时校验 foundation debug 变量已复位。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('打开文件夹打开 Content root 本身，目录不存在时先创建', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    // 配置一个尚不存在的 Content root：打开按钮必须先建目录再交给文件管理器。
    final Directory content = Directory(p.join(tmp.path, 'CustomContent'));
    expect(content.existsSync(), isFalse);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: content.path,
    });

    final List<String> opened = <String>[];
    debugOpenContentRootDirectory = (String path) async {
      opened.add(path);
      return true;
    };

    final SettingsStatusItem item =
        itemNamed(locationSection(), 'storage.content_root')
            as SettingsStatusItem;
    // 真实文件系统 IO 必须走 runAsync：testWidgets 的 FakeAsync 区里真实 IO 的
    // Future 不会完成（仓库既有测试同款约定）。
    await tester.runAsync(() async {
      await item.secondaryOnAction!(settings);
    });

    expect(content.existsSync(), isTrue, reason: '打开前必须先创建存储位置目录');
    expect(opened, <String>[content.path]);
  });

  testWidgets('打开文件夹创建目录失败时显示失败提示且不调用打开器', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    MyComicToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );
    // 父路径是文件：directory.create(recursive: true) 必然失败（只读盘 / 权限 /
    // 断链之外的确定性复现，不依赖运行环境）。
    final File blocker = File(p.join(tmp.path, 'blocker'))
      ..writeAsStringSync('not a directory');
    final Directory content = Directory(p.join(blocker.path, 'CustomContent'));
    expect(content.existsSync(), isFalse);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: content.path,
    });

    final List<String> opened = <String>[];
    debugOpenContentRootDirectory = (String path) async {
      opened.add(path);
      return true;
    };

    final SettingsStatusItem item =
        itemNamed(locationSection(), 'storage.content_root')
            as SettingsStatusItem;
    await tester.runAsync(() async {
      await item.secondaryOnAction!(settings);
    });
    await tester.pump(); // insert the toast overlay entry
    await tester.pump(const Duration(milliseconds: 250)); // fade-in

    expect(
      find.text(t.data_storage_open_failed),
      findsOneWidget,
      reason: '创建目录失败也必须给用户可见的失败提示，异常不能逃出设置页',
    );
    expect(opened, isEmpty, reason: '目录都没建出来，不应再调用文件管理器');

    // 让自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('打开文件夹失败时复用现有失败提示', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    MyComicToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );
    debugOpenContentRootDirectory = (String path) async => false;

    final SettingsStatusItem item =
        itemNamed(locationSection(), 'storage.content_root')
            as SettingsStatusItem;
    await tester.runAsync(() async {
      await item.secondaryOnAction!(settings);
    });
    await tester.pump(); // insert the toast overlay entry
    await tester.pump(const Duration(milliseconds: 250)); // fade-in

    expect(find.text(t.data_storage_open_failed), findsOneWidget);

    // 让自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('切换存储位置只建三个空文件夹并重启，不弹迁移提示', (WidgetTester tester) async {
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
      'local',
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

FilePicker? _currentFilePicker() {
  try {
    return FilePicker.platform;
  } catch (_) {
    return null;
  }
}

/// 记录「选目录」调用的 FilePicker；返回 null = 用户取消。
class _RecordingDirectoryPicker extends FilePicker {
  int directoryPickCalls = 0;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    bool lockParentWindow = false,
  }) async {
    directoryPickCalls++;
    return null;
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => null;
}
