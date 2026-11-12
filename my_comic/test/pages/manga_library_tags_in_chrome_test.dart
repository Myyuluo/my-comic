import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/manga/manga_library_page.dart';
import 'package:my_comic/src/media/tags/tag_chips.dart' show MyComicTagToggleChip;
import 'package:my_comic/src/pages/implementations/media_library_shell.dart';
import 'package:my_comic/src/pages/implementations/reader_my_comic_history_page.dart';
import 'package:my_comic/src/utils/components/my_comic_floating_chrome.dart'
    show MyComicFloatingChromeBar;
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic_core/my_comic_core.dart';

import 'manga_library_page_harness.dart';

/// 漫画页的标签栏在 ticket 06 曾占据原「书架」视图页签位；布局跟进 ticket 01
/// 起移到「漫画」标题 / 右上角动作行下方的**二级浮动行**（与在线源组二级胶囊
/// 同一套收放和顶部让位），形态是二级中性胶囊里的单选分段：首项「书架」+ 用户
/// 标签，点选即切换页签。
///
/// 页面级 seam（公共骨架见 [MangaLibraryPageHarness]）：挂真实页面（壳 + 书架
/// 页），标签走真 37 表 DB；书架列表 provider 覆写成受控列表，避开封面真 I/O。
/// 断言只落在用户可见的结果上：视图页签消失、标签行在主 chrome 行下方、空标签
/// 时仍有「书架」页签、点选筛选生效、随滚动收放、内容让位、长按不再排序。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(
    () => MangaLibraryPageHarness.setUpPathProvider(
      binding,
      tempPrefix: 'my_comic_manga_tags_chrome_pp',
    ),
  );
  tearDownAll(() => MangaLibraryPageHarness.tearDownPathProvider(binding));

  late MangaLibraryPageHarness<AppModel> harness;
  late MyComicDatabase db;

  setUp(() async {
    harness = await MangaLibraryPageHarness.create<AppModel>(
      tempPrefix: 'my_comic_manga_tags_chrome',
    );
    db = harness.db;
  });

  tearDown(() => harness.dispose());

  Future<String> seedManga(String bookKey, String title) =>
      harness.seedManga(bookKey, title);

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1400, 1200),
  }) => harness.pumpPage(tester, size: size);

  testWidgets('漫画页不再显示视图页签；标签页签在标题/动作行下方的二级浮动行', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    expect(
      find.byType(MyComicSectionTabBar<MediaLibraryViewKind>),
      findsNothing,
      reason: '漫画页只剩书架一个视图，不得再画视图页签分段条',
    );
    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    expect(tagBar, findsOneWidget, reason: '标签页签胶囊仍在页面里');
    final Finder mainBar = find.byType(MyComicFloatingChromeBar);
    expect(
      find.descendant(of: mainBar, matching: tagBar),
      findsNothing,
      reason: '标签栏已离开主 chrome 行的页签位',
    );
    expect(
      tester.getTopLeft(tagBar).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(mainBar).dy),
      reason: '标签栏是标题 / 动作行下方的二级浮动行',
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
    // 主 chrome 行的页签位在 ticket 01 后留空（继续阅读胶囊在 ticket 03 才落位）。
    expect(
      find.descendant(
        of: mainBar,
        matching: find.byKey(const ValueKey<String>('library_select_toggle')),
      ),
      findsOneWidget,
      reason: '右上角动作仍在主 chrome 行',
    );
  });

  testWidgets('标签页签只出现在二级浮动行，主 chrome 行不再有标题下的独立标签行', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);
    await db.createTag('短篇', 0xFF445566);
    await pumpPage(tester);

    final Finder mainBar = find.byType(MyComicFloatingChromeBar);
    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    for (final String name in <String>['连载', '短篇']) {
      expect(
        find.descendant(of: mainBar, matching: find.text(name)),
        findsNothing,
        reason: '标签页签「$name」不得再占主 chrome 行的页签位',
      );
      expect(
        find.descendant(of: tagBar, matching: find.text(name)),
        findsOneWidget,
        reason: '标签页签「$name」画在二级浮动行',
      );
      expect(
        find.text(name),
        findsOneWidget,
        reason: '标签只占二级行一处；标题下不再有独立标签行',
      );
    }

    // 二级行整体位于标题 / 动作行下方（不是同一行）。
    expect(
      tester.getTopLeft(tagBar).dy,
      greaterThan(tester.getBottomLeft(mainBar).dy),
      reason: '标签页签在标题 / 动作行下方，而不是与它们同一行',
    );
  });

  testWidgets('标签行是中性二级胶囊：选中段填充、贴合内容宽，数量用更轻的次要色', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);
    await pumpPage(tester);

    final BuildContext context = tester.element(find.byType(MangaLibraryPage));
    final ColorScheme cs = Theme.of(context).colorScheme;

    final Finder capsuleFinder = find.byKey(
      const ValueKey<String>('manga_tag_tab_capsule'),
    );
    expect(capsuleFinder, findsOneWidget, reason: '标签行收在一枚二级胶囊里');
    // 胶囊外框是共享的 MyComicCompactSecondaryTabsFrame（与库页二级页签同源），
    // 绘底的 DecoratedBox 在它里面。
    final Finder capsuleSurface = find.descendant(
      of: capsuleFinder,
      matching: find.byType(DecoratedBox),
    );
    final ShapeDecoration capsule =
        tester.widget<DecoratedBox>(capsuleSurface.first).decoration
            as ShapeDecoration;
    expect(
      capsule.color,
      cs.surfaceContainerHigh,
      reason: '二级胶囊是中性 surfaceContainerHigh，不再是一级悬浮工具栏胶囊',
    );

    final Finder shelf = find.byKey(
      const ValueKey<String>('manga_tag_tab_shelf'),
    );
    final AnimatedContainer fill = tester.widget<AnimatedContainer>(
      find.descendant(of: shelf, matching: find.byType(AnimatedContainer)),
    );
    expect(
      (fill.decoration! as ShapeDecoration).color,
      cs.secondaryContainer,
      reason: '选中段用 secondaryContainer 填充',
    );

    // 内容宽：两个页签远窄于整行可用宽。
    expect(
      tester.getSize(capsuleSurface.first).width,
      lessThan(600),
      reason: '胶囊贴合内容宽，不拉满整行',
    );

    // 数量用更轻的次要色小号数字，不与标签名同强度。
    final Text label = tester.widget<Text>(
      find.descendant(of: shelf, matching: find.text(t.library_view_shelf)),
    );
    final Text count = tester.widget<Text>(
      find.byKey(const ValueKey<String>('manga_tag_tab_count_shelf')),
    );
    expect(
      count.style?.color,
      isNot(label.style?.color),
      reason: '数量是更轻的次要色，不与标签名同色',
    );
    expect(
      count.style?.color?.a ?? 1,
      lessThan(1),
      reason: '数量颜色更轻（半透明次要色）',
    );
    expect(
      count.style?.fontSize,
      lessThanOrEqualTo(label.style?.fontSize ?? 14),
      reason: '数量是小号数字',
    );
  });

  testWidgets('标签行与主 chrome 行一起向下收起、向上弹回', (
    WidgetTester tester,
  ) async {
    for (int i = 0; i < 40; i++) {
      await seedManga('m$i', '漫画$i');
    }
    await pumpPage(tester, size: const Size(1000, 800));

    final Finder shelf = find.byKey(
      const ValueKey<String>('manga_tag_tab_shelf'),
    );
    final Finder mainAction = find.byKey(
      const ValueKey<String>('library_select_toggle'),
    );
    expect(shelf.hitTestable(), findsOneWidget, reason: '首屏标签行可点');
    expect(mainAction.hitTestable(), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(
      shelf.hitTestable(),
      findsNothing,
      reason: '向下滚动后标签行随主 chrome 行一起收起（同一份显隐）',
    );
    expect(
      mainAction.hitTestable(),
      findsNothing,
      reason: '主 chrome 行同时收起',
    );

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(
      shelf.hitTestable(),
      findsOneWidget,
      reason: '向上滚动后标签行与主 chrome 行一起弹回',
    );
  });

  testWidgets('内容首行让出两级浮动行，不被标签行遮挡', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    final Finder firstCard = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderMyComicSource.mediaIdentifierFor('m1')}',
      ),
    );
    expect(firstCard, findsOneWidget);
    expect(
      tester.getTopLeft(firstCard).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(tagBar).dy),
      reason: '网格首行从两级浮动行的下沿开始，不被标签行遮挡',
    );
  });

  testWidgets('标签多到放不下时在胶囊内横滚，「书架」固定可见', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    final List<int> tagIds = <int>[];
    for (int i = 0; i < 12; i++) {
      tagIds.add(
        await db.createTag('超长标签名称用于横向滚动测试$i', 0xFF112233),
      );
    }
    await pumpPage(tester);

    final Finder scroll = find.descendant(
      of: find.byKey(const ValueKey<String>('manga_tag_tab_bar')),
      matching: find.byType(SingleChildScrollView),
    );
    expect(scroll, findsOneWidget, reason: '标签区在胶囊内横向滚动');

    final Finder shelf = find.byKey(
      const ValueKey<String>('manga_tag_tab_shelf'),
    );
    final double shelfX = tester.getCenter(shelf).dx;
    final Finder lastTag = find.byKey(
      ValueKey<String>('manga_tag_tab_${tagIds.last}'),
    );
    final double beforeX = tester.getTopLeft(lastTag).dx;
    expect(
      beforeX,
      greaterThan(tester.view.physicalSize.width),
      reason: '最后一枚标签初始在胶囊视口外',
    );

    await tester.drag(scroll, const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(lastTag).dx,
      lessThan(beforeX - 100),
      reason: '标签区可横向滚动',
    );
    expect(
      tester.getCenter(shelf).dx,
      shelfX,
      reason: '「书架」固定在最左，不随标签区横滚',
    );
  });

  testWidgets('漫画页页头「管理标签」动作使用标签图标', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    final Finder manage = find.byKey(
      const ValueKey<String>('library_tag_settings'),
    );
    expect(manage, findsOneWidget, reason: '漫画页页头必须有管理标签入口');
    final MyComicIconButton button = tester.widget<MyComicIconButton>(manage);
    expect(
      button.icon,
      MyComicIcons.tag,
      reason: '管理标签入口与标签选择 / 管理页使用同一标签图标，不得再用齿轮',
    );
  });

  testWidgets('没有标签时二级行仍有「书架」页签，不出现彩色 chip', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    expect(
      find.byType(MyComicTagToggleChip),
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
      find.byType(MyComicFloatingChromeBar),
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

  testWidgets('点击二级行里的标签页签切换筛选，点回「书架」恢复默认', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await seedManga('m2', '漫画二');
    final int tagId = await db.createTag('连载', 0xFF112233);
    await db.addTagToBook('m1', tagId);
    await pumpPage(tester);

    final Finder card1 = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderMyComicSource.mediaIdentifierFor('m1')}',
      ),
    );
    final Finder card2 = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderMyComicSource.mediaIdentifierFor('m2')}',
      ),
    );
    // 默认「书架」只收无标签漫画。
    expect(card2, findsOneWidget, reason: '书架显示无标签漫画');
    expect(card1, findsNothing, reason: '有标签漫画不在书架');

    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    await tester.tap(find.descendant(of: tagBar, matching: find.text('连载')));
    await tester.pumpAndSettle();

    expect(card1, findsOneWidget, reason: '标签页签显示对应漫画');
    expect(card2, findsNothing, reason: '无标签漫画不在标签页签');
    expect(
      find.byKey(const ValueKey<String>('library_tag_clear_chip')),
      findsNothing,
      reason: '单选页签没有多选「清除筛选」chip',
    );

    await tester.tap(find.descendant(of: tagBar, matching: find.text('书架')));
    await tester.pumpAndSettle();

    expect(card2, findsOneWidget, reason: '点回书架恢复无标签漫画');
    expect(card1, findsNothing);
  });

  testWidgets('在二级行里长按拖动标签页签不再排序', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await db.createTag('连载', 0xFF112233);
    await db.createTag('短篇', 0xFF445566);
    await pumpPage(tester);

    Future<List<String>> tagOrder() async =>
        (await db.getAllTags()).map((BookTagRow tag) => tag.name).toList();
    expect(await tagOrder(), <String>['连载', '短篇']);

    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    final Finder chipA = find.descendant(
      of: tagBar,
      matching: find.text('连载'),
    );
    final Finder chipB = find.descendant(
      of: tagBar,
      matching: find.text('短篇'),
    );
    expect(
      find.descendant(
        of: tagBar,
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

  testWidgets('「管理标签」仍在主 chrome 右上角动作组，标签行本身没有管理入口', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    final Finder manage = find.byKey(
      const ValueKey<String>('library_tag_settings'),
    );
    expect(manage, findsOneWidget, reason: '管理标签入口仍在页面上');
    expect(
      find.descendant(
        of: find.byType(MyComicFloatingChromeBar),
        matching: manage,
      ),
      findsOneWidget,
      reason: '管理标签入口属于主 chrome 行右侧动作组',
    );
    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    expect(
      find.descendant(of: tagBar, matching: manage),
      findsNothing,
      reason: '标签行本身不承担管理入口',
    );
    expect(
      find.descendant(of: tagBar, matching: find.text(t.tag_manage)),
      findsNothing,
      reason: '标签行里不再出现「管理标签」文字入口',
    );
  });

  testWidgets('搜索词在二级标签行下仍只在当前页签内生效，数量同步', (
    WidgetTester tester,
  ) async {
    await seedManga('m1', 'Alpha 起点');
    await seedManga('m2', 'Beta 连载');
    await seedManga('m3', 'Alpha 续');
    final int tagA = await db.createTag('连载', 0xFF112233);
    await db.createTag('短篇', 0xFF445566);
    await db.addTagToBook('m2', tagA);
    await db.addTagToBook('m3', tagA);
    await pumpPage(tester);

    Finder card(String bookKey) => find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderMyComicSource.mediaIdentifierFor(bookKey)}',
      ),
    );
    String countText(String scope) => tester
        .widget<Text>(
          find.byKey(ValueKey<String>('manga_tag_tab_count_$scope')),
        )
        .data!;

    expect(countText('shelf'), '1');
    expect(countText('$tagA'), '2');

    await tester.tap(
      find.byKey(const ValueKey<String>('mycomic-header-search-button')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      'Alpha',
    );
    await tester.pumpAndSettle();

    expect(countText('shelf'), '1', reason: '书架命中 Alpha 的无标签漫画');
    expect(countText('$tagA'), '1', reason: '连载下只有 m3 命中 Alpha');
    expect(card('m1'), findsOneWidget);
    expect(card('m2'), findsNothing, reason: '搜索只在当前页签（书架）内生效');

    // 搜索栏展开时标签行仍在二级行，点选后筛选切到该页签。
    final Finder tagBar = find.byKey(
      const ValueKey<String>('manga_tag_tab_bar'),
    );
    await tester.tap(find.descendant(of: tagBar, matching: find.text('连载')));
    await tester.pumpAndSettle();

    expect(card('m3'), findsOneWidget, reason: '连载下命中 Alpha 的 m3');
    expect(card('m2'), findsNothing);
    expect(card('m1'), findsNothing);
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
      harness.buildScaffold(
        title: t.books,
        child: MediaLibraryShell(
          focusIdPrefix: 'book-library-view',
          views: <MediaLibraryViewSpec>[
            MediaLibraryViewSpec(
              kind: MediaLibraryViewKind.library,
              label: '书架',
              handlesChromeInset: true,
              // 普通书架：mangaOnly 默认为 false，不受漫画页改动影响。
              builder: (BuildContext context, Widget navigation) =>
                  ReaderMyComicHistoryPage(navigation: navigation),
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
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(MyComicSectionTabBar<MediaLibraryViewKind>),
      findsOneWidget,
      reason: '普通书籍页的视图页签不受漫画页改动影响',
    );
    expect(
      find.descendant(
        of: find.byType(MyComicFloatingChromeBar),
        matching: find.text('连载'),
      ),
      findsNothing,
      reason: '普通书籍页的标签仍不在浮动 chrome 页签位',
    );
    expect(find.text('连载'), findsOneWidget, reason: '普通书籍页标题下仍有独立标签行');
  });

  testWidgets('壳里的页头搜索按钮可见且能打开搜索栏', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    final Finder searchButton = find.byKey(
      const ValueKey<String>('mycomic-header-search-button'),
    );
    expect(searchButton, findsOneWidget);
    expect(searchButton.hitTestable(), findsOneWidget, reason: '搜索按钮必须在命中区内');

    await tester.tap(searchButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      findsOneWidget,
    );
  });

  testWidgets('页头搜索第一次输入不会丢焦点', (WidgetTester tester) async {
    await seedManga('m1', '漫画一');
    await pumpPage(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('mycomic-header-search-button')),
    );
    await tester.pumpAndSettle();

    final Finder field = find.byKey(
      const ValueKey<String>('shelf_search_field'),
    );
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '展开搜索后输入框应已聚焦',
    );

    // 模拟 IME 输入第一个字符，不走 tester.enterText 的重新聚焦路径。
    tester.testTextInput.enterText('漫');
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '首次输入后焦点必须保持在搜索框',
    );
    expect(tester.widget<TextField>(field).controller?.text, '漫');
  });
}
