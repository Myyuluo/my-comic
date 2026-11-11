// Ticket 02（manga-ux-batch）的页面级证据：本地图源进入与在线源等价的章级
// 阅读上下文。
//
// 真实 37 表内存库 + 真实偏好库 + 真实漫画阅读页 / 作品页；本地章节就在临时
// Content root 的 `local/` 下原地读取。只断言用户可见结果与数据库里的真实状态：
//   - 直接开书按 `LocalSourceMetadata.currentChapterKey` 恢复章节与页码；
//   - 打开章节写回 currentChapterKey，并按章写 manga_chapter_states；
//   - 无痕阅读保留章级位置、冻结 recency、不自动写已读 / 完成标记；
//   - 作品页章节列表高亮当前章；
//   - 书架进度按章节计算（总数来自 chaptersJson），未读角标按 readAt 计数。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_unread.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

class _LocalSourceTestAppModel extends AppModel {
  _LocalSourceTestAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required AppPaths paths,
    required Directory directory,
  }) : _paths = paths,
       super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  final AppPaths _paths;

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
      const MangaReaderPreferences(ocrTrigger: 'manual');
}

MediaItem _item(String bookKey) => MediaItem(
  mediaIdentifier: 'fushi://book/$bookKey',
  mediaSourceIdentifier: 'reader_manga',
  title: 'Fixture Series',
  mediaTypeIdentifier: 'reader',
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

Widget _readerHarness(AppModel appModel, String bookKey, {int? chapterIndex}) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: MangaFushiPage(
            item: _item(bookKey),
            bookKey: bookKey,
            initialChapterIndex: chapterIndex,
          ),
        ),
      ),
    );

Widget _seriesHarness(AppModel appModel, String bookKey) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
    ),
  ),
);

/// 记录作品页交给 openMedia 的 launchPageBuilder：断言「继续阅读」实际落到哪一章。
class _CapturingOpenAppModel extends _LocalSourceTestAppModel {
  _CapturingOpenAppModel({
    required super.database,
    required super.prefs,
    required super.paths,
    required super.directory,
  });

  Widget Function()? launchPageBuilder;

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
    this.launchPageBuilder = launchPageBuilder;
  }
}

MangaFushiPage _launchPage(Widget widget) => switch (widget) {
  MangaFushiPage page => page,
  FushiAppUiScaleNeutralizer(child: final Widget child) =>
    child as MangaFushiPage,
  _ => throw StateError('unexpected launch widget: $widget'),
};

const String _chapter1 = 'Ch 1';
const String _chapter2 = 'Ch 2';

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  late Directory tmp;
  late AppPaths paths;
  late Directory mangaDir;
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late _LocalSourceTestAppModel appModel;

  Future<void> boot() async {
    tmp = Directory.systemTemp.createTempSync('fushi_local_ctx_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    mangaDir = Directory(p.join(paths.localComicRoot.path, 'Fixture Series'))
      ..createSync(recursive: true);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = _LocalSourceTestAppModel(
      database: db,
      prefs: prefs,
      paths: paths,
      directory: paths.cacheRoot,
    );
  }

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> writeChapter(String name, int pageCount) async {
    final Directory dir = Directory(p.join(mangaDir.path, name))
      ..createSync(recursive: true);
    for (int i = 0; i < pageCount; i++) {
      File(
        p.join(dir.path, '${(i + 1).toString().padLeft(3, '0')}.jpg'),
      ).writeAsBytesSync(<int>[i, i + 1, i + 2]);
    }
  }

  /// 插入一条已在书架的本地图源作品。
  ///
  /// `chapterCount` 故意写成总页数（与线上 `chapterCount` 的「章数」语义不同）：
  /// 书架进度必须从 chaptersJson 推章节总数，而不是读这一列。
  Future<EpubBookRow> insertLocalSourceRow({
    String? currentChapterKey,
    int chapterCount = 7,
  }) async {
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Fixture Series',
        epubPath: '',
        extractDir: mangaDir.path,
        chapterCount: chapterCount,
        chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          const LocalSourceChapterRecord(
            key: _chapter1,
            name: _chapter1,
            relativePath: _chapter1,
          ),
          const LocalSourceChapterRecord(
            key: _chapter2,
            name: _chapter2,
            relativePath: _chapter2,
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

  testWidgets('直接开书按 currentChapterKey 恢复上次章节与页码', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      final EpubBookRow row = await insertLocalSourceRow(
        currentChapterKey: _chapter2,
      );
      // 上次在「第 2 话」读到第 2 页（0 起计 1）。
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: _chapter2,
        lastPage: 1,
        pageCount: 4,
      );
      await tester.pumpWidget(_readerHarness(appModel, row.bookKey));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    final ReaderSessionSnapshot snapshot = readerSessionRemotes.current.value!
        .snapshot()!;
    expect(snapshot.chapterIndex, 1, reason: 'currentChapterKey 指向第 2 话');
    expect(snapshot.chapterCount, 2);
    expect(snapshot.pageIndex, 1, reason: '回到该章上次停下的页码');
  });

  testWidgets('打开章节写回 currentChapterKey，并按章写进度与已读', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      row = await insertLocalSourceRow();
      await tester.pumpWidget(
        _readerHarness(appModel, row.bookKey, chapterIndex: 0),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    expect(
      LocalSourceMetadata.tryParse(
        (await db.getEpubBook(row.bookKey))!.sourceMetadata,
      )?.currentChapterKey,
      _chapter1,
      reason: '打开第 1 话后 currentChapterKey 必须跟着更新',
    );

    // 翻到本章最后一页：章级进度与已读落库。
    await tester.runAsync(() async {
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: row.uid,
      chapterKey: _chapter1,
    ))!;
    expect(state.lastPage, 2, reason: '章级进度按 currentChapterKey 落库');
    expect(state.pageCount, 3);
    expect(state.readAt, isNotNull, reason: '读到章末 = 该章已读');
    expect(
      (await db.getReaderPosition(row.uid))!.sectionIndex,
      2,
      reason: '书级续读位置照旧推进',
    );
    expect(
      LocalSourceMetadata.tryParse(
        (await db.getEpubBook(row.bookKey))!.sourceMetadata,
      )?.currentChapterKey,
      _chapter1,
    );

    // 未读角标：第 1 话已读，第 2 话仍未读 = 1。
    final Map<String, int> unread = computeMangaShelfUnreadCounts(
      await db.getMangaShelfReadSnapshot(),
    );
    expect(unread[row.bookKey], 1);
  });

  testWidgets('阅读器内切换章节：更新 currentChapterKey 并保留各章续读页', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      row = await insertLocalSourceRow(currentChapterKey: _chapter1);
      await tester.pumpWidget(
        _readerHarness(appModel, row.bookKey, chapterIndex: 0),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
    late bool switched;
    await tester.runAsync(() async {
      switched = await remote.goToChapter(1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    expect(switched, isTrue);
    expect(
      LocalSourceMetadata.tryParse(
        (await db.getEpubBook(row.bookKey))!.sourceMetadata,
      )?.currentChapterKey,
      _chapter2,
      reason: '换到第 2 话后 currentChapterKey 必须跟着更新',
    );
    expect(remote.snapshot()!.chapterIndex, 1);
    expect(remote.snapshot()!.pageIndex, 0, reason: '没读过的章从第 1 页开始');

    // 换回第 1 话：回到离开时停下的页码，而不是从头开始。
    await tester.runAsync(() async {
      switched = await remote.goToChapter(0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });
    expect(switched, isTrue);
    expect(remote.snapshot()!.chapterIndex, 0);
    expect(remote.snapshot()!.pageIndex, 1, reason: '各章续读页独立保留');
  });

  testWidgets('无痕阅读：保留章级位置，冻结 recency，不自动写已读 / 完成', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      await prefs.setIncognitoReading(true);
      row = await insertLocalSourceRow(currentChapterKey: _chapter1);
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(row.uid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(0),
          updatedAt: const Value<int>(1000),
        ),
      );
      await tester.pumpWidget(
        _readerHarness(appModel, row.bookKey, chapterIndex: 0),
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

    final MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: row.uid,
      chapterKey: _chapter1,
    ))!;
    expect(state.lastPage, 2, reason: '无痕仍保留章级续读位置');
    expect(state.readAt, isNull, reason: '无痕不自动写章节已读');
    expect(
      (await db.getReaderPosition(row.uid))!.updatedAt,
      1000,
      reason: '无痕冻结 reader_positions.updatedAt',
    );
    expect(
      (await db.getReaderPosition(row.uid))!.sectionIndex,
      2,
      reason: '续读页照写',
    );
    expect(
      (await db.getEpubBook(row.bookKey))!.completedAt,
      isNull,
      reason: '无痕不自动写书级完成标记',
    );
    expect(
      LocalSourceMetadata.tryParse(
        (await db.getEpubBook(row.bookKey))!.sourceMetadata,
      )?.currentChapterKey,
      _chapter1,
      reason: '章级上下文本身不因无痕而丢',
    );
  });

  testWidgets('作品页章节列表高亮 currentChapterKey 指向的当前章', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      row = await insertLocalSourceRow(currentChapterKey: _chapter2);
      await tester.pumpWidget(_seriesHarness(appModel, row.bookKey));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    final List<MediaDetailItemRow> rows = tester
        .widgetList<MediaDetailItemRow>(find.byType(MediaDetailItemRow))
        .toList();
    expect(rows, hasLength(2), reason: '本地章节全部列出');
    expect(rows.where((MediaDetailItemRow row) => row.current), hasLength(1));
    expect(
      rows.singleWhere((MediaDetailItemRow row) => row.current).title,
      _chapter2,
      reason: 'currentChapterKey 指向的章才是当前章',
    );
  });

  /// 作品页「继续阅读」实际交给阅读器的章下标。
  Future<int> tapLocalContinueAndReadChapterIndex(
    WidgetTester tester, {
    required String currentChapterKey,
    required String readChapterKey,
  }) async {
    late _CapturingOpenAppModel capturing;
    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      row = await insertLocalSourceRow(currentChapterKey: currentChapterKey);
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: readChapterKey,
        lastPage: 2,
        pageCount: 3,
        readAt: 1,
      );
      MediaSource.setDatabase(db);
      capturing = _CapturingOpenAppModel(
        database: db,
        prefs: prefs,
        paths: paths,
        directory: paths.cacheRoot,
      );
      await tester.pumpWidget(_seriesHarness(capturing, row.bookKey));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_open_local')),
      );
      for (int i = 0; i < 40 && capturing.launchPageBuilder == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(capturing.launchPageBuilder, isNotNull);
    return _launchPage(capturing.launchPageBuilder!()).initialChapterIndex!;
  }

  testWidgets('本地继续阅读：当前章已读完且后面无未读章时停在当前章', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    expect(
      await tapLocalContinueAndReadChapterIndex(
        tester,
        currentChapterKey: _chapter2,
        readChapterKey: _chapter2,
      ),
      1,
      reason: '第 2 话是最后一话且已读完，不能倒退到更早的第 1 话',
    );
  });

  testWidgets('本地继续阅读：当前章读完后面还有未读章时前进到下一未读章', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    expect(
      await tapLocalContinueAndReadChapterIndex(
        tester,
        currentChapterKey: _chapter1,
        readChapterKey: _chapter1,
      ),
      1,
      reason: '第 1 话读完，第 2 话未读：自动前进到第 2 话',
    );
  });

  testWidgets('书架进度对本地图源按章节计算，总数来自 chaptersJson', (WidgetTester tester) async {
    late EpubBookRow row;
    await tester.runAsync(() async {
      await boot();
      await writeChapter(_chapter1, 3);
      await writeChapter(_chapter2, 4);
      // chapterCount 写总页数：如果进度误用这一列，duration 会是 7 而不是 2。
      row = await insertLocalSourceRow(
        currentChapterKey: _chapter2,
        chapterCount: 7,
      );
      // 书级位置停在第 4 页（旧实现会把它当成章节进度）。
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(row.uid),
          sectionIndex: const Value<int>(3),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(0),
          updatedAt: const Value<int>(1000),
        ),
      );
    });

    final List<MediaItem> items =
        await tester.runAsync(
              () =>
                  ReaderFushiSource.instance.getBooksFromDb(appModel: appModel),
            )
            as List<MediaItem>;
    final MediaItem item = items.singleWhere(
      (MediaItem item) => item.mediaIdentifier.contains(row.bookKey),
    );
    expect(item.duration, 2, reason: '章节总数来自 chaptersJson');
    expect(item.position, 2, reason: 'currentChapterKey = 第 2 话（下标 1）→ 进度 2/2');
  });
}
