// Ticket 04（manga-ux-batch）的页面级证据：本地图源在阅读器里的跨章行为。
//
// 真实 37 表内存库 + 真实偏好库 + 真实漫画阅读页 / 作品页；本地章节就在临时
// Content root 的 `local/` 下原地读取。只断言用户可见结果与数据库里的真实状态：
//   - 章末继续后翻进入下一话第一页，章首继续前翻进入上一话最后一页；
//   - 阅读顺序是本地自然顺序（第 1 话→第 N 话）；
//   - 第一话 / 最后一话的边界停在原地并给出与在线源一致的提示；
//   - webtoon/连续滚动模式维持现有行为（跨章不做自动切换）；
//   - 「标记此章及更早为已读」对本地源写入章级 readAt。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/detail/media_detail_kit.dart';
import 'package:my_comic/src/media/manga/library/manga_series_page.dart';
import 'package:my_comic/src/media/manga/manga_reader_preferences.dart';
import 'package:my_comic/src/media/manga/manga_reading_mode.dart';
import 'package:my_comic/src/media/manga/reader/manga_my_comic_page.dart';
import 'package:my_comic/src/models/preferences_repository.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic/src/reader/reader_session_remote.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_library.dart';

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

class _LocalSourceTestAppModel extends AppModel {
  _LocalSourceTestAppModel({
    required MyComicDatabase database,
    required PreferencesRepository prefs,
    required AppPaths paths,
    required Directory directory,
    MangaReadingMode readingMode = MangaReadingMode.spread,
  }) : _paths = paths,
       _readingMode = readingMode,
       super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  final AppPaths _paths;
  final MangaReadingMode _readingMode;

  @override
  AppPaths get appPaths => _paths;

  @override
  Directory get temporaryDirectory => _paths.cacheRoot;

  @override
  double get appUiScale => 1.0;

  // 固定顶栏：测试里不需要浮动 chrome 的收起动画。
  @override
  bool get mangaChromeFloating => false;

  // 测试环境没有原生 OCR 后端。
  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      MangaReaderPreferences(mode: _readingMode, ocrTrigger: 'manual');
}

MediaItem _item(String bookKey) => MediaItem(
  mediaIdentifier: 'mycomic://book/$bookKey',
  mediaSourceIdentifier: 'reader_manga',
  title: 'Fixture Series',
  mediaTypeIdentifier: 'reader',
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

Widget _readerHarness(
  AppModel appModel,
  GlobalKey<NavigatorState> navKey,
  String bookKey, {
  int? chapterIndex,
}) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      navigatorKey: navKey,
      home: MangaMyComicPage(
        item: _item(bookKey),
        bookKey: bookKey,
        initialChapterIndex: chapterIndex,
      ),
    ),
  ),
);

Widget _seriesHarness(
  AppModel appModel,
  GlobalKey<NavigatorState> navKey,
  String bookKey,
) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      navigatorKey: navKey,
      home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
    ),
  ),
);

const String _chapter1 = 'Ch 1';
const String _chapter2 = 'Ch 2';
const String _chapter3 = 'Ch 3';

void main() {
  late Directory tmp;
  late AppPaths paths;
  late Directory mangaDir;
  late MyComicDatabase db;
  late PreferencesRepository prefs;
  late GlobalKey<NavigatorState> navKey;
  late _LocalSourceTestAppModel appModel;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    navKey = GlobalKey<NavigatorState>();
    MyComicToast.navigatorKey = navKey;
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> boot({
    MangaReadingMode readingMode = MangaReadingMode.spread,
  }) async {
    tmp = Directory.systemTemp.createTempSync('my_comic_local_switch_');
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    mangaDir = Directory(p.join(paths.localComicRoot.path, 'Fixture Series'))
      ..createSync(recursive: true);
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = _LocalSourceTestAppModel(
      database: db,
      prefs: prefs,
      paths: paths,
      directory: paths.cacheRoot,
      readingMode: readingMode,
    );
  }

  Future<void> writeChapter(String name, int pageCount) async {
    final Directory dir = Directory(p.join(mangaDir.path, name))
      ..createSync(recursive: true);
    for (int i = 0; i < pageCount; i++) {
      File(
        p.join(dir.path, '${(i + 1).toString().padLeft(3, '0')}.jpg'),
      ).writeAsBytesSync(<int>[i, i + 1, i + 2]);
    }
  }

  /// 插入一条已在书架的本地图源作品，章节按 [chapters] 的自然顺序。
  Future<EpubBookRow> insertLocalSourceRow({
    List<String> chapters = const <String>[_chapter1, _chapter2],
    String? currentChapterKey,
  }) async {
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Fixture Series',
        epubPath: '',
        extractDir: mangaDir.path,
        chapterCount: 7,
        chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          for (final String chapter in chapters)
            LocalSourceChapterRecord(
              key: chapter,
              name: chapter,
              relativePath: chapter,
            ),
        ]),
        importedAt: 0,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(
            relativePath: 'Fixture Series',
            currentChapterKey: currentChapterKey,
          ).encode(),
        ),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  Future<String?> currentChapterKey(String bookKey) async =>
      LocalSourceMetadata.tryParse(
        (await db.getEpubBook(bookKey))!.sourceMetadata,
      )?.currentChapterKey;

  /// 章末继续后翻：等待自动换章落到目标章并完成装载。
  Future<void> turnUntilChapter(
    WidgetTester tester, {
    required int targetChapter,
    bool forward = true,
  }) async {
    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    await remote.turnPage(forward: forward);
    for (int i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      final ReaderSessionSnapshot? snapshot = remote.snapshot();
      if (snapshot != null &&
          snapshot.chapterIndex == targetChapter &&
          snapshot.contentReady) {
        return;
      }
    }
    fail('turnPage 后没有落到第 $targetChapter 章');
  }

  testWidgets('本地源章末继续后翻进入下一话第一页，按自然顺序推进', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      await writeChapter(_chapter3, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2, _chapter3],
      );
      await tester.pumpWidget(
        _readerHarness(appModel, navKey, row.bookKey, chapterIndex: 0),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      // 翻到第 1 话最后一页，再继续后翻。
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    await tester.runAsync(() async {
      await turnUntilChapter(tester, targetChapter: 1);
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 1);
    expect(remote.snapshot()!.pageIndex, 0, reason: '章末后翻进入下一话第一页');
    expect(
      await currentChapterKey(row.bookKey),
      _chapter2,
      reason: '换章后 currentChapterKey 跟着更新',
    );
    final MangaChapterStateRow first = (await db.getMangaChapterState(
      bookUid: row.uid,
      chapterKey: _chapter1,
    ))!;
    expect(first.readAt, isNotNull, reason: '读完第 1 话自动写章级已读');
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter2,
      ))?.readAt,
      isNull,
      reason: '刚进入的第 2 话仍未读',
    );

    // 再读一章：自然顺序是下标 +1（第 3 话），不是在线源的下标 -1。
    await tester.runAsync(() async {
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    await tester.runAsync(() async {
      await turnUntilChapter(tester, targetChapter: 2);
    });
    expect(remote.snapshot()!.chapterIndex, 2);
    expect(remote.snapshot()!.pageIndex, 0);
    expect(await currentChapterKey(row.bookKey), _chapter3);
  });

  testWidgets('本地源章首继续前翻进入上一话最后一页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2],
      );
      await tester.pumpWidget(
        _readerHarness(appModel, navKey, row.bookKey, chapterIndex: 1),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      expect(remote.snapshot()!.chapterIndex, 1);
      expect(remote.snapshot()!.pageIndex, 0);
    });

    await tester.runAsync(() async {
      await turnUntilChapter(tester, targetChapter: 0, forward: false);
      // 落点页的章级进度由 debounce 落库。
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 0);
    expect(remote.snapshot()!.pageIndex, 2, reason: '章首前翻落在上一话最后一页，而不是开头');
    expect(await currentChapterKey(row.bookKey), _chapter1);
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter1,
      ))!.lastPage,
      2,
      reason: '落在上一话末页也要记成该章进度',
    );
  });

  testWidgets('第一话章首继续前翻停在原地，并给出边界提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2],
      );
      await tester.pumpWidget(
        _readerHarness(appModel, navKey, row.bookKey, chapterIndex: 0),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.turnPage(forward: false);
      await pumpUntilFound(
        tester,
        find.text(t.manga_series_first_chapter_reached),
        maxTries: 60,
      );
      await tester.pump();
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 0, reason: '第一话边界停在原地');
    expect(remote.snapshot()!.pageIndex, 0);
    expect(await currentChapterKey(row.bookKey), _chapter1);
    expect(
      await db.getMangaChapterState(bookUid: row.uid, chapterKey: _chapter1),
      isNull,
      reason: '边界前翻不产生阅读/已读状态',
    );
  });

  testWidgets('最后一话章末继续后翻停在原地，并提示读完该章', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2],
      );
      await tester.pumpWidget(
        _readerHarness(appModel, navKey, row.bookKey, chapterIndex: 1),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      await readerSessionRemotes.current.value!.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.turnPage(forward: true);
      await pumpUntilFound(
        tester,
        find.text(t.manga_series_last_chapter_reached),
        maxTries: 60,
      );
      await tester.pump();
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 1, reason: '最后一话边界停在原地');
    expect(remote.snapshot()!.pageIndex, 2);
    expect(await currentChapterKey(row.bookKey), _chapter2);
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter2,
      ))!.readAt,
      isNotNull,
      reason: '读到最后一话的末页也算读完该章',
    );
  });

  testWidgets('webtoon 连续滚动模式维持现状：章末翻页不自动换章', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot(readingMode: MangaReadingMode.webtoon);
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2],
      );
      await tester.pumpWidget(
        _readerHarness(appModel, navKey, row.bookKey, chapterIndex: 0),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      await readerSessionRemotes.current.value!.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.turnPage(forward: true);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    expect(remote.snapshot()!.chapterIndex, 0, reason: '连续滚动模式不在本次扩展自动换章');
    expect(remote.snapshot()!.pageIndex, 2);
    expect(await currentChapterKey(row.bookKey), _chapter1);
    expect(find.text(t.manga_series_last_chapter_reached), findsNothing);
  });

  testWidgets('「标记此章及更早为已读」对本地源写入章级 readAt', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 3);
      await writeChapter(_chapter3, 3);
      row = await insertLocalSourceRow(
        chapters: <String>[_chapter1, _chapter2, _chapter3],
      );
      await tester.pumpWidget(_seriesHarness(appModel, navKey, row.bookKey));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    // 第 2 话的溢出菜单 →「标记此章及更早为已读」。
    final Finder chapter2Row = find.ancestor(
      of: find.text(_chapter2),
      matching: find.byType(MediaDetailItemRow),
    );
    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: chapter2Row,
          matching: find.byType(MyComicOverflowMenu<String>),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    expect(find.text(t.manga_series_mark_previous_read), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.text(t.manga_series_mark_previous_read));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pump();
    });

    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter1,
      ))?.readAt,
      isNotNull,
      reason: '更早的第 1 话必须标为已读',
    );
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter2,
      ))?.readAt,
      isNotNull,
      reason: '当前章必须标为已读',
    );
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter3,
      ))?.readAt,
      isNull,
      reason: '更晚的第 3 话不受影响',
    );

    // 列表也立刻反映已读：对勾落在第 1、2 话上。
    final List<MediaDetailItemRow> rows = tester
        .widgetList<MediaDetailItemRow>(find.byType(MediaDetailItemRow))
        .toList();
    expect(rows.map((MediaDetailItemRow item) => item.title), <String>[
      _chapter1,
      _chapter2,
      _chapter3,
    ]);
    expect(rows.map((MediaDetailItemRow item) => item.completed), <bool>[
      true,
      true,
      false,
    ]);
  });
}
