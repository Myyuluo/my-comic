import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 08 的写入侧页面级证据（真实 37 表内存库 + 真实偏好库 + 真实阅读器 /
/// 作品页）：
///
/// - 作品页开章、首页「继续」直接开书、阅读器内切章都会写 / 更新历史；
/// - 只打开作品详情页不写；
/// - 每部 Manga 一条，重复阅读只刷新 `openedAt`；
/// - 在线作品身份 = Source + 作品 id，快照保存来源身份 / URL / 标题 / 封面；
/// - 无痕阅读跳过新增与更新，已有历史保留。
class _LocalReaderAppModel extends AppModel {
  _LocalReaderAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required Directory directory,
  }) : _directory = directory,
       super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  final Directory _directory;

  @override
  Directory get temporaryDirectory => _directory;

  @override
  double get appUiScale => 1.0;

  @override
  bool get mangaChromeFloating => false;

  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');
}

class _OnlineReaderAppModel extends _LocalReaderAppModel {
  _OnlineReaderAppModel({
    required super.database,
    required super.prefs,
    required super.directory,
    required OnlineMangaLibraryService library,
  }) : _library = library;

  final OnlineMangaLibraryService _library;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;
}

class _LocalSeriesAppModel extends _LocalReaderAppModel {
  _LocalSeriesAppModel({
    required super.database,
    required super.prefs,
    required super.directory,
    required AppPaths paths,
  }) : _paths = paths;

  final AppPaths _paths;

  @override
  AppPaths get appPaths => _paths;
}

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
  ) async => <int>[0x89, 0x50, 0x4e, 0x47];
}

MediaItem _item(String bookKey) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
  mediaSourceIdentifier: 'reader_manga',
  title: 'History Manga',
  mediaTypeIdentifier: 'reader_media_type',
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

Directory _makeLocalVolume() {
  final Directory dir = Directory.systemTemp.createTempSync(
    'fushi_history_volume_',
  );
  File(p.join(dir.path, 'manga.json')).writeAsStringSync(_mangaJson());
  Directory(p.join(dir.path, 'images')).createSync();
  for (int i = 1; i <= 3; i++) {
    File(p.join(dir.path, 'images', 'p00$i.jpg')).writeAsBytesSync(<int>[i]);
  }
  return dir;
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

Future<void> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
  String chapterKey,
) async {
  final Directory chapterDir = downloadChapterDirectory(bookDir, 'Chapter 1');
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await File(p.join(chapterDir.path, '002.jpg')).writeAsBytes(<int>[2]);
  await writePagesManifestAtomically(
    chapterDir,
    MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Fixture series',
      chapterKey: chapterKey,
      chapterName: 'Chapter 1',
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
          MokuroImage(
            url: '002.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    ),
  );
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapterKey,
    folderName: 'Chapter 1',
    updatedAt: 1,
  );
}

Future<List<MediaOpenHistoryRow>> _waitForHistory(
  WidgetTester tester,
  FushiDatabase db,
  bool Function(List<MediaOpenHistoryRow> rows) predicate,
) async {
  for (int i = 0; i < 100; i++) {
    final List<MediaOpenHistoryRow> rows =
        await tester.runAsync(db.getAllMediaOpenHistory) ??
        const <MediaOpenHistoryRow>[];
    if (predicate(rows)) return rows;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  final List<MediaOpenHistoryRow> rows =
      await tester.runAsync(db.getAllMediaOpenHistory) ??
      const <MediaOpenHistoryRow>[];
  fail('never observed expected history rows; saw ${rows.length}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() {
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('打开本地卷进入阅读器：写一条历史（reader_manga + hoshi://book）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory volume = _makeLocalVolume();
    addTearDown(() {
      if (volume.existsSync()) volume.deleteSync(recursive: true);
    });

    const String bookKey = 'history_local_volume';
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'History Manga',
          epubPath: 'manga.json',
          extractDir: volume.path,
          chapterCount: 3,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );
      await tester.pumpWidget(
        _readerHarness(
          _LocalReaderAppModel(database: db, prefs: prefs, directory: volume),
          bookKey,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    final List<MediaOpenHistoryRow> rows = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) => rows.length == 1,
    );
    expect(rows, hasLength(1));
    expect(rows.single.mediaSource, 'reader_manga');
    expect(rows.single.mediaId, ReaderFushiSource.mediaIdentifierFor(bookKey));
    final Map<String, Object?> snapshot =
        jsonDecode(rows.single.snapshotJson) as Map<String, Object?>;
    expect(snapshot['title'], 'History Manga');
    expect(
      (snapshot['mangaHistory'] as Map<String, Object?>)['kind'],
      MangaHistorySnapshot.kind,
    );

    final List<MangaHistoryEntry> entries =
        await tester.runAsync(() => loadMangaHistory(db)) ??
        const <MangaHistoryEntry>[];
    expect(entries, hasLength(1));
    expect(entries.single.title, 'History Manga');
    expect(entries.single.bookKey, bookKey);
  });

  testWidgets('只打开作品详情页不写历史', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_history_detail_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    final AppPaths paths = (await tester.runAsync(AppPaths.resolve))!;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, 'Fixture series'),
    );
    final Directory chapterDir = Directory(p.join(mangaDir.path, 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Fixture series',
          epubPath: '',
          extractDir: mangaDir.path,
          chapterCount: 1,
          chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
            const LocalSourceChapterRecord(
              key: 'ch1',
              name: 'Ch 1',
              relativePath: 'Ch 1',
            ),
          ]),
          importedAt: 1,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String>(
            const LocalSourceMetadata(relativePath: 'Fixture series').encode(),
          ),
        ),
      );
      await tester.pumpWidget(
        _seriesHarness(
          _LocalSeriesAppModel(
            database: db,
            prefs: prefs,
            directory: root,
            paths: paths,
          ),
          bookKey,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
    });

    // 详情页停住，不点章节。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    expect(
      await tester.runAsync(db.getAllMediaOpenHistory),
      isEmpty,
      reason: '浏览作品详情页不算阅读，不得写历史',
    );
  });

  testWidgets('作品页开章（initialChapterIndex）进入阅读器：写 Local source 身份', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_history_series_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    final AppPaths paths = (await tester.runAsync(AppPaths.resolve))!;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, 'Fixture series'),
    );
    final Directory chapterDir = Directory(p.join(mangaDir.path, 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Fixture series',
          epubPath: '',
          extractDir: mangaDir.path,
          chapterCount: 1,
          chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
            const LocalSourceChapterRecord(
              key: 'ch1',
              name: 'Ch 1',
              relativePath: 'Ch 1',
            ),
          ]),
          importedAt: 1,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String>(
            const LocalSourceMetadata(relativePath: 'Fixture series').encode(),
          ),
        ),
      );
      // 作品页开章最终就是 `MangaFushiPage(initialChapterIndex: n)`：直接按
      // 阅读器入口验证历史写入（作品页自身的 openMedia 接线由既有页面测试覆盖，
      // 不在本票改动范围）。
      await tester.pumpWidget(
        _readerHarness(
          _LocalSeriesAppModel(
            database: db,
            prefs: prefs,
            directory: root,
            paths: paths,
          ),
          bookKey,
          chapterIndex: 0,
        ),
      );
      // 不等正文（WebView 与页图解码不是本测试的对象）：历史在正文装载前写入。
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
    });

    final List<MediaOpenHistoryRow> rows = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) => rows.length == 1,
    );
    expect(rows, hasLength(1));
    expect(rows.single.mediaSource, kMangaHistoryLocalSource);
    expect(rows.single.mediaId, 'Fixture series');
    final Map<String, Object?> snapshot =
        jsonDecode(rows.single.snapshotJson) as Map<String, Object?>;
    expect(snapshot['title'], 'Fixture series');
    final Map<String, Object?> history =
        (snapshot['mangaHistory'] as Map<String, Object?>);
    expect(history['localRelativePath'], 'Fixture series');
  });

  testWidgets('本地源阅读器内切章：每部一条，只刷新 openedAt', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_history_local_switch_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    final AppPaths paths = (await tester.runAsync(AppPaths.resolve))!;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();

    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, 'Fixture series'),
    );
    for (final String chapter in <String>['Ch 1', 'Ch 2']) {
      final Directory dir = Directory(p.join(mangaDir.path, chapter))
        ..createSync(recursive: true);
      for (int i = 1; i <= 3; i++) {
        File(p.join(dir.path, '00$i.jpg')).writeAsBytesSync(<int>[i]);
      }
    }
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    late int firstOpenedAt;
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Fixture series',
          epubPath: '',
          extractDir: mangaDir.path,
          chapterCount: 6,
          chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
            const LocalSourceChapterRecord(
              key: 'Ch 1',
              name: 'Ch 1',
              relativePath: 'Ch 1',
            ),
            const LocalSourceChapterRecord(
              key: 'Ch 2',
              name: 'Ch 2',
              relativePath: 'Ch 2',
            ),
          ]),
          importedAt: 1,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String>(
            const LocalSourceMetadata(
              relativePath: 'Fixture series',
              currentChapterKey: 'Ch 1',
            ).encode(),
          ),
        ),
      );
      await tester.pumpWidget(
        _readerHarness(
          _LocalSeriesAppModel(
            database: db,
            prefs: prefs,
            directory: root,
            paths: paths,
          ),
          bookKey,
          chapterIndex: 0,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    final List<MediaOpenHistoryRow> first = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) => rows.length == 1,
    );
    firstOpenedAt = first.single.openedAt;
    expect(first.single.mediaSource, kMangaHistoryLocalSource);
    expect(first.single.mediaId, 'Fixture series');

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.runAsync(() async {
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      expect(await remote.goToChapter(1), isTrue);
    });
    await tester.pump();

    final List<MediaOpenHistoryRow> afterSwitch = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) =>
          rows.length == 1 && rows.single.openedAt > firstOpenedAt,
    );
    expect(afterSwitch, hasLength(1), reason: '每部 Manga 一条，不得新增第二行');
    expect(afterSwitch.single.mediaSource, kMangaHistoryLocalSource);
    expect(afterSwitch.single.mediaId, 'Fixture series');
  });

  testWidgets('在线书直接开书 + 阅读器内切章：每部一条，只刷新 openedAt', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_history_online_',
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
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeOnlineAdapter(),
    );

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_onlineEntry());
      bookKey = row.bookKey;
      await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
        '/chapter/1',
      );
      await tester.pumpWidget(
        _readerHarness(
          _OnlineReaderAppModel(
            database: db,
            prefs: prefs,
            directory: root,
            library: library,
          ),
          bookKey,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    // 直接开书（首页「继续」同一条路径）：写一条在线身份历史。
    final List<MediaOpenHistoryRow> first = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) => rows.length == 1,
    );
    final OnlineMangaLibraryEntry entry = _onlineEntry();
    expect(first.single.mediaSource, mangaHistoryOnlineSourceKey(entry));
    expect(first.single.mediaId, entry.series.key);
    final Map<String, Object?> snapshot =
        jsonDecode(first.single.snapshotJson) as Map<String, Object?>;
    expect(snapshot['title'], 'Fixture series');
    final Map<String, Object?> online =
        ((snapshot['mangaHistory'] as Map<String, Object?>)['online']
            as Map<String, Object?>);
    expect(online['runtime'], 'mihon');
    expect(online['extensionPackage'], 'org.example.fixture');
    expect(online['sourceId'], '1');
    expect(online['seriesKey'], '/series/fixture');
    expect(online['url'], '/series/fixture');
    final int openedAt = first.single.openedAt;

    // 阅读器内切章：仍是同一条，只刷新 openedAt。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.runAsync(() async {
      final ReaderSessionRemote remote = readerSessionRemotes.current.value!;
      await remote.goToChapter(0);
    });
    await tester.pump();

    final List<MediaOpenHistoryRow> afterSwitch = await _waitForHistory(
      tester,
      db,
      (List<MediaOpenHistoryRow> rows) =>
          rows.length == 1 && rows.single.openedAt > openedAt,
    );
    expect(afterSwitch, hasLength(1), reason: '每部 Manga 一条，不得新增第二行');
    expect(afterSwitch.single.mediaSource, first.single.mediaSource);
    expect(afterSwitch.single.mediaId, first.single.mediaId);
  });

  testWidgets('无痕阅读：不新增历史', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setIncognitoReading(true);
    final Directory volume = _makeLocalVolume();
    addTearDown(() {
      if (volume.existsSync()) volume.deleteSync(recursive: true);
    });

    const String bookKey = 'history_incognito_volume';
    await tester.runAsync(() async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'History Manga',
          epubPath: 'manga.json',
          extractDir: volume.path,
          chapterCount: 3,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );
      await tester.pumpWidget(
        _readerHarness(
          _LocalReaderAppModel(database: db, prefs: prefs, directory: volume),
          bookKey,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    expect(
      await tester.runAsync(db.getAllMediaOpenHistory),
      isEmpty,
      reason: '无痕阅读不得新增历史',
    );
  });

  testWidgets('无痕阅读：已有历史保留，不被刷新', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory volume = _makeLocalVolume();
    addTearDown(() {
      if (volume.existsSync()) volume.deleteSync(recursive: true);
    });

    const String bookKey = 'history_incognito_existing';
    late MediaOpenHistoryRow before;
    await tester.runAsync(() async {
      final String insertedKey = await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'History Manga',
          epubPath: 'manga.json',
          extractDir: volume.path,
          chapterCount: 3,
          chaptersJson: '[]',
          importedAt: 1,
          format: const Value<String>('manga'),
        ),
      );
      final EpubBookRow row = (await db.getEpubBook(insertedKey))!;
      await recordMangaHistoryOpened(db: db, row: row);
      before = (await db.getAllMediaOpenHistory()).single;
      await prefs.setIncognitoReading(true);
      await tester.pumpWidget(
        _readerHarness(
          _LocalReaderAppModel(database: db, prefs: prefs, directory: volume),
          bookKey,
        ),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    final List<MediaOpenHistoryRow> after = (await tester.runAsync(
      db.getAllMediaOpenHistory,
    ))!;
    expect(after, hasLength(1));
    expect(after.single.openedAt, before.openedAt, reason: '无痕不刷新 openedAt');
    expect(after.single.snapshotJson, before.snapshotJson);
  });
}
