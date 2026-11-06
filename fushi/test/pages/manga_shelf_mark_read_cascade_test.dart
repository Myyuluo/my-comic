// 漫画卡「标记为已读完 / 取消已读完」的级联行为（2026-11-05 漫画页 UI 修正）。
//
// 用户口径：在线漫画标记读完时本书所有 Chapter 都要变成已读，取消时清空所有
// Chapter 的已读时刻；两种情况都保留每章上次页码与当前章位置，下次仍从原页继续。
// 本地卷没有 Chapter，只切换书级完成标记，不动阅读位置 / 页进度。
//
// 这是页面级测试：真实 37 表内存库 + 真实 Manifest 页面，长按卡片打开菜单并点
// 动作，只断言用户可见结果与数据库事实，不伸手进私有方法。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

const String _onlineBookKey = 'manga_mark_read_online';
const String _onlineTitle = '在线漫画';
const String _localVolumeKey = 'manga_mark_read_local';
const String _localVolumeTitle = '本地卷';

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{'url': '/chapter/3'},
  ),
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

OnlineMangaLibraryEntry _onlineEntry({int? currentChapterIndex = 1}) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: _onlineTitle,
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
      currentChapterIndex: currentChapterIndex,
    );

MediaItem _mangaItem({
  required String bookKey,
  required String title,
  int position = 0,
  int duration = 100,
}) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
  title: title,
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
  position: position,
  duration: duration,
  canDelete: false,
  canEdit: true,
);

/// 离线测试壳：作品页解析在线服务时不能真的去拉 Mihon 运行时（Windows 上会起
/// sidecar）。作品页对解析失败有兜底（读描述符离线渲染），正好用来验证章节列表。
class _OfflineAppModel extends AppModel {
  _OfflineAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required Directory directory,
  }) : super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(
      prefsRepo: prefs,
      databaseDirectory: directory,
    );
  }

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => throw UnsupportedError('offline test has no online source runtime');
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_manga_mark_pp');
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
  late AppModel appModel;
  late PreferencesRepository prefs;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_mark_store');
    appModel = _OfflineAppModel(
      database: db,
      prefs: prefs,
      directory: storeDir,
    );
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  /// 插入一条带在线漫画描述符的书架条目。
  Future<EpubBookRow> insertOnlineManga({DateTime? completedAt}) async {
    final OnlineMangaLibraryEntry entry = _onlineEntry();
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _onlineBookKey,
        title: _onlineTitle,
        epubPath: '/tmp/$_onlineBookKey',
        extractDir: '/tmp/$_onlineBookKey',
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        completedAt: Value<DateTime?>(completedAt),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  /// 插入一条本地漫画卷（format='manga'，没有在线描述符 = 没有 Chapter）。
  Future<EpubBookRow> insertLocalVolume() async {
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _localVolumeKey,
        title: _localVolumeTitle,
        epubPath: '/tmp/$_localVolumeKey',
        extractDir: '/tmp/$_localVolumeKey',
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  /// 以指定 `updatedAt` 播种一章状态（import 路径可显式给时刻，见 Backup Import）。
  Future<void> seedChapterState(
    String bookUid,
    String chapterKey, {
    required int lastPage,
    required int updatedAt,
    int? readAt,
    int lastFraction = -1,
    int pageCount = 40,
  }) => db.importMangaChapterState(
    bookUid: bookUid,
    chapterKey: chapterKey,
    lastPage: lastPage,
    lastFraction: lastFraction,
    pageCount: pageCount,
    readAt: readAt,
    updatedAt: updatedAt,
  );

  Widget buildApp(List<MediaItem> books) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(books),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            mangaOnly: true,
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  /// 作品页：真实 DB + 描述符离线渲染章节列表（服务解析失败是页面已有的兜底）。
  ///
  /// override 集合必须与 [buildApp] **逐项相同**：同一棵 widget 树里 Riverpod
  /// 不允许增删 override，而换 key 重建 scope 会连坐 dispose 同一个 AppModel。
  /// 逐项相同时 ProviderScope 原地更新，测试结束时只 dispose 一次。
  Widget buildSeriesApp(String bookKey) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: MangaSeriesPage(
          target: ShelfMangaSeriesTarget(bookKey),
        ),
      ),
    ),
  );

  Future<void> sizeNarrowAndTall(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
  }

  Future<void> openMangaMenu(WidgetTester tester, String title) async {
    await sizeNarrowAndTall(tester);
    await tester.longPress(find.text(title).first);
    await tester.pumpAndSettle();
  }

  /// 在真实异步里点菜单动作，并等 [ready] 成立（返回 true）。
  ///
  /// 菜单动作会 `Navigator.pop` 后 await 数据库；fake 时钟的 pump 推不动真实
  /// IO，与 ticket 03 的删除确认测试一样放进 `runAsync`。
  Future<void> tapMenuActionAndWait(
    WidgetTester tester,
    String label,
    Future<bool> Function() ready,
  ) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(label));
      await tester.pump();
      for (int i = 0; i < 160; i++) {
        if (await ready()) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      throw StateError('等待数据库状态超时（$label）');
    });
    await tester.pumpAndSettle();
  }

  /// 让真实异步（DB 读、书架重取完成集合）落地并推进一帧；fake 时钟推不动它们。
  Future<void> pumpRealAsync(WidgetTester tester, {int steps = 20}) async {
    await tester.runAsync(() async {
      for (int i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('在线漫画标记为已读完：全部 Chapter 写入已读时刻，页码与当前章不变',
      (WidgetTester tester) async {
    late Map<String, MangaChapterStateRow> before;
    late int beforeContinueLastPosition;
    final EpubBookRow? seeded = await tester.runAsync(() async {
      final EpubBookRow row = await insertOnlineManga();
      await seedChapterState(row.uid, '/chapter/3', lastPage: 5, updatedAt: 1000);
      await seedChapterState(
        row.uid,
        '/chapter/2',
        lastPage: 9,
        lastFraction: 3,
        updatedAt: 3000,
      );
      // /chapter/1 故意不播种：级联会新插一行，updatedAt 必须是 0（不参与
      // 「最近动过哪一章」的竞争），不能是 now 把续读选章顶到列表首章。
      before = await db.getMangaChapterStates(row.uid);
      beforeContinueLastPosition = continueMangaChapterIndex(
        _onlineEntry(),
        before,
        target: MangaResumeTarget.lastPosition,
      );
      return row;
    });
    final EpubBookRow row = seeded!;

    await tester.pumpWidget(
      buildApp(<MediaItem>[
        _mangaItem(bookKey: _onlineBookKey, title: _onlineTitle),
      ]),
    );
    await tester.pumpAndSettle();

    await openMangaMenu(tester, _onlineTitle);
    expect(find.text(t.book_mark_completed_action), findsOneWidget);

    await tapMenuActionAndWait(
      tester,
      t.book_mark_completed_action,
      () async {
        final EpubBookRow? after = await db.getEpubBook(_onlineBookKey);
        final Map<String, MangaChapterStateRow> states =
            await db.getMangaChapterStates(row.uid);
        return after?.completedAt != null &&
            states.length == _chapters.length &&
            states.values.every(
              (MangaChapterStateRow state) => state.readAt != null,
            );
      },
    );

    final EpubBookRow? after = await tester.runAsync<EpubBookRow?>(
      () => db.getEpubBook(_onlineBookKey),
    );
    expect(after?.completedAt, isNotNull, reason: '书级完成标记必须写入');
    final String? metadata = after?.sourceMetadata;
    expect(
      OnlineMangaLibraryEntry.tryParse(metadata)?.currentChapterIndex,
      1,
      reason: '当前章位置不能被级联改写',
    );

    final Map<String, MangaChapterStateRow> states =
        (await tester.runAsync(() => db.getMangaChapterStates(row.uid)))!;
    expect(
      states.keys.toSet(),
      _chapters.map((OnlineMangaChapter chapter) => chapter.key).toSet(),
    );
    expect(
      states['/chapter/3']!.lastPage,
      5,
      reason: '标记读完不能改每章上次页码',
    );
    expect(states['/chapter/2']!.lastPage, 9);
    expect(
      states['/chapter/2']!.lastFraction,
      3,
      reason: '连续阅读的偏移也保留',
    );
    expect(
      states['/chapter/3']!.updatedAt,
      1000,
      reason: '既有行的 updatedAt 是续读选章判据，级联不能盖成 now',
    );
    expect(states['/chapter/2']!.updatedAt, 3000);
    expect(
      states['/chapter/1']!.updatedAt,
      0,
      reason: '级联新插入的行用 0，不参与「最近动过哪一章」的竞争',
    );
    expect(
      states['/chapter/1']!.readAt,
      isNotNull,
      reason: '新插入的行同样要写成已读',
    );
    // 播种时声明的当前章 = updatedAt 最大的 /chapter/2（列表下标 1）。
    expect(beforeContinueLastPosition, 1);
    expect(
      continueMangaChapterIndex(
        _onlineEntry(),
        states,
        target: MangaResumeTarget.lastPosition,
      ),
      1,
      reason: '标记读完不得把「最近续读」的当前章换成列表首章',
    );
  });

  testWidgets('在线漫画取消已读完：清空全部 Chapter 已读时刻，页码与当前章保持不变',
      (WidgetTester tester) async {
    final EpubBookRow? seeded = await tester.runAsync(() async {
      final EpubBookRow row = await insertOnlineManga(
        completedAt: DateTime(2026, 11, 5),
      );
      // /chapter/2 是最后动过的一章（updatedAt 最大）= 当前章。
      await seedChapterState(
        row.uid,
        '/chapter/3',
        lastPage: 5,
        updatedAt: 1000,
        readAt: 900,
      );
      await seedChapterState(
        row.uid,
        '/chapter/2',
        lastPage: 9,
        lastFraction: 3,
        updatedAt: 3000,
        readAt: 900,
      );
      await seedChapterState(
        row.uid,
        '/chapter/1',
        lastPage: 15,
        updatedAt: 2000,
        readAt: 900,
      );
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: row.uid,
          sectionIndex: 12,
          normCharOffset: 0,
          updatedAt: 1700000000000,
        ),
      );
      return row;
    });
    final EpubBookRow row = seeded!;
    final Map<String, MangaChapterStateRow> before =
        (await tester.runAsync(() => db.getMangaChapterStates(row.uid)))!;
    final int beforeContinueLastPosition = continueMangaChapterIndex(
      _onlineEntry(),
      before,
      target: MangaResumeTarget.lastPosition,
    );
    expect(beforeContinueLastPosition, 1, reason: '播种的当前章是 /chapter/2');

    await tester.pumpWidget(
      buildApp(<MediaItem>[
        _mangaItem(bookKey: _onlineBookKey, title: _onlineTitle),
      ]),
    );
    await tester.pumpAndSettle();

    await openMangaMenu(tester, _onlineTitle);
    expect(find.text(t.book_mark_uncompleted_action), findsOneWidget);

    await tapMenuActionAndWait(
      tester,
      t.book_mark_uncompleted_action,
      () async {
        final EpubBookRow? after = await db.getEpubBook(_onlineBookKey);
        final Map<String, MangaChapterStateRow> states =
            await db.getMangaChapterStates(row.uid);
        return after?.completedAt == null &&
            states.length == _chapters.length &&
            states.values.every(
              (MangaChapterStateRow state) => state.readAt == null,
            );
      },
    );

    final EpubBookRow? afterRow = await tester.runAsync<EpubBookRow?>(
      () => db.getEpubBook(_onlineBookKey),
    );
    expect(afterRow?.completedAt, isNull, reason: '书级完成标记必须清除');
    expect(
      OnlineMangaLibraryEntry.tryParse(afterRow?.sourceMetadata)
          ?.currentChapterIndex,
      1,
      reason: '当前章位置不能被取消级联改写',
    );

    final Map<String, MangaChapterStateRow> after =
        (await tester.runAsync(() => db.getMangaChapterStates(row.uid)))!;
    for (final OnlineMangaChapter chapter in _chapters) {
      final MangaChapterStateRow stateBefore = before[chapter.key]!;
      final MangaChapterStateRow stateAfter = after[chapter.key]!;
      expect(stateAfter.lastPage, stateBefore.lastPage, reason: '${chapter.key} 页码保留');
      expect(
        stateAfter.lastFraction,
        stateBefore.lastFraction,
        reason: '${chapter.key} 连续阅读偏移保留',
      );
      expect(stateAfter.pageCount, stateBefore.pageCount);
      expect(
        stateAfter.updatedAt,
        stateBefore.updatedAt,
        reason: '${chapter.key} updatedAt 是续读选章判据，整书清读不能把它盖成 now',
      );
    }
    // 当前章 = updatedAt 最大的 /chapter/2；取消后所有章未读，继续阅读不再前进。
    expect(
      continueMangaChapterIndex(_onlineEntry(), after),
      1,
      reason: '取消后当前章仍是最后动过的那章，而不是列表首章',
    );
    expect(
      continueMangaChapterIndex(
        _onlineEntry(),
        after,
        target: MangaResumeTarget.lastPosition,
      ),
      beforeContinueLastPosition,
      reason: '取消已读完前后，最近续读的当前章必须保持不变',
    );
    expect(
      resolveMangaChapterResumePoint(after['/chapter/2']),
      9,
      reason: '下次仍从原页继续',
    );

    final ReaderPositionRow? position = await tester.runAsync<ReaderPositionRow?>(
      () => db.getReaderPosition(row.uid),
    );
    expect(
      position?.sectionIndex,
      12,
      reason: 'ReaderPosition 不属于章状态，取消已读完不能动它',
    );
  });

  testWidgets('本地卷标记 / 取消已读完只切换书级完成标记，不动阅读位置和章状态',
      (WidgetTester tester) async {
    final EpubBookRow? seeded = await tester.runAsync(() async {
      final EpubBookRow row = await insertLocalVolume();
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: row.uid,
          sectionIndex: 7,
          normCharOffset: 3,
          updatedAt: 1700000000000,
        ),
      );
      return row;
    });
    final EpubBookRow row = seeded!;

    await tester.pumpWidget(
      buildApp(<MediaItem>[
        _mangaItem(bookKey: _localVolumeKey, title: _localVolumeTitle),
      ]),
    );
    await tester.pumpAndSettle();

    await openMangaMenu(tester, _localVolumeTitle);
    expect(find.text(t.book_mark_completed_action), findsOneWidget);
    await tapMenuActionAndWait(
      tester,
      t.book_mark_completed_action,
      () async {
        final EpubBookRow? after = await db.getEpubBook(_localVolumeKey);
        return after?.completedAt != null;
      },
    );
    await pumpRealAsync(tester);

    EpubBookRow? afterRow = await tester.runAsync<EpubBookRow?>(
      () => db.getEpubBook(_localVolumeKey),
    );
    expect(afterRow?.completedAt, isNotNull, reason: '本地卷的书级完成标记要写入');
    ReaderPositionRow? position =
        await tester.runAsync<ReaderPositionRow?>(
      () => db.getReaderPosition(row.uid),
    );
    expect(position?.sectionIndex, 7, reason: '标记读完不能改页进度');
    expect(position?.normCharOffset, 3);
    expect(
      await tester.runAsync<Map<String, MangaChapterStateRow>>(
        () => db.getMangaChapterStates(row.uid),
      ),
      isEmpty,
      reason: '本地卷没有 Chapter，不能凭空写章状态',
    );

    // 标记后菜单立即变成「取消已读完」。
    await openMangaMenu(tester, _localVolumeTitle);
    expect(find.text(t.book_mark_uncompleted_action), findsOneWidget);
    await tapMenuActionAndWait(
      tester,
      t.book_mark_uncompleted_action,
      () async {
        final EpubBookRow? after = await db.getEpubBook(_localVolumeKey);
        return after?.completedAt == null;
      },
    );

    afterRow = await tester.runAsync<EpubBookRow?>(
      () => db.getEpubBook(_localVolumeKey),
    );
    expect(afterRow?.completedAt, isNull, reason: '取消已读完清掉书级完成标记');
    position = await tester.runAsync<ReaderPositionRow?>(
      () => db.getReaderPosition(row.uid),
    );
    expect(position?.sectionIndex, 7, reason: '取消读完也不能改页进度');
    expect(position?.normCharOffset, 3);
    expect(
      await tester.runAsync<Map<String, MangaChapterStateRow>>(
        () => db.getMangaChapterStates(row.uid),
      ),
      isEmpty,
    );
  });

  testWidgets('标记已读完立即更新阅读状态筛选，作品页章节列表同步点亮',
      (WidgetTester tester) async {
    await tester.runAsync(() async {
      final EpubBookRow row = await insertOnlineManga();
      await seedChapterState(row.uid, '/chapter/3', lastPage: 0, updatedAt: 1000);
      await seedChapterState(row.uid, '/chapter/2', lastPage: 0, updatedAt: 2000);
      await seedChapterState(row.uid, '/chapter/1', lastPage: 0, updatedAt: 3000);
    });
    await prefs.setShelfReadStatusFilterName('unread');

    await tester.pumpWidget(
      buildApp(<MediaItem>[
        _mangaItem(bookKey: _onlineBookKey, title: _onlineTitle),
      ]),
    );
    await tester.pumpAndSettle();
    expect(find.text(_onlineTitle), findsWidgets, reason: '未读筛选下未读卡可见');

    await openMangaMenu(tester, _onlineTitle);
    await tapMenuActionAndWait(
      tester,
      t.book_mark_completed_action,
      () async {
        final EpubBookRow? after = await db.getEpubBook(_onlineBookKey);
        return after?.completedAt != null;
      },
    );

    // 书架重取完成集合后，「未读」筛选应立即把已读完的卡筛掉。
    await tester.runAsync(() async {
      for (int i = 0; i < 120; i++) {
        if (find.text(_onlineTitle).evaluate().isEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      throw StateError('阅读状态筛选没有立即更新');
    });
    expect(find.text(_onlineTitle), findsNothing, reason: '完成后不再属于「未读」');

    // 切到「读完」应重新出现——完成视觉的真值就是书级 completedAt。
    await tester.tap(
      find.byKey(const ValueKey<String>('library_sort_menu_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('shelf_filter_read_status_finished')),
    );
    await tester.pumpAndSettle();
    expect(find.text(_onlineTitle), findsWidgets, reason: '「读完」筛选应看到这张卡');

    // 作品页章节列表：同一份章状态 → 每章行尾都点亮已读对勾。
    await tester.pumpWidget(buildSeriesApp(_onlineBookKey));
    await tester.runAsync(() async {
      for (int i = 0; i < 160; i++) {
        if (find.text('Chapter 1').evaluate().isNotEmpty) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
      throw StateError('作品页章节列表未渲染');
    });
    expect(
      find.byKey(const ValueKey<String>('media-detail-item-completed')),
      findsNWidgets(_chapters.length),
      reason: '作品页章节列表必须反映级联后的已读状态',
    );
  });
}
