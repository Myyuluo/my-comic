import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/shelf_sort.dart';
import 'package:material_ui/material_ui.dart';

import 'manga_library_page_harness.dart';

/// manga-shelf-download-ux 票 01：在线漫画进度 / 继续阅读走**真实书架数据管线**
/// （`ReaderFushiSource.getBooksFromDb` + 真 37 表内存 DB + `manga_chapter_states`），
/// 不再依赖测试合成的 `MediaItem.position / duration`。
///
/// 覆盖：存储数组旧章在前、单章、完成旧章、完成最新章、非书架、导入章状态。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(
    () => MangaLibraryPageHarness.setUpPathProvider(
      binding,
      tempPrefix: 'fushi_manga_progress_pp',
    ),
  );
  tearDownAll(() => MangaLibraryPageHarness.tearDownPathProvider(binding));

  late MangaLibraryPageHarness<AppModel> harness;

  setUp(() async {
    harness = await MangaLibraryPageHarness.create<AppModel>(
      tempPrefix: 'fushi_manga_progress',
    );
  });

  tearDown(() => harness.dispose());

  OnlineMangaChapter chapter(String key, double number) => OnlineMangaChapter(
    key: key,
    name: 'Chapter ${number.toInt()}',
    number: number,
    raw: <String, Object?>{'url': key},
  );

  OnlineMangaLibraryEntry entry(
    List<OnlineMangaChapter> chapters, {
    int? currentChapterIndex,
  }) => OnlineMangaLibraryEntry(
    runtime: OnlineMangaRuntimeKind.mihon,
    extensionPackage: 'org.example.fixture',
    sourceId: '1',
    series: const OnlineMangaSeries(
      key: '/series/fixture',
      title: 'Fixture series',
      raw: <String, Object?>{'url': '/series/fixture'},
    ),
    chapters: chapters,
    currentChapterIndex: currentChapterIndex,
  );

  Future<({String bookKey, String uid})> seedOnlineManga(
    String bookKey, {
    required List<OnlineMangaChapter> chapters,
    int? currentChapterIndex,
    bool inLibrary = true,
    DateTime? completedAt,
  }) async {
    final String uid = 'uid_$bookKey';
    await harness.db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        uid: Value<String>(uid),
        title: 'Fixture series',
        epubPath: 'manga.json',
        extractDir: '${harness.pathProviderDir.path}/$bookKey',
        chapterCount: chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String>(
          entry(chapters, currentChapterIndex: currentChapterIndex).encode(),
        ),
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
        inLibrary: Value<bool>(inLibrary),
        completedAt: Value<DateTime?>(completedAt),
      ),
    );
    return (bookKey: bookKey, uid: uid);
  }

  Future<void> seedChapterState(
    String uid,
    String chapterKey, {
    required int lastPage,
    int? pageCount,
    int? readAt,
    required int updatedAt,
  }) => harness.db.importMangaChapterState(
    bookUid: uid,
    chapterKey: chapterKey,
    lastPage: lastPage,
    lastFraction: -1,
    pageCount: pageCount,
    readAt: readAt,
    updatedAt: updatedAt,
  );

  Future<Map<String, MediaItem>> shelfItems() async {
    final List<MediaItem> items = await ReaderFushiSource.instance
        .getBooksFromDb(appModel: harness.appModel);
    return <String, MediaItem>{
      for (final MediaItem item in items)
        ReaderFushiSource.parseBookKey(item.mediaIdentifier) ?? '': item,
    };
  }

  ShelfReadStatus statusOf(MediaItem item, {bool completed = false}) =>
      classifyShelfReadStatus(
        completion: completed
            ? ShelfCompletion.complete
            : ShelfCompletion.incomplete,
        position: item.position,
        duration: item.duration,
      );

  test('存储数组旧章在前、当前选中第 1 话中间页 → 在读而不是读完', () async {
    // 导入条目的数组常把旧章放在前面：第 1 话是下标 0，第 2 话是下标 1。
    // 旧实现把 currentChapterIndex=0 当成「最后一话」，position == duration。
    final chapters = <OnlineMangaChapter>[
      chapter('/chapter/1', 1),
      chapter('/chapter/2', 2),
    ];
    final seeded = await seedOnlineManga(
      'old_first',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/chapter/1',
      lastPage: 4,
      pageCount: 10,
      updatedAt: 5000,
    );

    final Map<String, MediaItem> items = await shelfItems();
    final MediaItem item = items['old_first']!;
    expect(item.position, greaterThan(0), reason: '读了一部分就是有进度');
    expect(
      item.position,
      lessThan(item.duration),
      reason: '第 1 话只是中间页，不能算整部作品读完',
    );
    expect(statusOf(item), ShelfReadStatus.reading);
  });

  test('单章作品打开但未读完 → 在读；显式完成标记后才读完', () async {
    final chapters = <OnlineMangaChapter>[chapter('/only', 1)];
    final seeded = await seedOnlineManga(
      'single',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/only',
      lastPage: 0,
      pageCount: 20,
      updatedAt: 5000,
    );

    Map<String, MediaItem> items = await shelfItems();
    expect(
      statusOf(items['single']!),
      ShelfReadStatus.reading,
      reason: '刚打开第 1 页，不能因为单章就判读完',
    );

    await harness.db.setEpubBookCompleted('single', DateTime.now());
    items = await shelfItems();
    expect(
      statusOf(items['single']!, completed: true),
      ShelfReadStatus.finished,
    );
  });

  test('读完多话作品的旧章 → 只算在读，不写书级完成', () async {
    final chapters = <OnlineMangaChapter>[
      chapter('/chapter/1', 1),
      chapter('/chapter/2', 2),
    ];
    final seeded = await seedOnlineManga(
      'old_done',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/chapter/1',
      lastPage: 9,
      pageCount: 10,
      readAt: 5000,
      updatedAt: 5000,
    );

    final Map<String, MediaItem> items = await shelfItems();
    final MediaItem item = items['old_done']!;
    expect(item.position, lessThan(item.duration));
    expect(statusOf(item), ShelfReadStatus.reading);
    expect(
      (await harness.db.getEpubBook('old_done'))!.completedAt,
      isNull,
      reason: '读完旧章只写章级 readAt，不写书级完成',
    );
  });

  test('读完最新章但无完成标记 → 在读；有完成标记 → 读完', () async {
    final chapters = <OnlineMangaChapter>[
      chapter('/chapter/1', 1),
      chapter('/chapter/2', 2),
    ];
    final seeded = await seedOnlineManga('latest_done', chapters: chapters);
    await seedChapterState(
      seeded.uid,
      '/chapter/2',
      lastPage: 9,
      pageCount: 10,
      readAt: 5000,
      updatedAt: 6000,
    );

    Map<String, MediaItem> items = await shelfItems();
    expect(
      statusOf(items['latest_done']!),
      ShelfReadStatus.reading,
      reason: '完成状态已知且未完成：进度到 100% 也不自动判读完',
    );

    await harness.db.setEpubBookCompleted('latest_done', DateTime.now());
    items = await shelfItems();
    expect(
      statusOf(items['latest_done']!, completed: true),
      ShelfReadStatus.finished,
    );
  });

  test('非书架漫画不进入书架列书 / 继续阅读候选', () async {
    final chapters = <OnlineMangaChapter>[chapter('/only', 1)];
    final seeded = await seedOnlineManga(
      'hidden',
      chapters: chapters,
      inLibrary: false,
    );
    await seedChapterState(
      seeded.uid,
      '/only',
      lastPage: 4,
      pageCount: 20,
      updatedAt: 5000,
    );

    final Map<String, MediaItem> items = await shelfItems();
    expect(items.containsKey('hidden'), isFalse);
  });

  test('导入备份的章状态参与进度与最近阅读（本机没有 reader_positions）', () async {
    final chapters = <OnlineMangaChapter>[
      chapter('/chapter/1', 1),
      chapter('/chapter/2', 2),
    ];
    final seeded = await seedOnlineManga('imported', chapters: chapters);
    // 备份导入写的章状态：只有页号 / 已读 / 时间，没有 pageCount。
    await harness.db.importMangaChapterState(
      bookUid: seeded.uid,
      chapterKey: '/chapter/1',
      lastPage: 5,
      readAt: null,
      updatedAt: 7000,
    );

    final Map<String, MediaItem> items = await shelfItems();
    expect(
      statusOf(items['imported']!),
      ShelfReadStatus.reading,
      reason: '导入的章级进度必须参与书架判读',
    );

    final ProviderContainer container = ProviderContainer(
      overrides: <Override>[
        appProvider.overrideWith((ref) => harness.appModel),
      ],
    );
    addTearDown(container.dispose);
    final Map<String, int> recency = await container.read(
      bookLastReadAtProvider.future,
    );
    expect(
      recency[seeded.uid],
      7000,
      reason: '没有 reader_positions 时用章状态 updatedAt 作为最近阅读补充证据',
    );
  });

  Finder pillFinder() =>
      find.byKey(const ValueKey<String>('reader_shelf_continue_pill'));

  /// 真实 provider 的书架页：FakeAsync 收不到真实事件循环的 Future，放行一次
  /// 真实 async 再固定帧推进（同 `manga_library_membership_test`）。
  Future<void> pumpRealShelf(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness.buildApp(overrideBooks: false));
    for (int round = 0; round < 2; round++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> unmountShelf(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 10));
  }

  testWidgets('旧章在前 + 当前选中旧章 + 中间页：继续阅读胶囊出现且指向该作', (WidgetTester tester) async {
    final chapters = <OnlineMangaChapter>[
      chapter('/chapter/1', 1),
      chapter('/chapter/2', 2),
    ];
    final seeded = await seedOnlineManga(
      'pill_old_first',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/chapter/1',
      lastPage: 4,
      pageCount: 10,
      updatedAt: 5000,
    );

    await pumpRealShelf(tester);

    expect(
      find.ancestor(
        of: pillFinder(),
        matching: find.byTooltip('Fixture series'),
      ),
      findsOneWidget,
      reason: '无 reader_positions 时章状态 updatedAt 也足以让胶囊出现',
    );

    await unmountShelf(tester);
  });

  testWidgets('阅读状态筛选「在读」：100% 但未标记完成的书不被排除', (WidgetTester tester) async {
    final chapters = <OnlineMangaChapter>[chapter('/only', 1)];
    final seeded = await seedOnlineManga(
      'filter_reading',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/only',
      lastPage: 9,
      pageCount: 10,
      readAt: 5000,
      updatedAt: 5000,
    );
    final Finder card = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderFushiSource.mediaIdentifierFor('filter_reading')}',
      ),
    );

    await harness.prefs.setShelfReadStatusFilterName(
      ShelfReadStatus.reading.name,
    );
    await pumpRealShelf(tester);
    expect(card, findsOneWidget, reason: '「在读」筛选必须收下它');
    await unmountShelf(tester);
  });

  testWidgets('阅读状态筛选「读完」：没有完成标记的书不被收下', (WidgetTester tester) async {
    final chapters = <OnlineMangaChapter>[chapter('/only', 1)];
    final seeded = await seedOnlineManga(
      'filter_finished',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/only',
      lastPage: 9,
      pageCount: 10,
      readAt: 5000,
      updatedAt: 5000,
    );
    final Finder card = find.byKey(
      ValueKey<String>(
        'book_entry_${ReaderFushiSource.mediaIdentifierFor('filter_finished')}',
      ),
    );

    await harness.prefs.setShelfReadStatusFilterName(
      ShelfReadStatus.finished.name,
    );
    await pumpRealShelf(tester);
    expect(card, findsNothing, reason: '「读完」筛选不得收下没有完成标记的书');
    await unmountShelf(tester);
  });

  testWidgets('完成状态已知且未完成的 100% 单章书仍出现在继续阅读胶囊', (WidgetTester tester) async {
    final chapters = <OnlineMangaChapter>[chapter('/only', 1)];
    final seeded = await seedOnlineManga(
      'pill_single_done_chapter',
      chapters: chapters,
      currentChapterIndex: 0,
    );
    await seedChapterState(
      seeded.uid,
      '/only',
      lastPage: 9,
      pageCount: 10,
      readAt: 5000,
      updatedAt: 5000,
    );

    await pumpRealShelf(tester);

    expect(
      find.ancestor(
        of: pillFinder(),
        matching: find.byTooltip('Fixture series'),
      ),
      findsOneWidget,
      reason: '章读完了但书没有完成标记：书架判在读，胶囊不消失',
    );

    await unmountShelf(tester);
  });
}
