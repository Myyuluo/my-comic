import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// ticket 04 的页面级证据（真实 37 表内存库 + 真实偏好库 + 真实漫画阅读页）：
///
/// 无痕阅读开启时，翻页仍写精确续读位置（`reader_positions.sectionIndex` /
/// `charOffset`），但 `reader_positions.updatedAt`（书架「最近阅读」排序 / 继续
/// 阅读 hero 的唯一 recency 信号）冻结、书级完成标记不写；关掉开关后这些
/// History 信号恢复。开关值每次落库现读，所以页内切换立即生效。
class _IncognitoTestAppModel extends AppModel {
  _IncognitoTestAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required Directory directory,
  }) : super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  @override
  double get appUiScale => 1.0;

  // 固定顶栏：测试里不需要浮动 chrome 的收起动画。
  @override
  bool get mangaChromeFloating => false;
}

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          child ?? const SizedBox.shrink(),
      home: MangaFushiPage(item: _item(bookKey), bookKey: bookKey),
    ),
  ),
);

MediaItem _item(String bookKey) => MediaItem(
  mediaIdentifier: 'fushi://book/$bookKey',
  mediaSourceIdentifier: 'reader_manga',
  title: 'Incognito Manga',
  mediaTypeIdentifier: 'reader',
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

String _mangaJson() => jsonEncode(<String, Object?>{
  'pages': <Map<String, Object?>>[
    for (int i = 1; i <= 3; i++)
      <String, Object?>{
        'url': 'p00$i.jpg',
        'width': 100,
        'height': 150,
        'blocks': <Object?>[],
      },
  ],
});

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

// ── 在线漫画（书架条目 + 章目录）────────────────────────────────────────

class _FakeOnlineAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async => throw StateError('source unavailable');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async =>
      throw StateError('source unavailable');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _OnlineIncognitoTestAppModel extends AppModel {
  _OnlineIncognitoTestAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required Directory directory,
    required OnlineMangaLibraryService library,
  }) : _directory = directory,
       _library = library,
       super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  final Directory _directory;
  final OnlineMangaLibraryService _library;

  @override
  Directory get temporaryDirectory => _directory;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  @override
  double get appUiScale => 1.0;

  @override
  bool get mangaChromeFloating => false;

  // 开书不启整卷 OCR：测试环境没有原生 OCR 后端，自动触发会等一个永远不会
  // 就绪的引擎。与既有在线章节测试同一口径。
  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');
}

const List<OnlineMangaChapter> _onlineChapters = <OnlineMangaChapter>[
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

OnlineMangaLibraryEntry _onlineEntry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _onlineChapters,
);

Future<void> _writeDownloadedChapter(String bookDir, String chapterKey) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  await images.create(recursive: true);
  await File(p.join(images.path, 'page-000001.jpg')).writeAsBytes(<int>[1]);
  await File(p.join(images.path, 'page-000002.jpg')).writeAsBytes(<int>[2]);
  await mangaChapterJsonFile(chapterDir).writeAsString(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
        <String, Object?>{
          'url': 'images/page-000002.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
      ],
    }),
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  testWidgets('无痕：续读位置照写，最近阅读时间冻结且不写完成标记；关闭后恢复', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    // 无痕开启：本页所有落库都必须保持续读能力，但不产生 History 信号。
    await prefs.setIncognitoReading(true);

    final Directory storeDir = Directory.systemTemp.createTempSync(
      'fushi_incognito_manga',
    );
    addTearDown(() {
      if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
    });
    final AppModel appModel = _IncognitoTestAppModel(
      database: db,
      prefs: prefs,
      directory: storeDir,
    );

    final Directory bookDir = Directory.systemTemp.createTempSync(
      'fushi_incognito_book',
    );
    addTearDown(() {
      if (bookDir.existsSync()) bookDir.deleteSync(recursive: true);
    });
    File(p.join(bookDir.path, 'manga.json')).writeAsStringSync(_mangaJson());
    Directory(p.join(bookDir.path, 'images')).createSync();
    for (int i = 1; i <= 3; i++) {
      File(
        p.join(bookDir.path, 'images', 'p00$i.jpg'),
      ).writeAsBytesSync(<int>[i]);
    }

    const String bookKey = 'incognito_local_volume';
    late String bookUid;
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Incognito Manga',
          epubPath: 'manga.json',
          extractDir: bookDir.path,
          chapterCount: 3,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
        ),
      );
      bookUid = (await db.resolveEpubBookUid(bookKey))!;
      // 已有阅读历史：updatedAt 是「上次阅读时间」，必须被冻结在旧值。
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(bookUid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(0),
          updatedAt: const Value<int>(1000),
        ),
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      // 开书本身会触发一次 600ms debounce 的位置落库。
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    ReaderPositionRow pos = (await db.getReaderPosition(bookUid))!;
    expect(pos.updatedAt, 1000, reason: '开书落库也必须冻结最近阅读时间');

    // 翻到最后一页：续读位置照写，但 History 信号全部不新增。
    await tester.runAsync(() async {
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    pos = (await db.getReaderPosition(bookUid))!;
    expect(pos.sectionIndex, 2, reason: '精确续读位置必须照常写');
    expect(pos.charOffset, 0, reason: '页内精确锚照常写');
    expect(pos.updatedAt, 1000, reason: '无痕期间最近阅读时间不得推进');
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNull,
      reason: '无痕期间不得自动写书级完成标记',
    );

    // 页内关掉无痕（不重启页面）：下一次落库立即恢复 History 信号。
    await prefs.setIncognitoReading(false);
    await tester.runAsync(() async {
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToPage(0);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
      await remote.goToPage(2);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    pos = (await db.getReaderPosition(bookUid))!;
    expect(pos.sectionIndex, 2);
    expect(pos.updatedAt, greaterThan(1000), reason: '关闭无痕后最近阅读时间恢复推进');
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNotNull,
      reason: '关闭无痕后读到末页恢复自动完成标记',
    );
  });

  testWidgets('无痕：在线漫画仍写当前章进度与「继续阅读」信号，但不新增章节已读 / 书级完成', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_incognito_online_',
    );
    addTearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    EpubStorage.debugBaseDirectoryOverride = root.path;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setIncognitoReading(true);
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeOnlineAdapter(),
    );
    final AppModel appModel = _OnlineIncognitoTestAppModel(
      database: db,
      prefs: prefs,
      directory: root,
      library: library,
    );

    late String bookKey;
    late String bookUid;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_onlineEntry());
      bookKey = row.bookKey;
      bookUid = row.uid;
      // 新读者从最旧一话（列表末尾 = Chapter 1）开始。
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(bookUid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(0),
          updatedAt: const Value<int>(1000),
        ),
      );
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    expect(
      find.byKey(const ValueKey<String>('manga_content_ready')),
      findsOneWidget,
      reason: '在线章节应已装载',
    );

    // 翻到本章最后一页：页进度照写，History 信号仍不新增。
    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.goToPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: bookUid,
      chapterKey: '/chapter/1',
    ))!;
    expect(state.lastPage, 1, reason: '精确续读页必须照常写');
    expect(
      state.updatedAt,
      greaterThan(1000),
      reason: '在线漫画当前章 updatedAt 必须推进，「继续阅读」才指向当前章',
    );
    expect(state.readAt, isNull, reason: '无痕：翻到章尾也不写章节已读');
    expect((await db.getReaderPosition(bookUid))!.updatedAt, 1000);
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNull,
      reason: '无痕：不写书级完成标记',
    );

    // 章尾继续翻页（自动换章路径）：不得补写「已读」。
    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.turnPage(forward: true);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    state = (await db.getMangaChapterState(
      bookUid: bookUid,
      chapterKey: '/chapter/1',
    ))!;
    expect(state.readAt, isNull, reason: '无痕：章尾自动标记已读必须被跳过');
  });

  testWidgets('关闭无痕：在线漫画恢复章尾自动已读与书级完成标记', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_online_off_',
    );
    addTearDown(() {
      EpubStorage.debugBaseDirectoryOverride = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    EpubStorage.debugBaseDirectoryOverride = root.path;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    expect(prefs.incognitoReading, isFalse, reason: '默认关闭 = 记录 History');
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeOnlineAdapter(),
    );
    final AppModel appModel = _OnlineIncognitoTestAppModel(
      database: db,
      prefs: prefs,
      directory: root,
      library: library,
    );

    late String bookKey;
    late String bookUid;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_onlineEntry());
      bookKey = row.bookKey;
      bookUid = row.uid;
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await db.upsertReaderPosition(
        ReaderPositionsCompanion(
          bookUid: Value<String>(bookUid),
          sectionIndex: const Value<int>(0),
          normCharOffset: const Value<int>(0),
          charOffset: const Value<int>(0),
          updatedAt: const Value<int>(1000),
        ),
      );
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.goToPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });

    final MangaChapterStateRow state = (await db.getMangaChapterState(
      bookUid: bookUid,
      chapterKey: '/chapter/1',
    ))!;
    expect(state.lastPage, 1);
    expect(state.readAt, isNotNull, reason: '关闭无痕后章尾恢复自动已读');
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNotNull,
      reason: '关闭无痕后恢复书级完成标记',
    );
    expect(
      (await db.getReaderPosition(bookUid))!.updatedAt,
      greaterThan(1000),
      reason: '关闭无痕后最近阅读时间恢复推进',
    );
  });
}
