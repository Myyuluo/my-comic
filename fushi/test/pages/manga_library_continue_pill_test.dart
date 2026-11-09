import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar;
import 'package:fushi/utils.dart';

import 'manga_library_page_harness.dart';

/// 漫画页布局跟进 ticket 03：继续阅读入口从网格顶部的大 hero 卡变成主 chrome
/// 行里的一枚紧凑胶囊（tag bar 原来的页签位，「漫画」标题右侧、右上角动作左侧）。
///
/// 页面级 seam（公共骨架见 [MangaLibraryPageHarness]）：挂真实页面（壳 + 书架
/// 页），书架列表 provider 受控，阅读历史落真 `reader_positions` 表。断言只落在
/// 用户可见的结果上：胶囊在哪、长什么样、点它是否走原继续阅读路径、无候选是否
/// 隐藏、滚动手势是否随 chrome 收放、窄窗是否仍能看到。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(
    () => MangaLibraryPageHarness.setUpPathProvider(
      binding,
      tempPrefix: 'fushi_manga_continue_pill_pp',
    ),
  );
  tearDownAll(() => MangaLibraryPageHarness.tearDownPathProvider(binding));

  late MangaLibraryPageHarness<RecordingAppModel> harness;
  late RecordingAppModel appModel;

  setUp(() async {
    harness = await MangaLibraryPageHarness.create<RecordingAppModel>(
      tempPrefix: 'fushi_manga_pill',
      appModelFactory: RecordingAppModel.new,
    );
    appModel = harness.appModel;
  });

  tearDown(() => harness.dispose());

  Future<String> seedManga(
    String bookKey,
    String title, {
    int position = 0,
    int duration = 1,
  }) => harness.seedManga(
    bookKey,
    title,
    position: position,
    duration: duration,
  );

  Future<void> seedRecency(String uid, int updatedAt) =>
      harness.seedRecency(uid, updatedAt);

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1400, 1200),
  }) => harness.pumpPage(tester, size: size);

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

  testWidgets('整颗胶囊可点：悬浮面内衬（留白）也是继续阅读点击目标', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga('m1', '漫画一', position: 5, duration: 10);
    await seedRecency(uid, 1000);
    await pumpPage(tester);

    final Finder pill = pillFinder();
    expect(pill, findsOneWidget);
    final Rect pillRect = tester.getRect(pill);

    // 点左缘内 3px、垂直居中：落在悬浮胶囊表面的横向内衬（6px）里，位于
    // 内部胶囊段（封面 / 文案 / 播放钮）之外。没有整颗点击目标时这里点不动。
    await tester.tapAt(Offset(pillRect.left + 3, pillRect.center.dy));
    await tester.pump();

    expect(appModel.opened, hasLength(1), reason: '点胶囊留白也走继续阅读打开路径');
    expect(
      appModel.opened.single?.mediaIdentifier,
      ReaderFushiSource.mediaIdentifierFor('m1'),
    );
  });

  testWidgets('胶囊 tooltip 书名经显示名 override（编辑弹窗改名）', (
    WidgetTester tester,
  ) async {
    final String uid = await seedManga(
      'm-override',
      '原名',
      position: 5,
      duration: 10,
    );
    await seedRecency(uid, 1000);
    await ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
      item: harness.mangaItems.single,
      title: '改名漫画',
    );
    addTearDown(
      () => ReaderFushiSource.instance.setOverrideTitleFromMediaItem(
        item: harness.mangaItems.single,
        title: null,
      ),
    );
    await pumpPage(tester);

    final Finder pill = pillFinder();
    expect(pill, findsOneWidget);
    expect(
      find.ancestor(of: pill, matching: find.byTooltip('改名漫画')),
      findsOneWidget,
      reason: 'tooltip 书名应用编辑弹窗写入的 override，不直读 DB 原名',
    );
    expect(
      find.ancestor(of: pill, matching: find.byTooltip('原名')),
      findsNothing,
      reason: '改名后不得再显示 DB 原始书名',
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

  testWidgets('胶囊跟随当前标签页签切换候选，点击打开该标签的最近阅读', (
    WidgetTester tester,
  ) async {
    final String shelfUid = await seedManga(
      'm-shelf',
      '无标签漫画',
      position: 5,
      duration: 10,
    );
    final String taggedUid = await seedManga(
      'm-tagged',
      '标签漫画',
      position: 5,
      duration: 10,
    );
    final String otherTaggedUid = await seedManga(
      'm-other-tag',
      '第二标签漫画',
      position: 5,
      duration: 10,
    );
    // 全局最近阅读是无标签那本；两个标签各有自己的最近阅读。
    await seedRecency(shelfUid, 3000);
    await seedRecency(taggedUid, 2000);
    await seedRecency(otherTaggedUid, 1000);
    final int tagId = await harness.db.createTag('连载', 0xFF112233);
    final int otherTagId = await harness.db.createTag('完结', 0xFF445566);
    await harness.db.addTagToBook('m-tagged', tagId);
    await harness.db.addTagToBook('m-other-tag', otherTagId);
    await pumpPage(tester);

    final Finder pill = pillFinder();
    expect(
      find.ancestor(of: pill, matching: find.byTooltip('无标签漫画')),
      findsOneWidget,
      reason: '书架页签显示书架内最近阅读',
    );

    await tester.tap(
      find.byKey(ValueKey<String>('manga_tag_tab_$tagId')),
    );
    await tester.pumpAndSettle();

    expect(
      find.ancestor(of: pill, matching: find.byTooltip('标签漫画')),
      findsOneWidget,
      reason: '切换到标签页签后胶囊跟随该标签的最近阅读',
    );
    await tester.tap(pill);
    await tester.pump();
    expect(appModel.opened, hasLength(1));
    expect(
      appModel.opened.single?.mediaIdentifier,
      ReaderFushiSource.mediaIdentifierFor('m-tagged'),
      reason: '点击胶囊打开当前标签的最近阅读作品',
    );

    appModel.opened.clear();
    await tester.tap(
      find.byKey(ValueKey<String>('manga_tag_tab_$otherTagId')),
    );
    await tester.pumpAndSettle();
    expect(
      find.ancestor(of: pill, matching: find.byTooltip('第二标签漫画')),
      findsOneWidget,
      reason: '切换另一个标签后胶囊再次跟随该标签的最近阅读',
    );
    await tester.tap(pill);
    await tester.pump();
    expect(
      appModel.opened.single?.mediaIdentifier,
      ReaderFushiSource.mediaIdentifierFor('m-other-tag'),
    );
  });
}
