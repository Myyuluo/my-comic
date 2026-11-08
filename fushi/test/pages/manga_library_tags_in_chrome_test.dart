import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/manga_library_page.dart';
import 'package:fushi/src/media/tags/tag_chips.dart' show FushiTagToggleChip;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar, FushiShellInlineTitle;
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 漫画页的标签栏占据原「书架」视图页签位（ticket 06 起），ticket 01 起从彩色
/// 多选 chip 改为单选分段胶囊：首项「书架」+ 用户标签，点选即切换页签。
///
/// 页面级 seam（与 [reader_shelf_tag_filter_empty_state_test] 同源）：挂真实
/// [MangaLibraryPage]（壳 + 书架页），标签走真 37 表 DB；书架列表 provider 覆写
/// 成受控列表，避开封面真 I/O。断言只落在用户可见的结果上：视图页签消失、分段
/// 胶囊在浮动 chrome 行、空标签时仍有「书架」页签、点选筛选生效、长按不再排序。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_tags_chrome_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_tags_chrome');
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

  Future<void> seedManga(String bookKey, String title) async {
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
        position: 0,
        duration: 1,
        canDelete: false,
        canEdit: true,
      ),
    );
  }

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(mangaItems),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: FushiShellTitleScope(
            title: t.manga_library,
            child: const FushiShellInlineTitle(
              enabled: true,
              child: MangaLibraryPage(),
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  testWidgets('漫画页不再显示视图页签；chrome 页签位是标签页签胶囊', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    expect(
      find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
      findsNothing,
      reason: '漫画页只剩书架一个视图，不得再画视图页签分段条',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_tag_tab_bar')),
      findsOneWidget,
      reason: 'chrome 页签位由标签页签胶囊占据',
    );
    expect(
      find.text(t.library_view_shelf),
      findsOneWidget,
      reason: '标签栏首项固定是「书架」页签',
    );
    // 「漫画」标题仍在浮动 chrome 行上。
    expect(
      find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
      findsOneWidget,
    );
  });

  testWidgets('标签页签出现在浮动 chrome 行，标题下不再有独立标签行', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);
    await db.createTag('短篇', 0xFF445566);
    await pumpPage(tester);

    final Finder bar = find.byType(FushiFloatingChromeBar);
    for (final String name in <String>['连载', '短篇']) {
      expect(
        find.descendant(of: bar, matching: find.text(name)),
        findsOneWidget,
        reason: '标签页签「$name」必须出现在浮动 chrome 行（原视图页签位置）',
      );
      expect(
        find.text(name),
        findsOneWidget,
        reason: '标签只占 chrome 一处；标题下不再有独立标签行',
      );
    }

    // 同一行：chip 与「漫画」标题胶囊、右上角动作的纵向中心一致。
    final double chipCenter = tester
        .getCenter(find.descendant(of: bar, matching: find.text('连载')))
        .dy;
    final double titleCenter = tester
        .getCenter(
          find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
        )
        .dy;
    final double actionsCenter = tester
        .getCenter(find.byKey(const ValueKey<String>('library_select_toggle')))
        .dy;
    expect(
      (chipCenter - titleCenter).abs(),
      lessThan(4.0),
      reason: '标签页签与「漫画」标题同一行',
    );
    expect(
      (chipCenter - actionsCenter).abs(),
      lessThan(4.0),
      reason: '标签页签与右上角动作同一行',
    );
  });

  testWidgets('漫画页页头「管理标签」动作使用标签图标', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    final Finder manage = find.byKey(
      const ValueKey<String>('library_tag_settings'),
    );
    expect(manage, findsOneWidget, reason: '漫画页页头必须有管理标签入口');
    final FushiIconButton button = tester.widget<FushiIconButton>(manage);
    expect(
      button.icon,
      FushiIcons.tag,
      reason: '管理标签入口与标签选择 / 管理页使用同一标签图标，不得再用齿轮',
    );
  });

  testWidgets('没有标签时 chrome 页签位仍有「书架」页签，不出现彩色 chip', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    expect(
      find.byType(FushiTagToggleChip),
      findsNothing,
      reason: '漫画页不再使用彩色多选 chip',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_tag_tab_shelf')),
      findsOneWidget,
      reason: '没有用户标签时「书架」仍是固定首项',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_tag_tab_count_shelf')),
      findsOneWidget,
      reason: '书架页签始终显示数量（含 0）',
    );
    expect(
      find.byType(FushiFloatingChromeBar),
      findsOneWidget,
      reason: '「漫画」标题与右侧动作的浮动 chrome 行仍在',
    );
    expect(
      find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('library_select_toggle')),
      findsOneWidget,
    );
  });

  testWidgets('点击 chrome 里的标签页签切换筛选，点回「书架」恢复默认', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await seedManga('m2', '漫画二');
    final int tagId = await db.createTag('连载', 0xFF112233);
    await db.addTagToBook('m1', tagId);
    await pumpPage(tester);

    final Finder card1 = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderFushiSource.mediaIdentifierFor('m1')}',
      ),
    );
    final Finder card2 = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderFushiSource.mediaIdentifierFor('m2')}',
      ),
    );
    // 默认「书架」只收无标签漫画。
    expect(card2, findsOneWidget, reason: '书架显示无标签漫画');
    expect(card1, findsNothing, reason: '有标签漫画不在书架');

    final Finder bar = find.byType(FushiFloatingChromeBar);
    await tester.tap(find.descendant(of: bar, matching: find.text('连载')));
    await tester.pumpAndSettle();

    expect(card1, findsOneWidget, reason: '标签页签显示对应漫画');
    expect(card2, findsNothing, reason: '无标签漫画不在标签页签');
    expect(
      find.byKey(const ValueKey<String>('library_tag_clear_chip')),
      findsNothing,
      reason: '单选页签没有多选「清除筛选」chip',
    );

    await tester.tap(find.descendant(of: bar, matching: find.text('书架')));
    await tester.pumpAndSettle();

    expect(card2, findsOneWidget, reason: '点回书架恢复无标签漫画');
    expect(card1, findsNothing);
  });

  testWidgets('在 chrome 行里长按拖动标签页签不再排序', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);
    await db.createTag('短篇', 0xFF445566);
    await pumpPage(tester);

    Future<List<String>> tagOrder() async =>
        (await db.getAllTags()).map((BookTagRow tag) => tag.name).toList();
    expect(await tagOrder(), <String>['连载', '短篇']);

    final Finder bar = find.byType(FushiFloatingChromeBar);
    final Finder chipA = find.descendant(of: bar, matching: find.text('连载'));
    final Finder chipB = find.descendant(of: bar, matching: find.text('短篇'));
    expect(
      find.descendant(
        of: bar,
        matching: find.byType(LongPressDraggable<BookTagRow>),
      ),
      findsNothing,
      reason: '漫画页标签栏不再提供长按拖拽排序',
    );

    final TestGesture drag = await tester.startGesture(tester.getCenter(chipA));
    // 按住不动，等长按识别器接管；再把第一枚拖到第二枚上放下。
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await drag.moveTo(tester.getCenter(chipB));
    await tester.pump(const Duration(milliseconds: 100));
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      await tagOrder(),
      <String>['连载', '短篇'],
      reason: '标签顺序仍在标签管理页维护，页签栏拖动不改变顺序',
    );
  });

  testWidgets('普通书籍页（my-comic 中不可达）仍保留视图页签与标题下标签行', (
    WidgetTester tester,
  ) async {
    await db.createTag('连载', 0xFF112233);
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(mangaItems),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: FushiShellTitleScope(
                title: t.books,
                child: FushiShellInlineTitle(
                  enabled: true,
                  child: MediaLibraryShell(
                    focusIdPrefix: 'book-library-view',
                    views: <MediaLibraryViewSpec>[
                      MediaLibraryViewSpec(
                        kind: MediaLibraryViewKind.library,
                        label: '书架',
                        handlesChromeInset: true,
                        // 普通书架：mangaOnly 默认为 false，不受漫画页改动影响。
                        builder: (BuildContext context, Widget navigation) =>
                            ReaderFushiHistoryPage(navigation: navigation),
                      ),
                      MediaLibraryViewSpec(
                        kind: MediaLibraryViewKind.sources,
                        label: '导入',
                        builder: (BuildContext context, Widget navigation) =>
                            const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(FushiSectionTabBar<MediaLibraryViewKind>),
      findsOneWidget,
      reason: '普通书籍页的视图页签不受漫画页改动影响',
    );
    expect(
      find.descendant(
        of: find.byType(FushiFloatingChromeBar),
        matching: find.text('连载'),
      ),
      findsNothing,
      reason: '普通书籍页的标签仍不在浮动 chrome 页签位',
    );
    expect(find.text('连载'), findsOneWidget, reason: '普通书籍页标题下仍有独立标签行');
  });
}
