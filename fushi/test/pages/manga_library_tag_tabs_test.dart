import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/pages/implementations/tag_management_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 01：漫画页标签栏改为单选分段胶囊（书架 + 用户标签，排他归属 + 数量）。
///
/// 页面级 seam（与 [manga_library_tags_in_chrome_test] 同源）：挂真实漫画书架
/// `ReaderFushiHistoryPage(mangaOnly: true)`，标签走真 37 表内存 DB；书架列表
/// provider 覆写成受控列表，避开封面真 I/O。断言只落在用户可见结果上：哪些卡在
/// 网格里、页签上的数量、页签顺序与选中结果。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_tag_tabs_pp',
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

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late List<MediaItem> mangaItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_tag_tabs');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    mangaItems = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedManga(
    String bookKey,
    String title, {
    int position = 0,
    int duration = 1,
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey/manga.json',
        extractDir: '${pathProviderDir.path}/$bookKey',
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
      ),
    );
    mangaItems.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: 'reader',
        mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
        position: position,
        duration: duration,
        canDelete: false,
        canEdit: true,
      ),
    );
  }

  Widget buildApp({Key? pageKey}) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(mangaItems),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            key: pageKey,
            mangaOnly: true,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester, {Key? pageKey}) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(pageKey: pageKey));
    await tester.pumpAndSettle();
  }

  Finder mangaCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  Finder shelfSegment() =>
      find.byKey(const ValueKey<String>('manga_tag_tab_shelf'));

  Finder tagSegment(int tagId) =>
      find.byKey(ValueKey<String>('manga_tag_tab_$tagId'));

  Finder segmentCount(String scope) =>
      find.byKey(ValueKey<String>('manga_tag_tab_count_$scope'));

  String countText(WidgetTester tester, String scope) =>
      tester.widget<Text>(segmentCount(scope)).data!;

  Future<void> search(WidgetTester tester, String query) async {
    // 单行页头：搜索平时收成页头的 🔍，点开才有输入框。
    final Finder field = find.byKey(
      const ValueKey<String>('shelf_search_field'),
    );
    if (field.evaluate().isEmpty) {
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi-header-search-button')),
      );
      await tester.pumpAndSettle();
    }
    await tester.enterText(field, query);
    await tester.pumpAndSettle();
  }

  Future<void> pickReadStatus(WidgetTester tester, String name) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('library_sort_menu_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('shelf_filter_read_status_$name')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('默认「书架」只显示无标签漫画，标签页签显示对应漫画，数量始终显示', (WidgetTester tester) async {
    await seedManga('m1', '无标签漫画');
    await seedManga('m2', '连载漫画');
    final int tagId = await db.createTag('连载', 0xFF112233);
    await db.addTagToBook('m2', tagId);

    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey<String>('manga_tag_tab_bar')),
      findsOneWidget,
      reason: '漫画页标签栏是分段胶囊',
    );
    expect(shelfSegment(), findsOneWidget, reason: '首项固定是「书架」');
    expect(tagSegment(tagId), findsOneWidget, reason: '用户标签出现在书架之后');
    expect(find.text('全部'), findsNothing, reason: '不存在「全部」页签');

    expect(mangaCard('m1'), findsOneWidget, reason: '「书架」显示无标签漫画');
    expect(mangaCard('m2'), findsNothing, reason: '有标签的漫画不出现在「书架」');
    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagId'), '1');

    await tester.tap(tagSegment(tagId));
    await tester.pumpAndSettle();

    expect(mangaCard('m2'), findsOneWidget, reason: '标签页签显示该标签漫画');
    expect(mangaCard('m1'), findsNothing, reason: '无标签漫画不出现在标签页签');

    await tester.tap(shelfSegment());
    await tester.pumpAndSettle();

    expect(mangaCard('m1'), findsOneWidget);
    expect(mangaCard('m2'), findsNothing);
  });

  testWidgets('多标签漫画在每个对应标签下都出现；无书标签显示数量 0', (WidgetTester tester) async {
    await seedManga('m1', '无标签');
    await seedManga('m2', '双标签');
    await seedManga('m3', '单标签');
    final int tagA = await db.createTag('标签甲', 0xFF112233);
    final int tagB = await db.createTag('标签乙', 0xFF445566);
    final int emptyTag = await db.createTag('空标签', 0xFF778899);
    await db.addTagToBook('m2', tagA);
    await db.addTagToBook('m2', tagB);
    await db.addTagToBook('m3', tagB);

    await pumpPage(tester);

    expect(mangaCard('m1'), findsOneWidget, reason: '书架只收无标签漫画');
    expect(mangaCard('m2'), findsNothing, reason: '多标签漫画不出现在书架');
    expect(mangaCard('m3'), findsNothing, reason: '有标签漫画不出现在书架');
    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagA'), '1');
    expect(countText(tester, '$tagB'), '2', reason: '多标签漫画在标签乙中计一次');
    expect(countText(tester, '$emptyTag'), '0', reason: '数量始终显示，包括 0');

    await tester.tap(tagSegment(tagA));
    await tester.pumpAndSettle();
    expect(mangaCard('m2'), findsOneWidget);
    expect(mangaCard('m3'), findsNothing);

    await tester.tap(tagSegment(tagB));
    await tester.pumpAndSettle();
    expect(mangaCard('m2'), findsOneWidget, reason: '多标签漫画在本标签下也出现');
    expect(mangaCard('m3'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing);
  });

  testWidgets('数量随搜索词更新，切换页签保留搜索词且只在当前页签内生效', (WidgetTester tester) async {
    await seedManga('m1', 'Alpha 起点');
    await seedManga('m2', 'Beta 连载');
    await seedManga('m3', 'Alpha 续');
    final int tagA = await db.createTag('连载', 0xFF112233);
    final int tagB = await db.createTag('短篇', 0xFF445566);
    await db.addTagToBook('m2', tagA);
    await db.addTagToBook('m3', tagA);

    await pumpPage(tester);
    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagA'), '2');
    expect(countText(tester, '$tagB'), '0');

    await search(tester, 'Alpha');

    expect(countText(tester, 'shelf'), '1', reason: '书架命中 Alpha 的无标签漫画');
    expect(countText(tester, '$tagA'), '1', reason: '连载命中 Alpha 的只有 m3');
    expect(countText(tester, '$tagB'), '0', reason: '搜索后续仍显示 0');
    expect(mangaCard('m1'), findsOneWidget);
    expect(mangaCard('m2'), findsNothing);
    expect(mangaCard('m3'), findsNothing, reason: '搜索只在当前页签（书架）内生效');

    await tester.tap(tagSegment(tagA));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      findsOneWidget,
      reason: '切换页签保留搜索栏状态',
    );
    expect(countText(tester, 'shelf'), '1', reason: '切换页签后数量保持当前搜索结果');
    expect(countText(tester, '$tagA'), '1');
    expect(mangaCard('m3'), findsOneWidget);
    expect(mangaCard('m2'), findsNothing);
    expect(mangaCard('m1'), findsNothing, reason: '搜索只在当前页签（连载）内生效');
  });

  testWidgets('数量随阅读状态筛选实时更新，标签无命中时显示筛选空态', (WidgetTester tester) async {
    await seedManga('m1', '未读一', position: 0, duration: 100);
    await seedManga('m2', '在读一', position: 50, duration: 100);
    await seedManga('m3', '读完一', position: 100, duration: 100);
    await seedManga('m4', '未读二', position: 0, duration: 100);
    final int tagA = await db.createTag('连载', 0xFF112233);
    await db.addTagToBook('m3', tagA);
    await db.addTagToBook('m4', tagA);

    await pumpPage(tester);
    expect(countText(tester, 'shelf'), '2');
    expect(countText(tester, '$tagA'), '2');

    await pickReadStatus(tester, 'reading');

    expect(countText(tester, 'shelf'), '1', reason: '书架只剩在读的 m2');
    expect(countText(tester, '$tagA'), '0', reason: '连载下没有在读漫画');
    expect(mangaCard('m2'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing);

    await tester.tap(tagSegment(tagA));
    await tester.pumpAndSettle();

    expect(mangaCard('m3'), findsNothing);
    expect(mangaCard('m4'), findsNothing);
    expect(
      find.text(t.tag_no_books_for_filter),
      findsOneWidget,
      reason: '当前页签筛选无命中 → 筛选空态，而不是「书架为空」',
    );
  });

  testWidgets('标签名过长时截断，数量始终完整显示', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    final String longName = '这是一个非常非常长的标签名称' * 4;
    final int tagId = await db.createTag(longName, 0xFF112233);

    await pumpPage(tester);

    final Finder label = find.descendant(
      of: tagSegment(tagId),
      matching: find.text(longName),
    );
    expect(label, findsOneWidget);
    expect(
      tester.widget<Text>(label).overflow,
      TextOverflow.ellipsis,
      reason: '过长的标签名要截断',
    );
    expect(tester.widget<Text>(label).maxLines, 1);
    expect(segmentCount('$tagId'), findsOneWidget, reason: '名称截断不影响数量显示');
  });

  testWidgets('标签按标签管理页的顺序排列；长按拖动不再排序', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    final int tagA = await db.createTag('甲', 0xFF112233);
    final int tagB = await db.createTag('乙', 0xFF445566);

    await pumpPage(tester);

    final Finder shelf = shelfSegment();
    final Finder segA = tagSegment(tagA);
    final Finder segB = tagSegment(tagB);
    expect(shelf.evaluate(), isNotEmpty);
    expect(
      tester.getCenter(shelf).dx,
      lessThan(tester.getCenter(segA).dx),
      reason: '「书架」固定在最左',
    );
    expect(
      tester.getCenter(segA).dx,
      lessThan(tester.getCenter(segB).dx),
      reason: '标签按存储顺序排列',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('manga_tag_tab_bar')),
        matching: find.byType(LongPressDraggable<BookTagRow>),
      ),
      findsNothing,
      reason: '漫画页标签栏不再支持长按拖拽排序',
    );

    final TestGesture drag = await tester.startGesture(tester.getCenter(segA));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveTo(tester.getCenter(segB));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      (await db.getAllTags()).map((BookTagRow tag) => tag.name).toList(),
      <String>['甲', '乙'],
      reason: '长按拖动不得改变标签顺序',
    );
  });

  testWidgets('页签选择在页面 State 重建后保留（应用运行期间）', (WidgetTester tester) async {
    await seedManga('m1', '无标签');
    await seedManga('m2', '有标签');
    final int tagA = await db.createTag('连载', 0xFF112233);
    await db.addTagToBook('m2', tagA);

    await pumpPage(tester);
    await tester.tap(tagSegment(tagA));
    await tester.pumpAndSettle();
    expect(mangaCard('m2'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing);

    // 页面 State 整个重建（等价离开漫画页再回来）：app 级 ProviderScope 仍在，
    // 选择必须保留。
    await tester.pumpWidget(buildApp(pageKey: const ValueKey<int>(2)));
    await tester.pumpAndSettle();
    expect(mangaCard('m2'), findsOneWidget, reason: '运行期间保留当前页签');
    expect(mangaCard('m1'), findsNothing);
  });

  test('进程重启（新的 ProviderContainer）后回到默认「书架」', () {
    // 页签状态活在 app 级 ProviderScope 里：同一容器内保留，容器销毁即回到
    // 默认值——这正是「运行期间保留、重启回到书架」的实现边界。
    final ProviderContainer first = ProviderContainer();
    expect(
      first.read(mangaTagTabSelectionProvider),
      const MangaShelfTabSelection(),
    );
    first.read(mangaTagTabSelectionProvider.notifier).state =
        const MangaTagTabSelection(42);
    expect(
      first.read(mangaTagTabSelectionProvider),
      const MangaTagTabSelection(42),
    );
    first.dispose();

    final ProviderContainer restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    expect(
      restarted.read(mangaTagTabSelectionProvider),
      const MangaShelfTabSelection(),
      reason: '重启后默认选中「书架」',
    );
  });

  testWidgets('页头「管理标签」入口仍可打开标签管理页', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);

    await pumpPage(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('library_tag_settings')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(TagManagementPage),
      findsOneWidget,
      reason: '管理标签入口不受标签栏形态改动影响',
    );
  });
}
