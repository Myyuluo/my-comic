import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

/// 非书架行与在线阅读（manga-library-membership 票 02/05）页面级 seam：
/// 挂真实 [MangaSeriesPage] + 真 37 表内存 DB + 可控在线 adapter/service。
/// 断言只落在用户可见行为与数据结果上：打开源作品页是否落一条非书架行、
/// 点章是否不再入库、再次打开是否复用同一行/uid；非书架作品是否具备已读/
/// 批量标记/继续阅读/刷新/登录/打开网站，同时隐藏书架专属入口；以及下载完成
/// 后是否只给可选「加入书架？」提示而不自动加入。
class _FakeAdapter
    implements
        OnlineMangaRuntimeAdapter,
        OnlineMangaLoginCapable,
        OnlineMangaWebUrlCapable {
  _FakeAdapter({List<OnlineMangaChapter>? chapters})
    : chapters = chapters ?? _chapters;

  /// [refresh] 返回的章节列表。
  final List<OnlineMangaChapter> chapters;

  int refreshCalls = 0;

  /// 为真时像真源一样给页表和页图（阅读器持久化用例用）。
  bool serve = false;

  static final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 60, height: 90)),
  );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    refreshCalls++;
    return OnlineMangaRefreshResult(series: entry.series, chapters: chapters);
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    if (!serve) throw StateError('the series page must not resolve pages');
    return <OnlineMangaPageRef>[
      for (int index = 0; index < 3; index++)
        HttpMangaPageRef(
          index: index,
          url: 'https://example.invalid${chapter.key}/$index.png',
          referer: 'https://example.invalid',
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (!serve) throw StateError('the series page must not fetch pages');
    return png;
  }

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

  @override
  OnlineMangaLoginTarget? loginTarget(OnlineMangaLibraryEntry entry) => (
    runtime: OnlineMangaRuntimeKind.mihon,
    sourceName: 'Fake source',
    baseUrl: 'https://example.invalid',
  );

  @override
  OnlineMangaLoginTarget? loginTargetForChapter(
    OnlineMangaLibraryEntry entry,
    OnlineMangaChapter chapter,
  ) => loginTarget(entry);

  @override
  Future<Uri?> webUrl(OnlineMangaLibraryEntry entry) async =>
      Uri.parse('https://example.invalid${entry.series.key}');
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, this._temp)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: _temp,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final Directory _temp;
  final List<MediaItem?> opened = <MediaItem?>[];
  Widget Function()? launchPageBuilder;

  @override
  FushiDatabase get database => _db;

  @override
  Directory get temporaryDirectory => _temp;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  // 阅读器 widget 测试需要的稳定偏好快照（与
  // `manga_fushi_page_online_chapter_test` 同口径）。
  @override
  bool get lowMemoryMode => false;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  String get mangaSpreadPreference => 'auto';
  @override
  String get mangaReadingDirection => 'rtl';
  @override
  int get mangaZoomPercent => 100;
  @override
  int get mangaZoomSensitivity => kMangaZoomSensitivityDefault;
  @override
  String get mangaPageAnimation => MangaPageAnimation.slide.key;
  @override
  String get mangaPageAnimationSpeed => PageTurnAnimationSpeed.normal.key;
  @override
  bool get mangaPageTurnFollowDrag => kMangaPageTurnFollowDragDefault;
  @override
  bool get mangaTapZonePaging => true;
  @override
  bool get mangaChromeFloating => false;
  @override
  bool get mangaVolumeKeyPaging => false;
  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');

  /// 开阅读器的副作用与本测试无关，只记「点了哪一条、交给阅读器哪个入口」。
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
    this.launchPageBuilder = launchPageBuilder;
  }
}

Widget _harness(AppModel appModel, Widget home) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(child: MaterialApp(home: home)),
);

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _seed({
  String seriesKey = '/series/fixture',
  String title = 'Fixture series',
  List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
  bool subscribed = false,
  bool autoDownload = false,
}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: seriesKey,
    title: title,
    raw: <String, Object?>{'url': seriesKey},
  ),
  chapters: chapters,
  subscribed: subscribed,
  autoDownload: autoDownload,
);

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

Future<void> _openChapterMenu(WidgetTester tester, String title) async {
  await tester.tap(
    find.descendant(
      of: _chapterRow(title),
      matching: find.byType(FushiOverflowMenu<String>),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
}

/// 推进 fake clock 到多选栏 / 进场动画结束（手势不能包在 runAsync 里）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 空间足够时「⋯」动作平铺在操作栏；不够时才收进「⋯」。
///
/// 平铺时同一个 key 落在包住这些平铺钮的 Row 上，不能当按钮点；只认真正
/// 的图标钮。返回是否真的打开了菜单。
Future<bool> _openMoreMenu(WidgetTester tester) async {
  final Finder more = find.byWidgetPredicate(
    (Widget widget) =>
        widget is FushiIconButtonControl &&
        widget.key == const ValueKey<String>('online_work_more'),
  );
  if (more.evaluate().isEmpty) return false;
  await tester.tap(more);
  await tester.pump(const Duration(milliseconds: 300));
  return true;
}

Future<void> _tapMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  for (int i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

/// 模拟一章下载完成（票 05：下载 worker 属票 08，这里只伪造完成后的任务行）。
Future<void> _insertCompletedDownload(
  FushiDatabase db, {
  required EpubBookRow row,
  required OnlineMangaChapter chapter,
}) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  await db.upsertMangaDownloadJob(
    MangaDownloadJobsCompanion.insert(
      jobId: 'fixture-${chapter.key}',
      kind: MangaDownloadJobKind.chapter,
      bookKey: row.bookKey,
      chapterKey: chapter.key,
      runtime: OnlineMangaRuntimeKind.mihon.wireValue,
      title: row.title,
      chapterTitle: chapter.name,
      status: const Value<String>(MangaDownloadJobStatus.done),
      pagesDone: const Value<int>(1),
      pagesTotal: const Value<int>(1),
      createdAt: now,
      updatedAt: now,
      completedAt: Value<int?>(now),
    ),
  );
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late _TestAppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_nonlibrary_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    TestWidgetsFlutterBinding.ensureInitialized();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
    );
    appModel = _TestAppModel(db, library, root);
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSourcePage(
    WidgetTester tester, {
    Key? pageKey,
    OnlineMangaLibraryEntry? seed,
    Future<void> Function(Uri url)? openExternal,
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        appModel,
        MangaSeriesPage(
          key: pageKey,
          openExternal: openExternal,
          target: SourceMangaSeriesTarget(
            adapter: adapter,
            seed: seed ?? _seed(),
            service: library,
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Chapter 1'));
  }

  testWidgets('打开在线源作品页创建非书架行；再次打开复用同一行与 uid', (WidgetTester tester) async {
    await tester.runAsync(() => pumpSourcePage(tester));

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1), reason: '打开源作品页就应有且只有一条 Manga 行');
    final EpubBookRow row = rows.single;
    expect(row.inLibrary, isFalse, reason: '源页打开不得自动加入书架');
    expect(row.uid, isNotEmpty, reason: '非书架行也要有稳定 uid');
    expect(row.format, BookFormat.manga.dbValue);
    final OnlineMangaLibraryEntry stored = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    )!;
    expect(stored.series.key, '/series/fixture');
    expect(stored.extensionPackage, 'org.example.fixture');
    expect(stored.sourceId, '1');
    expect(
      stored.chapters.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/chapter/2', '/chapter/1'],
      reason: '进页后拉到的章节要写进这条非书架行',
    );
    expect(adapter.refreshCalls, 1);

    final String bookKey = row.bookKey;
    final String uid = row.uid;
    expect(await db.getLibraryEpubBooks(), isEmpty, reason: '书架读取口看不到非书架行');
    expect(
      await ReaderFushiSource.instance.getBooksFromDb(appModel: appModel),
      isEmpty,
      reason: '书架列书（页面数据源）不得出现刚创建的非书架作品',
    );

    // 再次从在线源打开同一作品：不重复建行，bookKey / uid 原样复用。
    // 只换页面（换 Key 强制新 State），ProviderScope/AppModel 保持存活；
    // 整棵 ProviderScope 重新挂会 dispose 掉注入的 AppModel。
    await tester.runAsync(() => pumpSourcePage(tester, pageKey: UniqueKey()));

    final List<EpubBookRow> reopened = await db.getAllEpubBooks();
    expect(reopened, hasLength(1), reason: '重复打开不得重复建行');
    expect(reopened.single.bookKey, bookKey);
    expect(reopened.single.uid, uid);
    expect(reopened.single.inLibrary, isFalse);
    expect(await db.getLibraryEpubBooks(), isEmpty);
  });

  testWidgets('点章节不再自动入库：阅读器打开非书架行，进度/已读/当前章/History 持久化', (
    WidgetTester tester,
  ) async {
    adapter.serve = true;

    late String bookKey;
    late String uid;
    await tester.runAsync(() async {
      await pumpSourcePage(tester);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      bookKey = row.bookKey;
      uid = row.uid;
      expect(row.inLibrary, isFalse);

      // 点章节：不加入书架，直接开阅读器读这条非书架行。
      await tester.tap(find.text('Chapter 1'));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(appModel.opened, hasLength(1), reason: '点章应打开阅读器');
    expect(appModel.launchPageBuilder, isNotNull);

    final EpubBookRow afterTap = (await db.getEpubBook(bookKey))!;
    expect(afterTap.inLibrary, isFalse, reason: '阅读不得把作品自动加入书架');
    expect(afterTap.uid, uid, reason: '阅读不得改变行身份');
    final OnlineMangaLibraryEntry tappedEntry =
        OnlineMangaLibraryEntry.tryParse(afterTap.sourceMetadata)!;
    expect(tappedEntry.currentChapter?.key, '/chapter/1', reason: '点开的章要写成当前章');
    final int chapterIndex = tappedEntry.chapters.indexWhere(
      (OnlineMangaChapter chapter) => chapter.key == '/chapter/1',
    );

    // 作品页交给 openMedia 的阅读器必须指向同一条非书架行、点名同一章。
    final MangaFushiPage launched = _readerOf(appModel.launchPageBuilder!());
    expect(launched.bookKey, bookKey);
    expect(launched.initialChapterIndex, chapterIndex);

    // 真挂阅读器：进度、章节已读与 History 都写这条行的 uid/bookKey。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(appModel, appModel.launchPageBuilder!()),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final EpubBookRow afterReading = (await db.getEpubBook(bookKey))!;
    expect(afterReading.inLibrary, isFalse, reason: '读完仍是非书架作品');
    expect(afterReading.uid, uid);

    final MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: uid,
      chapterKey: '/chapter/1',
    ))!;
    expect(state.lastPage, 2, reason: '章级进度落在非书架行的 uid');
    expect(state.readAt, isNotNull, reason: '读到章末 = 该章已读');

    final ReaderPosition position = (await ReaderPositionRepository(
      db,
    ).findByBookUid(uid))!;
    expect(position.sectionIndex, 2, reason: '书级进度也落在同一 uid');

    final List<MangaHistoryEntry> history = await loadMangaHistory(db);
    expect(history, hasLength(1), reason: '每部 Manga 一条 History');
    expect(history.single.bookKey, bookKey);
    expect(history.single.title, 'Fixture series');
    expect(history.single.online, isNotNull);
    expect(history.single.openedAt, greaterThan(0));

    expect(await db.getLibraryEpubBooks(), isEmpty, reason: '阅读不该让作品进入书架成员集合');
  });

  testWidgets('非书架作品下载完成后提示「加入书架？」；不自动加入，确认后同一行翻 membership', (
    WidgetTester tester,
  ) async {
    late String bookKey;
    late String uid;
    const ValueKey<String> promptKey = ValueKey<String>(
      'manga_series_add_to_shelf_after_download',
    );
    await tester.runAsync(() async {
      await pumpSourcePage(tester);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      bookKey = row.bookKey;
      uid = row.uid;

      // 等首屏那次任务状态读取落定（基线），再模拟「刚下载完成」。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await _insertCompletedDownload(db, row: row, chapter: _chapters[1]);
      await pumpUntilFound(tester, find.byKey(promptKey));
      // 等提示条滑入到位再点动作（刚入树时还在屏幕下方）。
      await tester.pump(const Duration(milliseconds: 500));
    });

    expect(
      find.text(
        t.manga_series_add_to_shelf_after_download(title: 'Fixture series'),
      ),
      findsOneWidget,
      reason: '下载完成要给出可选的加入书架提示',
    );
    expect(
      (await db.getEpubBook(bookKey))!.inLibrary,
      isFalse,
      reason: '提示不得自动加入书架',
    );

    final Finder prompt = find.byKey(promptKey);
    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: prompt,
          matching: find.text(t.mihon_add_to_bookshelf),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    final EpubBookRow added = (await db.getEpubBook(bookKey))!;
    expect(added.inLibrary, isTrue, reason: '确认提示后才加入书架');
    expect(added.bookKey, bookKey, reason: '加入书架不得改变行身份');
    expect(added.uid, uid);
    expect(await db.getLibraryEpubBooks(), hasLength(1));
  });

  testWidgets('同一次打开作品页只提示一次，批量逐章完成不反复打扰', (WidgetTester tester) async {
    const ValueKey<String> promptKey = ValueKey<String>(
      'manga_series_add_to_shelf_after_download',
    );
    late String bookKey;
    late EpubBookRow seeded;
    await tester.runAsync(() async {
      await pumpSourcePage(tester);
      seeded = (await db.getAllEpubBooks()).single;
      bookKey = seeded.bookKey;

      // 等首屏任务状态基线落定后再模拟下载完成。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await _insertCompletedDownload(db, row: seeded, chapter: _chapters[1]);
      await pumpUntilFound(tester, find.byKey(promptKey));
    });
    // 手动收起提示条（自动退场的计时器挂在真实时钟上），模拟用户看过/划走。
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .hideCurrentSnackBar();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(promptKey), findsNothing);

    // 第二批章节完成：同一次打开页里不再追问。
    await tester.runAsync(() async {
      await _insertCompletedDownload(db, row: seeded, chapter: _chapters[0]);
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(find.byKey(promptKey), findsNothing, reason: '批量下载逐章完成只提示一次');
    expect((await db.getEpubBook(bookKey))!.inLibrary, isFalse);
  });

  testWidgets('书架作品、以及打开页面前就已完成的下载，都不弹「加入书架？」', (WidgetTester tester) async {
    const ValueKey<String> promptKey = ValueKey<String>(
      'manga_series_add_to_shelf_after_download',
    );

    // 书架成员：下载完成事件照常刷新状态，但不提示收藏（它已经在书架里）。
    late EpubBookRow libraryRow;
    await tester.runAsync(() async {
      libraryRow = await library.add(
        _seed(seriesKey: '/series/library', title: 'Library series'),
      );
      await _insertCompletedDownload(
        db,
        row: libraryRow,
        chapter: _chapters[0],
      );
      await pumpSourcePage(
        tester,
        seed: _seed(seriesKey: '/series/library', title: 'Library series'),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.byKey(promptKey), findsNothing, reason: '已在书架的作品不需要加入书架提示');
    expect((await db.getEpubBook(libraryRow.bookKey))!.inLibrary, isTrue);

    // 非书架成员，但下载在打开页面之前就完成了：首轮只记基线，不追问历史完成。
    late EpubBookRow nonLibraryRow;
    await tester.runAsync(() async {
      nonLibraryRow = await library.ensureNonLibrary(
        _seed(
          seriesKey: '/series/predownloaded',
          title: 'Predownloaded series',
          chapters: _chapters,
        ),
      );
      await _insertCompletedDownload(
        db,
        row: nonLibraryRow,
        chapter: _chapters[0],
      );
      await pumpSourcePage(
        tester,
        pageKey: UniqueKey(),
        seed: _seed(
          seriesKey: '/series/predownloaded',
          title: 'Predownloaded series',
          chapters: _chapters,
        ),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(find.byKey(promptKey), findsNothing, reason: '打开页面时早已完成的下载不该再弹提示');
    expect((await db.getEpubBook(nonLibraryRow.bookKey))!.inLibrary, isFalse);
  });

  testWidgets('非书架作品可标记已读/未读/此章及更早，状态持久化在同一条行', (WidgetTester tester) async {
    late String uid;
    late String bookKey;
    await tester.runAsync(() async {
      await pumpSourcePage(tester);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      uid = row.uid;
      bookKey = row.bookKey;
    });

    // 单章「标记为已读」。
    await tester.runAsync(() async {
      await _openChapterMenu(tester, 'Chapter 1');
      expect(find.text(t.manga_series_mark_read), findsOneWidget);
      await _tapMenuItem(tester, t.manga_series_mark_read);
    });
    expect(
      (await db.getMangaChapterState(
        bookUid: uid,
        chapterKey: '/chapter/1',
      ))?.readAt,
      isNotNull,
      reason: '非书架行的章级已读要落库',
    );

    // 再点同一章是「标记为未读」，只清 readAt。
    await tester.runAsync(() async {
      await _openChapterMenu(tester, 'Chapter 1');
      expect(find.text(t.manga_series_mark_unread), findsOneWidget);
      await _tapMenuItem(tester, t.manga_series_mark_unread);
    });
    expect(
      (await db.getMangaChapterState(
        bookUid: uid,
        chapterKey: '/chapter/1',
      ))?.readAt,
      isNull,
      reason: '非书架行也要能取消已读',
    );

    // 列表新→旧：第 2 话的「此章及更早」应把第 2、1 话都标为已读。
    await tester.runAsync(() async {
      await _openChapterMenu(tester, 'Chapter 2');
      await _tapMenuItem(tester, t.manga_series_mark_previous_read);
    });
    for (final String chapterKey in <String>['/chapter/2', '/chapter/1']) {
      expect(
        (await db.getMangaChapterState(
          bookUid: uid,
          chapterKey: chapterKey,
        ))?.readAt,
        isNotNull,
        reason: '$chapterKey 属于该章及更早，应标为已读',
      );
    }
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.inLibrary, isFalse, reason: '标记已读不得改变书架归属');
    expect(row.uid, uid);
    expect(await db.getLibraryEpubBooks(), isEmpty);
  });

  testWidgets('非书架作品支持批量标记已读/未读，并持久化在同一行', (WidgetTester tester) async {
    late String uid;
    await tester.runAsync(() async {
      await pumpSourcePage(tester);
      uid = (await db.getAllEpubBooks()).single.uid;
    });

    const ValueKey<String> markReadKey = ValueKey<String>(
      'manga_series_batch_mark_read',
    );
    const ValueKey<String> markUnreadKey = ValueKey<String>(
      'manga_series_batch_mark_unread',
    );

    // 手势必须走 fake clock（同 `manga_series_page_chapter_selection_test`）。
    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    expect(find.byKey(markReadKey), findsOneWidget);
    expect(find.byKey(markUnreadKey), findsOneWidget);

    await tester.tap(find.byKey(markReadKey));
    await _settle(tester);
    expect(
      (await db.getMangaChapterState(
        bookUid: uid,
        chapterKey: '/chapter/1',
      ))?.readAt,
      isNotNull,
      reason: '批量标记已读要落在非书架行',
    );

    await tester.tap(find.byKey(markUnreadKey));
    await _settle(tester);
    expect(
      (await db.getMangaChapterState(
        bookUid: uid,
        chapterKey: '/chapter/1',
      ))?.readAt,
      isNull,
      reason: '批量标记未读同样作用于非书架行',
    );
    expect((await db.getAllEpubBooks()).single.inLibrary, isFalse);
  });

  testWidgets('非书架作品「继续阅读」回到上次章节与页', (WidgetTester tester) async {
    adapter.serve = true;
    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.ensureNonLibrary(
        _seed(
          seriesKey: '/series/resume',
          title: 'Resume series',
          chapters: _chapters,
        ),
      );
      bookKey = row.bookKey;
      // 读到第 2 话第 2 页（lastPage 0-based）后离开。
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/2',
        lastPage: 1,
        pageCount: 3,
      );
      await pumpSourcePage(
        tester,
        seed: _seed(
          seriesKey: '/series/resume',
          title: 'Resume series',
          chapters: _chapters,
        ),
      );
    });

    expect(
      find.text('${t.book_continue_reading} · Chapter 2'),
      findsOneWidget,
      reason: '继续阅读应指向上次读到的第 2 话',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_continue')),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(appModel.opened, hasLength(1), reason: '继续阅读应打开阅读器');
    final MangaFushiPage launched = _readerOf(appModel.launchPageBuilder!());
    expect(launched.bookKey, bookKey);
    expect(launched.initialChapterIndex, 0, reason: '第 2 话在章节列表下标 0');

    // 真挂阅读器：从上次的章节与页继续。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(appModel, appModel.launchPageBuilder!()),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 0);
    expect(remote.snapshot()!.pageIndex, 1, reason: '应回到上次读到的第 2 页，而不是从头开始');
    expect((await db.getEpubBook(bookKey))!.inLibrary, isFalse);
  });

  testWidgets('非书架作品可刷新章节、登录源、打开网站', (WidgetTester tester) async {
    final List<Uri> launched = <Uri>[];
    await tester.runAsync(() async {
      await pumpSourcePage(
        tester,
        openExternal: (Uri url) async => launched.add(url),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_login')),
      findsOneWidget,
      reason: '非书架作品仍能登录来源',
    );

    final int refreshCallsBefore = adapter.refreshCalls;
    await tester.runAsync(() async {
      await _openMoreMenu(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_series_open_website')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_open_website')),
      );
      for (int i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(launched, <Uri>[
      Uri.parse('https://example.invalid/series/fixture'),
    ], reason: '在网站打开走的是该条目的源站地址');

    await tester.runAsync(() async {
      await _openMoreMenu(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_series_refresh')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_refresh')),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    expect(adapter.refreshCalls, refreshCallsBefore + 1);
    expect((await db.getAllEpubBooks()).single.inLibrary, isFalse);
  });

  testWidgets('非书架作品不显示 Tag/订阅/自动追更/Tracking；加入书架后订阅入口出现', (
    WidgetTester tester,
  ) async {
    final OnlineMangaLibraryEntry seed = _seed(
      seriesKey: '/series/gated',
      title: 'Gated series',
      subscribed: true,
      autoDownload: true,
    );
    late String bookKey;
    await tester.runAsync(() async {
      bookKey = (await library.ensureNonLibrary(seed)).bookKey;
      await pumpSourcePage(tester, seed: seed);
    });

    const ValueKey<String> subscribeKey = ValueKey<String>(
      'manga_series_subscribe',
    );
    const ValueKey<String> autoDownloadKey = ValueKey<String>(
      'manga_series_auto_download',
    );
    expect(find.byKey(subscribeKey), findsNothing, reason: '非书架作品没有订阅入口');
    expect(find.text(t.manga_series_subscribe), findsNothing);
    expect(find.text(t.manga_series_auto_download), findsNothing);
    expect(find.text(t.tag_manage), findsNothing, reason: '非书架作品没有 Tag 入口');
    expect(
      find.text(t.media_tracking_card_title),
      findsNothing,
      reason: '非书架作品没有 Tracking 入口',
    );

    await tester.runAsync(() async {
      final bool menuOpened = await _openMoreMenu(tester);
      expect(
        find.byKey(autoDownloadKey),
        findsNothing,
        reason: '即使条目带着订阅标志，非书架也不显示自动追更',
      );
      // 关掉菜单（若它是收在「⋯」里的形态）。
      if (menuOpened) {
        await tester.tapAt(const Offset(4, 4));
        await tester.pump(const Duration(milliseconds: 300));
      }
    });

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect((await db.getEpubBook(bookKey))!.inLibrary, isTrue);
    expect(find.byKey(subscribeKey), findsOneWidget, reason: '加入书架后才出现订阅入口');
    await tester.runAsync(() async {
      await _openMoreMenu(tester);
      expect(find.byKey(autoDownloadKey), findsOneWidget);
    });
  });
}

MangaFushiPage _readerOf(Widget widget) => switch (widget) {
  MangaFushiPage page => page,
  FushiAppUiScaleNeutralizer(child: final Widget child) =>
    child as MangaFushiPage,
  _ => throw StateError('unexpected launch widget: $widget'),
};
