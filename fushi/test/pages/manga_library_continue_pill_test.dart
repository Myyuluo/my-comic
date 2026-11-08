import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/manga_library_page.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar, FushiShellInlineTitle;
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 漫画页布局跟进 ticket 03：继续阅读入口从网格顶部的大 hero 卡变成主 chrome
/// 行里的一枚紧凑胶囊（tag bar 原来的页签位，「漫画」标题右侧、右上角动作左侧）。
///
/// 页面级 seam（与 `manga_library_tags_in_chrome_test` 同源）：挂真实
/// [MangaLibraryPage]（壳 + 书架页），书架列表 provider 受控，阅读历史落真
/// `reader_positions` 表。断言只落在用户可见的结果上：胶囊在哪、长什么样、
/// 点它是否走原继续阅读路径、无候选是否隐藏、滚动手势是否随 chrome 收放、
/// 窄窗是否仍能看到。
class _RecordingAppModel extends AppModel {
  _RecordingAppModel() : super(testPlatformServices());

  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    opened.add(item);
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_continue_pill_pp',
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
  late _RecordingAppModel appModel;
  late Directory storeDir;
  late List<MediaItem> mangaItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_pill');
    appModel = _RecordingAppModel()
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
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

  Future<String> seedManga(
    String bookKey,
    String title, {
    int position = 0,
    int duration = 1,
  }) async {
    final String uid = 'uid_$bookKey';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        uid: Value<String>(uid),
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey/manga.json',
        extractDir: '${pathProviderDir.path}/$bookKey',
        chapterCount: duration,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
      ),
    );
    mangaItems.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: 'reader_media_type',
        mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
        position: position,
        duration: duration,
        canDelete: false,
        canEdit: true,
      ),
    );
    return uid;
  }

  Future<void> seedRecency(String uid, int updatedAt) async {
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: uid,
        sectionIndex: 0,
        normCharOffset: 0,
        updatedAt: updatedAt,
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

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1400, 1200),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Finder pillFinder() =>
      find.byKey(const ValueKey<String>('reader_shelf_continue_pill'));

  testWidgets('主 chrome 行页签位显示继续阅读胶囊：圆形封面 + 主色「继续阅读」+ 主色圆形播放钮', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga(
      'm1',
      '漫画一',
      position: 5,
      duration: 10,
    );
    await seedRecency(uid, 1000);
    await pumpPage(tester);

    final Finder pill = pillFinder();
    expect(pill, findsOneWidget, reason: '有继续阅读条目时胶囊出现在页面里');
    expect(
      find.descendant(of: find.byType(FushiFloatingChromeBar), matching: pill),
      findsOneWidget,
      reason: '胶囊占主 chrome 行的页签位（标签栏原来的位置）',
    );

    final BuildContext context = tester.element(pill);
    final ColorScheme cs = Theme.of(context).colorScheme;

    // 圆形封面缩略图
    final Finder cover = find.byKey(
      const ValueKey<String>('reader_shelf_continue_pill_cover'),
    );
    expect(cover, findsOneWidget, reason: '胶囊左侧是封面缩略图');
    expect(
      find.ancestor(of: cover, matching: find.byType(ClipOval)),
      findsOneWidget,
      reason: '封面裁成圆形',
    );
    final Size coverSize = tester.getSize(cover);
    expect(coverSize.width, coverSize.height, reason: '圆形封面是正方形槽');

    // 主色蓝「继续阅读」文案
    final Text label = tester.widget<Text>(
      find.descendant(of: pill, matching: find.text(t.book_continue_reading)),
    );
    expect(
      label.style?.color,
      cs.primary,
      reason: '「继续阅读」用主色（参考图的蓝色文案）',
    );

    // 主色圆形播放钮 + 白色播放图标
    final Finder play = find.byKey(
      const ValueKey<String>('reader_shelf_continue_pill_play'),
    );
    expect(play, findsOneWidget, reason: '胶囊右侧是播放圆钮');
    final BoxDecoration playDecoration =
        tester.widget<DecoratedBox>(play).decoration as BoxDecoration;
    expect(playDecoration.color, cs.primary, reason: '播放钮是主色圆');
    expect(playDecoration.shape, BoxShape.circle);
    final FushiIcon playIcon = tester.widget<FushiIcon>(
      find.descendant(of: play, matching: find.byType(FushiIcon)),
    );
    expect(playIcon.color, cs.onPrimary, reason: '播放图标用主色上的对比色（白）');

    // 页签位在「漫画」标题右侧、右上角动作左侧。
    final Finder title = find.byKey(
      const ValueKey<String>('floating-chrome-shell-title'),
    );
    final Finder action = find.byKey(
      const ValueKey<String>('library_select_toggle'),
    );
    expect(title, findsOneWidget);
    expect(action, findsOneWidget);
    expect(
      tester.getTopLeft(pill).dx,
      greaterThan(tester.getTopRight(title).dx),
      reason: '胶囊排在「漫画」标题右侧',
    );
    expect(
      tester.getTopRight(pill).dx,
      lessThan(tester.getTopLeft(action).dx),
      reason: '胶囊排在右上角动作左侧',
    );
  });

  testWidgets('胶囊不显示书名与进度；整颗可点走原继续阅读打开路径，悬停 tooltip 显示书名', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga(
      'm1',
      '漫画一',
      position: 5,
      duration: 10,
    );
    await seedRecency(uid, 1000);
    await pumpPage(tester);

    final Finder pill = pillFinder();
    expect(pill, findsOneWidget);

    // 不显示书名与进度（保持参考图的紧凑形态）。
    expect(
      find.descendant(of: pill, matching: find.text('漫画一')),
      findsNothing,
      reason: '胶囊不显示书名',
    );
    expect(
      find.descendant(of: pill, matching: find.textContaining('%')),
      findsNothing,
      reason: '胶囊不显示进度百分比',
    );

    // 悬停 tooltip 显示书名（Tooltip 包在整颗胶囊外面）。
    final Finder tooltip = find.ancestor(
      of: pill,
      matching: find.byTooltip('漫画一'),
    );
    expect(tooltip, findsOneWidget, reason: '胶囊挂着书名 tooltip');

    final int titleTextsBefore = find.text('漫画一').evaluate().length;
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(pill));
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      find.text('漫画一').evaluate().length,
      greaterThan(titleTextsBefore),
      reason: '悬停胶囊时浮出书名 tooltip',
    );
    await mouse.removePointer();
    await tester.pump();

    // 点胶囊任意位置（含播放钮）都走原继续阅读路径。
    await tester.tap(
      find.descendant(of: pill, matching: find.text(t.book_continue_reading)),
    );
    await tester.pump();
    expect(appModel.opened, hasLength(1));
    expect(
      appModel.opened.single?.mediaIdentifier,
      ReaderFushiSource.mediaIdentifierFor('m1'),
      reason: '点文案继续阅读到当前在读书',
    );

    appModel.opened.clear();
    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_continue_pill_play')),
    );
    await tester.pump();
    expect(appModel.opened, hasLength(1), reason: '播放钮只是视觉强调，点它也继续阅读');
    expect(
      appModel.opened.single?.mediaIdentifier,
      ReaderFushiSource.mediaIdentifierFor('m1'),
    );
  });

  testWidgets('没有继续阅读条目时胶囊不渲染，顶部只剩「漫画」标题与右侧动作', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    expect(pillFinder(), findsNothing, reason: '无在读条目时整个胶囊隐藏');
    expect(
      find.byKey(const ValueKey<String>('floating-chrome-shell-title')),
      findsOneWidget,
      reason: '「漫画」标题仍在',
    );
    expect(
      find.byKey(const ValueKey<String>('library_select_toggle')),
      findsOneWidget,
      reason: '右上角动作仍在',
    );
  });

  testWidgets('网格顶部的旧继续阅读大卡片移除，胶囊是该页唯一入口', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga(
      'm1',
      '漫画一',
      position: 5,
      duration: 10,
    );
    await seedRecency(uid, 1000);
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey<String>('reader_shelf_continue_hero')),
      findsNothing,
      reason: '旧的大 hero 卡不再占据网格顶部',
    );
    expect(
      find.byKey(const ValueKey<String>('reader_shelf_continue_hero_progress')),
      findsNothing,
    );
    expect(
      find.text(t.book_continue_reading),
      findsOneWidget,
      reason: '「继续阅读」字样只出现在顶部胶囊这一处',
    );
  });

  testWidgets('胶囊随主 chrome 行一起向下收起、向上弹回', (WidgetTester tester) async {
    final String uid = await seedManga(
      'm0',
      '漫画0',
      position: 3,
      duration: 10,
    );
    for (int i = 1; i < 40; i++) {
      await seedManga('m$i', '漫画$i');
    }
    await seedRecency(uid, 1000);
    await pumpPage(tester, size: const Size(1000, 800));

    final Finder pill = pillFinder();
    expect(pill.hitTestable(), findsOneWidget, reason: '首屏胶囊可点');
    final Finder mainAction = find.byKey(
      const ValueKey<String>('library_select_toggle'),
    );
    expect(mainAction.hitTestable(), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(
      pill.hitTestable(),
      findsNothing,
      reason: '向下滚动后胶囊随主 chrome 行一起收起',
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(
      pill.hitTestable(),
      findsOneWidget,
      reason: '向上滚动后胶囊与主 chrome 行一起弹回',
    );
  });

  testWidgets('窄窗下中间区域可横向滚动，胶囊保持可见，右侧动作按现有规则收纳', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga(
      'm1',
      '漫画一',
      position: 5,
      duration: 10,
    );
    await seedRecency(uid, 1000);
    await pumpPage(tester, size: const Size(400, 800));

    final Finder pill = pillFinder();
    expect(pill, findsOneWidget, reason: '窄窗下胶囊仍渲染，不消失');
    expect(
      pill.hitTestable(),
      findsOneWidget,
      reason: '胶囊在窄窗里仍可点（中间区域横滚兜底）',
    );

    final Finder scroll = find.ancestor(
      of: pill,
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroll, findsOneWidget, reason: '中区可横向滚动');

    final double beforeX = tester.getTopLeft(pill).dx;
    await tester.drag(scroll, const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(pill).dx,
      lessThan(beforeX - 20),
      reason: '横向拖动可见胶囊的其余部分',
    );
  });
}
