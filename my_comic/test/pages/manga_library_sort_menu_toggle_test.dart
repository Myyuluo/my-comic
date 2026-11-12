// Ticket 07：漫画书架页「排序与筛选」第二次点击应**收起**菜单，而不是关了又开。
//
// 根因：页头排序按钮画在 MenuAnchor（零尺寸常驻锚点）的 tap region 之外。菜单
// 打开时按下按钮，MenuAnchor 当外部点击在 pointer-down 关掉菜单；pointer-up 的
// onTap 读到的 isOpen 已是 false，于是又打开——观感就是「点了没反应 / 关了又开」。
//
// 页面级 seam（与 [reader_shelf_read_status_filter_persist_test] 同源）：挂真实
// `ReaderMyComicHistoryPage`（漫画页）+ 内存 DB，列表 provider 覆写成受控列表。
// 断言只落在用户可见结果上：菜单项出现 / 消失、点外部 / ESC / 选项选择是否关闭、
// 标签项是否保持打开。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/models/preferences_repository.dart';
import 'package:my_comic/src/pages/implementations/media_library_shell.dart';
import 'package:my_comic/src/pages/implementations/reader_my_comic_history_page.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:material_ui/material_ui.dart';
import 'package:my_comic_core/my_comic_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'my_comic_sort_menu_toggle_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late MyComicDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late MediaLibrarySecondaryRowSlot secondaryRow;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(
      'my_comic_sort_menu_toggle_store',
    );
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    secondaryRow = MediaLibrarySecondaryRowSlot();
  });

  tearDown(() async {
    secondaryRow.dispose();
    await db.close();
  });

  Widget buildApp({ThemeData? theme}) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      myComicBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: theme,
        home: Scaffold(
          body: MediaLibraryShellScope(
            kinds: const <MediaLibraryViewKind>{MediaLibraryViewKind.library},
            select: (MediaLibraryViewKind _) {},
            secondaryRowSlot: secondaryRow,
            // 模拟库页外壳的二级浮动行：页头把标签页签登记到槽里，壳负责画。
            // 没有这一行，页面会走「无壳」回退把标签塞进排序菜单。
            child: Column(
              children: <Widget>[
                ListenableBuilder(
                  listenable: secondaryRow,
                  builder: (BuildContext context, Widget? _) =>
                      secondaryRow.content ?? const SizedBox.shrink(),
                ),
                Expanded(
                  child: ReaderMyComicHistoryPage(
                    mangaOnly: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  // Cupertino/legacy 工具行路径（isCupertinoPlatform 只看设计系统扩展）。
  ThemeData cupertinoTheme() => ThemeData(
    extensions: const <ThemeExtension<dynamic>>[
      MyComicDesignSystemTheme(MyComicDesignSystem.cupertino),
    ],
  );

  Finder sortButton() =>
      find.byKey(const ValueKey<String>('library_sort_menu_button'));

  // 排序菜单里「阅读状态 → 全部」这一项：出现 = 菜单开着。
  Finder menuProbe() =>
      find.byKey(const ValueKey<String>('shelf_filter_read_status_all'));

  testWidgets('页头排序按钮：第一次点击展开，第二次点击同一按钮收起', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsNothing);

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsOneWidget, reason: '第一次点击应展开排序菜单');

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(
      menuProbe(),
      findsNothing,
      reason: '第二次点击同一按钮应收起菜单（不能关了又开）',
    );

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsOneWidget, reason: '第三次点击应再次展开');
  });

  testWidgets('点击菜单外部仍关闭菜单', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsOneWidget);

    // 菜单锚在页头下沿右侧；左下角是菜单外。
    await tester.tapAt(const Offset(60, 540));
    await tester.pumpAndSettle();
    expect(menuProbe(), findsNothing, reason: '点外部应关闭菜单');
  });

  testWidgets('ESC 仍关闭菜单', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(menuProbe(), findsNothing, reason: 'ESC 应关闭菜单');
  });

  testWidgets('选择菜单项后菜单仍关闭', (WidgetTester tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('shelf_filter_read_status_reading')),
    );
    await tester.pumpAndSettle();
    expect(menuProbe(), findsNothing, reason: '选中阅读状态后菜单应关闭');
    expect(prefs.shelfReadStatusFilterName, 'reading');
  });

  testWidgets('Cupertino/legacy 工具行：同一按钮二次点击也收起，漫画标签不进菜单',
      (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(500, 900);
    addTearDown(tester.view.reset);
    final int tagA = await db.createTag('TagA', 0xFF4CAF50);

    await tester.pumpWidget(buildApp(theme: cupertinoTheme()));
    await tester.pumpAndSettle();

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(menuProbe(), findsOneWidget, reason: 'legacy 工具行按钮应展开菜单');

    // 漫画页标签栏已改为独立的单选页签胶囊（ticket 01）：legacy 工具行的排序
    // 菜单里不再有「多选标签」组。
    expect(
      find.byKey(ValueKey<String>('library_menu_tag_$tagA')),
      findsNothing,
      reason: '漫画页标签是独立页签，不再并进排序菜单',
    );
    expect(
      find.byKey(ValueKey<String>('manga_tag_tab_$tagA')),
      findsOneWidget,
      reason: '标签以单选页签形式出现在页签胶囊里',
    );

    await tester.tap(sortButton());
    await tester.pumpAndSettle();
    expect(
      menuProbe(),
      findsNothing,
      reason: 'legacy 路径第二次点击同一按钮也应收起菜单',
    );
  });
}
