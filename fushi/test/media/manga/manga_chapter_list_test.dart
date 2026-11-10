import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 章节列表被**两个**界面共用（作品页正文 + 阅读器里的章节弹层）。两处对
/// 「已读怎么显示、当前章怎么高亮、排序默认哪个方向」的答案必须一致，所以这些
/// 语义钉在组件上而不是各自的宿主页面上。
void main() {
  const OnlineMangaChapter newest = OnlineMangaChapter(
    key: '/c/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{},
  );
  const OnlineMangaChapter middle = OnlineMangaChapter(
    key: '/c/2',
    name: 'Chapter 2',
    number: 2,
    scanlator: 'Fixture scans',
    raw: <String, Object?>{},
  );
  const OnlineMangaChapter oldest = OnlineMangaChapter(
    key: '/c/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{},
  );

  // 源按新→旧返回，列表 0 是最新一话。
  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    newest,
    middle,
    oldest,
  ];

  OnlineMangaLibraryEntry entryWith(List<OnlineMangaChapter> items) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '1',
        series: const OnlineMangaSeries(
          key: '/s',
          title: 'Fixture',
          raw: <String, Object?>{},
        ),
        chapters: items,
      );

  Future<void> pumpList(
    WidgetTester tester, {
    required OnlineMangaLibraryEntry? entry,
    Map<String, MangaChapterStateRow> states =
        const <String, MangaChapterStateRow>{},
    bool newestFirst = true,
    bool unreadOnly = false,
    MangaChapterDownloadFilter downloadFilter = MangaChapterDownloadFilter.all,
    String? currentChapterKey,
    Set<String> downloadedChapterKeys = const <String>{},
    Set<String> missingChapterKeys = const <String>{},
    Set<String>? selectedChapterKeys,
    ThemeData? theme,
    void Function(OnlineMangaChapter)? onChapterTap,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MangaChapterList(
              entry: entry,
              states: states,
              newestFirst: newestFirst,
              unreadOnly: unreadOnly,
              downloadFilter: downloadFilter,
              currentChapterKey: currentChapterKey,
              downloadedChapterKeys: downloadedChapterKeys,
              missingChapterKeys: missingChapterKeys,
              selectedChapterKeys: selectedChapterKeys,
              onChapterTap: onChapterTap ?? (OnlineMangaChapter _) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// 按屏幕纵坐标读出当前可见的章节标题顺序。
  List<String> visibleTitles(WidgetTester tester) {
    final List<({double dy, String text})> found =
        <({double dy, String text})>[];
    for (final Element element in find.byType(Text).evaluate()) {
      final Text widget = element.widget as Text;
      final String? data = widget.data;
      if (data == null || !data.startsWith('Chapter ')) continue;
      found.add((dy: tester.getTopLeft(find.byWidget(widget)).dy, text: data));
    }
    found.sort(
      (({double dy, String text}) a, ({double dy, String text}) b) =>
          a.dy.compareTo(b.dy),
    );
    return found.map((({double dy, String text}) e) => e.text).toList();
  }

  testWidgets('显式 missing 集覆盖已下载状态（Local source 旧 Content root）', (
    WidgetTester tester,
  ) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      downloadedChapterKeys: <String>{'/c/2'},
      missingChapterKeys: <String>{'/c/2'},
    );

    expect(
      find.textContaining(t.manga_chapter_download_status_missing),
      findsOneWidget,
    );
    expect(
      find.textContaining(t.manga_chapter_download_status_downloaded),
      findsNothing,
    );
  });

  testWidgets('默认保持源顺序（新→旧）；翻转后第 1 话在前', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(chapters));
    expect(visibleTitles(tester), <String>[
      'Chapter 3',
      'Chapter 2',
      'Chapter 1',
    ]);

    await pumpList(tester, entry: entryWith(chapters), newestFirst: false);
    expect(visibleTitles(tester), <String>[
      'Chapter 1',
      'Chapter 2',
      'Chapter 3',
    ], reason: '「最早在前」必须真的翻转，而不是只改按钮文案');
  });

  testWidgets('导入章节按 sourceOrder 显示：最新在前，第一话在前正确反转', (
    WidgetTester tester,
  ) async {
    // 备份数组顺序（旧→新）不是显示契约：sourceOrder 0 = 最新一话。
    const List<OnlineMangaChapter> imported = <OnlineMangaChapter>[
      OnlineMangaChapter(
        key: '/c/2',
        name: 'Chapter 2',
        sourceOrder: 1,
        raw: <String, Object?>{},
      ),
      OnlineMangaChapter(
        key: '/c/3',
        name: 'Chapter 3',
        sourceOrder: 0,
        raw: <String, Object?>{},
      ),
      OnlineMangaChapter(
        key: '/c/1',
        name: 'Chapter 1',
        sourceOrder: 2,
        raw: <String, Object?>{},
      ),
    ];

    await pumpList(tester, entry: entryWith(imported));
    expect(visibleTitles(tester), <String>[
      'Chapter 3',
      'Chapter 2',
      'Chapter 1',
    ]);

    await pumpList(tester, entry: entryWith(imported), newestFirst: false);
    expect(visibleTitles(tester), <String>[
      'Chapter 1',
      'Chapter 2',
      'Chapter 3',
    ]);

    final List<String> tapped = <String>[];
    await pumpList(
      tester,
      entry: entryWith(imported),
      onChapterTap: (OnlineMangaChapter chapter) => tapped.add(chapter.key),
    );
    await tester.tap(find.text('Chapter 2'));
    await tester.pump();
    expect(tapped, <String>['/c/2'], reason: '显示排序不改变章节身份');
  });

  testWidgets('没有 sourceOrder 时按章节号显示最新在前', (WidgetTester tester) async {
    final List<OnlineMangaChapter> byNumber = <OnlineMangaChapter>[
      const OnlineMangaChapter(
        key: '/c/2',
        name: 'Chapter 2',
        number: 2,
        raw: <String, Object?>{},
      ),
      const OnlineMangaChapter(
        key: '/c/3',
        name: 'Chapter 3',
        number: 3,
        raw: <String, Object?>{},
      ),
      const OnlineMangaChapter(
        key: '/c/1',
        name: 'Chapter 1',
        number: 1,
        raw: <String, Object?>{},
      ),
    ];

    await pumpList(tester, entry: entryWith(byNumber));
    expect(visibleTitles(tester), <String>[
      'Chapter 3',
      'Chapter 2',
      'Chapter 1',
    ]);

    await pumpList(tester, entry: entryWith(byNumber), newestFirst: false);
    expect(visibleTitles(tester), <String>[
      'Chapter 1',
      'Chapter 2',
      'Chapter 3',
    ]);
  });

  // 2026-10 M3E：行是 MediaDetailItemRow。已读 = 行尾 tertiary 对勾（key
  // media-detail-item-completed）、读了一半 = 副标题「读到第 N 页」（知道总页数
  // 时另有行内进度条）、未读两样都没有。
  testWidgets('已读 / 读了一半 / 未读三态可区分', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
        '/c/2': _state(chapterKey: '/c/2', lastPage: 5),
      },
    );

    final Finder completed = find.byKey(
      const ValueKey<String>('media-detail-item-completed'),
    );
    expect(completed, findsOneWidget, reason: 'readAt != null = 已读');
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Chapter 3'),
          matching: find.byType(MediaDetailItemRow),
        ),
        matching: completed,
      ),
      findsOneWidget,
      reason: '对勾落在已读的那一行',
    );
    expect(
      find.textContaining(t.manga_series_read_progress_partial(page: '6')),
      findsOneWidget,
      reason: '有状态行、没读完、且真的翻过页 = 读了一半',
    );
  });

  testWidgets('lastPage 为 0 不算「读了一半」', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(<OnlineMangaChapter>[oldest]),
      states: <String, MangaChapterStateRow>{
        '/c/1': _state(chapterKey: '/c/1'),
      },
    );
    expect(
      find.textContaining(t.manga_series_read_progress_partial(page: '1')),
      findsNothing,
      reason: '开了一下就退出不该显示成「读到第 1 页」，那是误导',
    );
    expect(
      find.byKey(const ValueKey<String>('media-detail-item-completed')),
      findsNothing,
    );
  });

  // 2026-11 当前章样式：整行底色 / 序号胶囊主色 / 标题加粗都撤销，只留标题
  // 文字主色；读了一半的进度条仍在。普通行、已读行维持原样。
  testWidgets('当前章只把标题文字染成主色，普通行与已读行不变', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
        '/c/2': _state(chapterKey: '/c/2', lastPage: 5, pageCount: 20),
      },
    );
    final ColorScheme cs = Theme.of(
      tester.element(find.text('Chapter 1')),
    ).colorScheme;

    final Text currentTitle = tester.widget<Text>(find.text('Chapter 2'));
    final Text normalTitle = tester.widget<Text>(find.text('Chapter 1'));
    final Text readTitle = tester.widget<Text>(find.text('Chapter 3'));

    expect(currentTitle.style?.color, cs.primary, reason: '当前章只靠标题主色定位');
    expect(normalTitle.style?.color, cs.onSurface, reason: '普通行文字色不变');
    expect(readTitle.style?.color, cs.onSurfaceVariant, reason: '已读行的降调文字色不变');
    expect(
      currentTitle.style?.fontWeight,
      normalTitle.style?.fontWeight,
      reason: '当前章标题不再使用 emphasized 字重',
    );
    expect(currentTitle.style?.fontSize, normalTitle.style?.fontSize);
  });

  testWidgets('当前章的副标题小字也跟随标题染成主色', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
      states: <String, MangaChapterStateRow>{
        '/c/2': _state(chapterKey: '/c/2', lastPage: 5, pageCount: 20),
      },
    );
    final ColorScheme cs = Theme.of(
      tester.element(find.text('Chapter 1')),
    ).colorScheme;
    final Finder currentRow = find.ancestor(
      of: find.text('Chapter 2'),
      matching: find.byType(MediaDetailItemRow),
    );
    final Finder currentSubtitle = find.descendant(
      of: currentRow,
      matching: find.textContaining(
        t.manga_series_read_progress(page: '6', total: '20'),
      ),
    );
    expect(currentSubtitle, findsOneWidget);
    expect(
      tester.widget<Text>(currentSubtitle).style?.color,
      cs.primary,
      reason: '当前章标题下方的小字也跟随标题变主色',
    );

    final Finder normalRow = find.ancestor(
      of: find.text('Chapter 1'),
      matching: find.byType(MediaDetailItemRow),
    );
    final Finder normalSubtitle = find.descendant(
      of: normalRow,
      matching: find.textContaining(t.manga_chapter_not_downloaded),
    );
    expect(normalSubtitle, findsOneWidget);
    expect(
      tester.widget<Text>(normalSubtitle).style?.color,
      cs.onSurfaceVariant,
      reason: '普通行副标题保持次要色',
    );
  });

  testWidgets('当前章行无背景，且不再有号码胶囊', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
    );
    final Finder currentRow = find.ancestor(
      of: find.text('Chapter 2'),
      matching: find.byType(MediaDetailItemRow),
    );
    final FushiGroupedListItem shell = tester.widget<FushiGroupedListItem>(
      find
          .descendant(
            of: currentRow,
            matching: find.byType(FushiGroupedListItem),
          )
          .first,
    );
    expect(shell.color, isNull, reason: '整行底色（含 Apple 的半透明前景罩）必须移除');

    final MediaDetailItemRow row = tester.widget<MediaDetailItemRow>(
      currentRow,
    );
    expect(row.number, isNull, reason: '章节号胶囊在所有章节列表里都不再渲染');
    expect(
      find.descendant(of: currentRow, matching: find.text('2')),
      findsNothing,
      reason: '画面上不能只剩一个孤立的章号',
    );
  });

  testWidgets('当前章读了一半仍显示行内进度条', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
      states: <String, MangaChapterStateRow>{
        '/c/2': _state(chapterKey: '/c/2', lastPage: 5, pageCount: 20),
      },
    );
    final Finder currentRow = find.ancestor(
      of: find.text('Chapter 2'),
      matching: find.byType(MediaDetailItemRow),
    );
    expect(
      find.descendant(
        of: currentRow,
        matching: find.byType(FushiLinearProgressIndicator),
      ),
      findsOneWidget,
      reason: '当前章只换文字色，读了一半的进度条保留',
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Chapter 1'),
          matching: find.byType(MediaDetailItemRow),
        ),
        matching: find.byType(FushiLinearProgressIndicator),
      ),
      findsNothing,
      reason: '未读的普通行不凭空出现进度条',
    );
  });

  testWidgets('Apple 玻璃主题下当前章也没有整行前景罩', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      currentChapterKey: '/c/2',
      theme: ThemeData(
        extensions: const <ThemeExtension<dynamic>>[
          FushiGlassTheme(FushiGlassMaterial.off, glassDesign: true),
        ],
      ),
    );
    final Finder currentRow = find.ancestor(
      of: find.text('Chapter 2'),
      matching: find.byType(MediaDetailItemRow),
    );
    final FushiGroupedListItem shell = tester.widget<FushiGroupedListItem>(
      find
          .descendant(
            of: currentRow,
            matching: find.byType(FushiGroupedListItem),
          )
          .first,
    );
    expect(shell.color, isNull, reason: 'Apple 用半透明主色做前景罩，也必须移除');
    final ColorScheme cs = Theme.of(
      tester.element(find.text('Chapter 1')),
    ).colorScheme;
    expect(
      tester.widget<Text>(find.text('Chapter 2')).style?.color,
      cs.primary,
    );
  });

  testWidgets('章节行不再带话数序号、分段排布且不被撑高', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(chapters));
    final List<MediaDetailItemRow> rows = tester
        .widgetList<MediaDetailItemRow>(find.byType(MediaDetailItemRow))
        .toList();
    expect(rows, hasLength(3));
    expect(
      rows.every((MediaDetailItemRow row) => row.number == null),
      isTrue,
      reason: '导入作品的「第 N 话」标题已经带号码，行首胶囊不再重复',
    );
    for (final String number in <String>['3', '2', '1']) {
      expect(
        find.descendant(
          of: find.byType(MediaDetailItemRow),
          matching: find.text(number),
        ),
        findsNothing,
        reason: '行内不应出现号码胶囊文字 $number',
      );
    }
    expect(
      rows.map((MediaDetailItemRow row) => (row.index, row.count)),
      <(int, int)>[(0, 3), (1, 3), (2, 3)],
      reason: '分段列表靠 index / count 决定组首尾圆角',
    );
    final List<Element> elements = find
        .byType(MediaDetailItemRow)
        .evaluate()
        .toList();
    final Rect first = tester.getRect(find.byWidget(elements.first.widget));
    final Rect second = tester.getRect(find.byWidget(elements[1].widget));
    expect(second.top, greaterThanOrEqualTo(first.bottom));
    // 标题 + 一行元信息的章节行不超过 M3E 三行列表项高（88）。
    expect(first.height, lessThanOrEqualTo(88));
  });

  testWidgets('多选模式保留勾选标记，同时不再显示号码胶囊', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      selectedChapterKeys: <String>{'/c/2'},
    );
    final List<MediaDetailItemRow> rows = tester
        .widgetList<MediaDetailItemRow>(find.byType(MediaDetailItemRow))
        .toList();
    expect(
      rows.map((MediaDetailItemRow row) => row.number),
      everyElement(isNull),
      reason: '多选模式也不能把号码胶囊带回来',
    );
    expect(rows.map((MediaDetailItemRow row) => row.selected), <bool?>[
      false,
      true,
      false,
    ], reason: '行首选择标记保留：选中行 true，未选中行 false（null = 非多选态）');
    List<IconData?> iconsIn(String title) => tester
        .widgetList<FushiIcon>(
          find.descendant(
            of: find.ancestor(
              of: find.text(title),
              matching: find.byType(MediaDetailItemRow),
            ),
            matching: find.byType(FushiIcon),
          ),
        )
        .map((FushiIcon icon) => icon.icon)
        .toList();
    expect(
      iconsIn('Chapter 2'),
      contains(FushiIcons.filled(FushiIcons.success)),
      reason: '选中行仍显示实心勾选标记',
    );
    expect(
      iconsIn('Chapter 1'),
      contains(FushiIcons.addCircle),
      reason: '未选中行仍显示空心选择圈',
    );
  });

  testWidgets('只看未读会滤掉已读的章', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
      },
    );
    expect(visibleTitles(tester), <String>['Chapter 2', 'Chapter 1']);
  });

  testWidgets('章节标题显示「只看未读」后的可见数量', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      states: <String, MangaChapterStateRow>{
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
      },
    );
    expect(find.text(t.manga_series_chapters_count(count: 2)), findsOneWidget);
    expect(find.text(t.manga_series_chapters_count(count: 3)), findsNothing);
  });

  testWidgets('章节标题跟随「全部 / 已下载 / 未下载」筛选', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      downloadedChapterKeys: <String>{'/c/2'},
    );
    expect(find.text(t.manga_series_chapters_count(count: 3)), findsOneWidget);

    await pumpList(
      tester,
      entry: entryWith(chapters),
      downloadedChapterKeys: <String>{'/c/2'},
      downloadFilter: MangaChapterDownloadFilter.downloaded,
    );
    expect(find.text(t.manga_series_chapters_count(count: 1)), findsOneWidget);

    await pumpList(
      tester,
      entry: entryWith(chapters),
      downloadedChapterKeys: <String>{'/c/2'},
      downloadFilter: MangaChapterDownloadFilter.notDownloaded,
    );
    expect(find.text(t.manga_series_chapters_count(count: 2)), findsOneWidget);
  });

  testWidgets('「只看未读」与下载筛选 AND 后计数', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      downloadFilter: MangaChapterDownloadFilter.downloaded,
      downloadedChapterKeys: <String>{'/c/1', '/c/2'},
      states: <String, MangaChapterStateRow>{
        '/c/1': _state(chapterKey: '/c/1', readAt: 1),
        '/c/3': _state(chapterKey: '/c/3', readAt: 1),
      },
    );
    expect(find.text(t.manga_series_chapters_count(count: 1)), findsOneWidget);
  });

  testWidgets('空列表显示「共 0 章」', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(const <OnlineMangaChapter>[]));
    expect(find.text(t.manga_series_chapters_count(count: 0)), findsOneWidget);
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
  });

  testWidgets('筛选无结果时标题显示 0，而不是总数', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      downloadFilter: MangaChapterDownloadFilter.downloaded,
    );
    expect(find.text(t.manga_series_chapters_count(count: 0)), findsOneWidget);
    expect(find.text(t.manga_series_no_chapters_match_filter), findsOneWidget);
  });

  testWidgets('切换排序不改变章节数量', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(chapters), newestFirst: true);
    expect(find.text(t.manga_series_chapters_count(count: 3)), findsOneWidget);

    await pumpList(tester, entry: entryWith(chapters), newestFirst: false);
    expect(
      find.text(t.manga_series_chapters_count(count: 3)),
      findsOneWidget,
      reason: '计数只反映筛选结果，排序只改变顺序',
    );
  });

  testWidgets('标题沿用章节标题字体，且没有单独的数字徽章', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(chapters));
    final Finder title = find.text(t.manga_series_chapters_count(count: 3));
    final MediaDetailSectionHeader header = tester
        .widget<MediaDetailSectionHeader>(
          find.byType(MediaDetailSectionHeader),
        );
    expect(header.count, isNull, reason: '数字徽章已并入「共 X 章」标题');
    expect(
      tester.widget<Text>(title).style,
      tester.element(title).fushiType.titleLargeEmphasized,
      reason: '沿用原章节标题的 typography',
    );
  });

  testWidgets('全读完 + 只看未读 → 提示「都读完了」，而不是空白', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(chapters),
      unreadOnly: true,
      states: <String, MangaChapterStateRow>{
        for (final OnlineMangaChapter chapter in chapters)
          chapter.key: _state(chapterKey: chapter.key, readAt: 1),
      },
    );
    expect(visibleTitles(tester), isEmpty);
    expect(find.text(t.manga_series_all_read), findsOneWidget);
  });

  testWidgets('没有章节时给出明确提示', (WidgetTester tester) async {
    await pumpList(tester, entry: entryWith(const <OnlineMangaChapter>[]));
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
  });

  testWidgets('entry 为 null（还没加载出来）不崩，走空态', (WidgetTester tester) async {
    await pumpList(tester, entry: null);
    expect(find.text(t.manga_series_no_chapters), findsOneWidget);
  });

  testWidgets('副标题带上翻译组与章内进度', (WidgetTester tester) async {
    await pumpList(
      tester,
      entry: entryWith(<OnlineMangaChapter>[middle]),
      states: <String, MangaChapterStateRow>{
        '/c/2': _state(chapterKey: '/c/2', lastPage: 7, pageCount: 24),
      },
    );
    // lastPage 是 0-based，显示要 +1。
    expect(find.textContaining('Fixture scans'), findsOneWidget);
    expect(
      find.textContaining(t.manga_series_read_progress(page: '8', total: '24')),
      findsOneWidget,
      reason: 'lastPage 是 0-based，显示必须 +1，否则用户看到的页码永远少一页',
    );
  });

  testWidgets('已下载的章菜单出「打开文件位置」不出「下载」；未下载的章相反', (WidgetTester tester) async {
    final List<String> revealed = <String>[];
    Future<void> pumpOne({required bool downloaded}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MangaChapterList(
                entry: entryWith(const <OnlineMangaChapter>[middle]),
                states: const <String, MangaChapterStateRow>{},
                newestFirst: true,
                unreadOnly: false,
                onChapterTap: (OnlineMangaChapter _) {},
                downloadedChapterKeys: downloaded
                    ? <String>{middle.key}
                    : const <String>{},
                onDownload: (OnlineMangaChapter _) {},
                onRevealDownload: (OnlineMangaChapter chapter) =>
                    revealed.add(chapter.key),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(FushiOverflowMenu<String>));
      await tester.pumpAndSettle();
    }

    await pumpOne(downloaded: true);
    expect(find.text(t.manga_chapter_download_action), findsNothing);
    await tester.tap(find.text(t.media_file_location_open));
    await tester.pumpAndSettle();
    expect(revealed, <String>[middle.key], reason: '菜单项必须回调到那一章');

    await pumpOne(downloaded: false);
    expect(find.text(t.manga_chapter_download_action), findsOneWidget);
    expect(
      find.text(t.media_file_location_open),
      findsNothing,
      reason: '没下载的章没有文件可定位',
    );
  });

  testWidgets('点某一行回调的是那一行对应的章', (WidgetTester tester) async {
    final List<String> tapped = <String>[];
    await pumpList(
      tester,
      entry: entryWith(chapters),
      onChapterTap: (OnlineMangaChapter chapter) => tapped.add(chapter.key),
    );
    await tester.tap(find.text('Chapter 2'));
    await tester.pump();
    expect(tapped, <String>['/c/2']);
  });
}

MangaChapterStateRow _state({
  required String chapterKey,
  int lastPage = 0,
  int? pageCount,
  int? readAt,
  int updatedAt = 1,
}) => MangaChapterStateRow(
  bookUid: 'uid',
  chapterKey: chapterKey,
  lastPage: lastPage,
  lastFraction: -1,
  pageCount: pageCount,
  readAt: readAt,
  updatedAt: updatedAt,
);
