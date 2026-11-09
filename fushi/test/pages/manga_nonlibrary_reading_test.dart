import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
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
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

/// 非书架行与在线阅读（manga-library-membership 票 02）页面级 seam：
/// 挂真实 [MangaSeriesPage] + 真 37 表内存 DB + 可控在线 adapter/service。
/// 断言只落在用户可见行为与数据结果上：打开源作品页是否落一条非书架行、
/// 点章是否不再入库、再次打开是否复用同一行/uid，以及书架成员读取口是否
/// 完全看不到它。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
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

OnlineMangaLibraryEntry _seed() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: <OnlineMangaChapter>[],
);

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

  Future<void> pumpSourcePage(WidgetTester tester, {Key? pageKey}) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        appModel,
        MangaSeriesPage(
          key: pageKey,
          target: SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _seed(),
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
}

MangaFushiPage _readerOf(Widget widget) => switch (widget) {
  MangaFushiPage page => page,
  FushiAppUiScaleNeutralizer(child: final Widget child) =>
    child as MangaFushiPage,
  _ => throw StateError('unexpected launch widget: $widget'),
};
