import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/local_source/local_source_entry_row.dart';
import 'package:fushi/src/media/online/installed_online_source_row.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 04：图源列表第一位的内置「本地图源」行。
///
/// 行内容 = 启用开关（默认开、可持久化）+ 名称 + `localcomic` 绝对路径；
/// 关闭后行置灰、不可进入（点击不触发 onOpen）；不写入 `manga_online_sources`
/// （因此不会进入 enabledMangaOnlineSources / 发现页 / 全局搜索）。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths, Directory root)
    : super(testPlatformServices()) {
    final PreferencesRepository prefs = PreferencesRepository(_db);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: root);
    // AppModel 在真实初始化时转发 prefs 通知；测试壳手动接上同一条线。
    prefs.addListener(notifyListeners);
  }

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;

  @override
  AppPaths? get appPathsOrNull => _paths;
}

Widget _harness(AppModel appModel, {VoidCallback? onOpen}) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: LocalSourceEntryRow(onOpen: onOpen)),
      ),
    ),
  ),
);

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_row_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('行显示名称与 localcomic 绝对路径，开关默认开，点击可进入', (
    WidgetTester tester,
  ) async {
    int opened = 0;
    await tester.pumpWidget(
      _harness(
        _TestAppModel(db, paths, tmp),
        onOpen: () => opened++,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('local_source_row')),
      findsOneWidget,
    );
    expect(find.text(t.local_source_title), findsOneWidget);
    expect(find.text(paths.localComicRoot.path), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    final InstalledOnlineSourceRow row = tester
        .widget<InstalledOnlineSourceRow>(
          find.byType(InstalledOnlineSourceRow),
        );
    expect(row.language, isNull, reason: '本地图源没有语言标签');
    expect(row.primaryAction, isNull);
    expect(
      row.menuActions,
      isEmpty,
      reason: '没有置顶 / 排序 / 清除数据 / 卸载扩展菜单',
    );

    await tester.tap(find.text(t.local_source_title));
    await tester.pumpAndSettle();
    expect(opened, 1, reason: '启用时点行进本地图源页面');
  });

  testWidgets('关闭开关后状态持久化，行不可进入', (WidgetTester tester) async {
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);
    int opened = 0;
    await tester.pumpWidget(
      _harness(appModel, onOpen: () => opened++),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(appModel.prefsRepo.localSourceEnabled, isFalse);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(
      await db.getMangaOnlineSources(),
      isEmpty,
      reason: '开关只写偏好，不写 manga_online_sources（因此不影响发现 / 全局搜索）',
    );

    await tester.tap(find.text(t.local_source_title));
    await tester.pumpAndSettle();
    expect(opened, 0, reason: '关闭的图源不可进入（与普通源行同一口径）');
  });

  testWidgets('本地图源不是 manga_online_sources 行，不参与扩展源枚举', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp)));
    await tester.pumpAndSettle();

    expect(
      await db.getMangaOnlineSources(),
      isEmpty,
      reason: '内置伪源照旧 Mokuro.moe 的做法：不写 manga_online_sources',
    );
  });
}
