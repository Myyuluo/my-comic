// Ticket 02：漫画页批量下载只服务在线漫画。
//
// 判定与「下载全部」同源：本地在线漫画条目 = `epub_books` 行 + 可解析的在线漫画
// 描述符（带章节列表）；本地卷 = 没有在线描述符的漫画行。批量下载遇到本地卷跳过
// 并提示数量；在线条目按作品页「下载全部」的规则入队——已下载、已排队、锁定的
// 章节都不重复入队。
import 'dart:convert';
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
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_storage.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart' show SyncTransferProgress;
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

const List<OnlineMangaChapter> _remoteChapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/remote/ch3',
    name: '\u{1F512} Remote 3',
    number: 3,
    locked: true,
    raw: <String, Object?>{'url': '/remote/ch3'},
  ),
  OnlineMangaChapter(
    key: '/remote/ch2',
    name: 'Remote 2',
    number: 2,
    raw: <String, Object?>{'url': '/remote/ch2'},
  ),
  OnlineMangaChapter(
    key: '/remote/ch1',
    name: 'Remote 1',
    number: 1,
    raw: <String, Object?>{'url': '/remote/ch1'},
  ),
];

const RemoteBookInfo _remoteChapteredBook = RemoteBookInfo(
  title: 'Remote Chaptered',
  bookKey: 'peer-chaptered-1',
  hasContent: false,
  format: 'manga',
  hasMangaContent: false,
  hasMangaChapters: true,
);

const RemoteBookInfo _remoteWholeBook = RemoteBookInfo(
  title: 'Remote Whole Book',
  bookKey: 'peer-whole-1',
  hasContent: true,
  format: 'manga',
  hasMangaContent: true,
  hasMangaChapters: false,
);

/// 普通 EPUB 远端书：非漫画，批量下载不得服务（ticket 02 复审 B）。
const RemoteBookInfo _remoteEpubBook = RemoteBookInfo(
  title: 'Remote Epub',
  bookKey: 'peer-epub-1',
  hasContent: true,
  format: 'epub',
);

/// 纯 SRT 远端有声书：非漫画，批量下载不得服务（ticket 02 复审 B）。
const RemoteAudiobookInfo _remoteSrtAudiobook = RemoteAudiobookInfo(
  bookKey: '',
  uid: 'remote-srt-1',
  title: 'Remote SRT',
  hasAudio: true,
);

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/4',
    name: '\u{1F512} Chapter 4',
    number: 4,
    locked: true,
    raw: <String, Object?>{'url': '/chapter/4'},
  ),
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

OnlineMangaLibraryEntry _onlineEntry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture Online Manga',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
);

/// AppModel 只在测试需要时覆盖在线漫画服务 / 模块可见性。
///
/// my-comic 的 `ModuleVisibility.resolve` 只保留 manga / browse；远端占位卡在
/// 生产里不可达（同步互联已移除）。ticket 02 仍要求远端章节漫画与整本包分支的
/// 行为正确，故测试通过覆盖 [moduleVisibility] 打开 sync 门，走页面真实的远端
/// 渲染与下载路径。
class _TestAppModel extends AppModel {
  _TestAppModel({
    required FushiDatabase db,
    required PreferencesRepository prefs,
    required Directory storeDir,
    this.library,
  }) : super(testPlatformServices()) {
    wireDatabaseForTesting(db);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    populateLanguages();
    populateMediaTypes();
    populateMediaSources();
  }

  final OnlineMangaLibraryService? library;

  @override
  ModuleVisibility get moduleVisibility => const ModuleVisibility(
    <ModuleId>{ModuleId.manga, ModuleId.browse, ModuleId.sync},
  );

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) =>
      library ?? super.onlineMangaLibraryService(runtime);
}

class _FakeMangaAdapter implements OnlineMangaRuntimeAdapter {
  _FakeMangaAdapter(this.refreshedChapters);

  final List<OnlineMangaChapter> refreshedChapters;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.interconnect;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(
        series: entry.series,
        chapters: refreshedChapters,
      );

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the shelf must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the shelf must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

/// 可当「互联对端」用的远端客户端：章节漫画收养路径要求
/// `client is InterconnectSyncBackend`，因此继承真实后端并只覆写测试用到的端点。
class _FakeInterconnectClient extends InterconnectSyncBackend {
  _FakeInterconnectClient(
    this.books, {
    this.audiobooks = const <RemoteAudiobookInfo>[],
  }) : super.withProbe((String _, String __) async => true);

  final List<RemoteBookInfo> books;
  final List<RemoteAudiobookInfo> audiobooks;
  final List<String> fetchedTitles = <String>[];
  final List<String> fetchedAudiobookIds = <String>[];

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteBookInfo>> listRemoteBooks() async => books;

  @override
  Future<List<RemoteAudiobookInfo>> listRemoteAudiobooks() async => audiobooks;

  @override
  Future<void> getRemoteAudiobook(
    String bookKey,
    File dest, {
    SyncTransferProgress? onProgress,
    bool fresh = false,
  }) async {
    fetchedAudiobookIds.add(bookKey);
    await dest.writeAsBytes(<int>[1]);
  }

  @override
  Future<void> getRemoteBook(
    String title,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    fetchedTitles.add(title);
    await destination.writeAsBytes(<int>[1]);
  }

  @override
  Future<RemoteBookProgress> remoteBookProgress(String bookKey) async =>
      RemoteBookProgress.empty;

  @override
  Future<void> putRemoteBookProgress(
    String bookKey,
    RemoteBookProgress progress,
  ) async {}
}

void _writeDownloadedChapter(String bookDir, String chapterKey) {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  images.createSync(recursive: true);
  File(p.join(images.path, 'page-000001.jpg')).writeAsBytesSync(<int>[1]);
  mangaChapterJsonFile(chapterDir).writeAsStringSync(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[],
        },
      ],
    }),
  );
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_batch_download_pp',
    );
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

  late Directory root;
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late Directory storeDir;
  late List<MediaItem> books;
  late _TestAppModel appModel;
  late GlobalKey<NavigatorState> navKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = Directory.systemTemp.createTempSync('fushi_batch_download_root');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_batch_download_store');
    books = <MediaItem>[];
    appModel = _TestAppModel(db: db, prefs: prefs, storeDir: storeDir);
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    for (final Directory dir in <Directory>[root, storeDir]) {
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  MediaItem mediaItemFor(String bookKey, String title) => MediaItem(
    mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
    title: title,
    mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
    position: 0,
    duration: 1,
    canDelete: true,
    canEdit: true,
  );

  Future<String> seedOnlineManga() async {
    final OnlineMangaLibraryEntry entry = _onlineEntry();
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(entry);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: entry.series.title,
        epubPath: '${root.path}/$bookKey.mokuro',
        extractDir: p.join(root.path, bookKey),
        chapterCount: entry.chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    books.add(mediaItemFor(bookKey, entry.series.title));
    return bookKey;
  }

  Future<String> seedLocalVolume() async {
    const String bookKey = 'manga:local:volume';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Local Volume',
        epubPath: '${root.path}/$bookKey.mokuro',
        extractDir: p.join(root.path, bookKey),
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    books.add(mediaItemFor(bookKey, 'Local Volume'));
    return bookKey;
  }

  Widget buildApp({
    RemoteBookClient? remoteClient,
    bool mangaOnly = true,
  }) => ProviderScope(
    overrides: <Override>[
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
        navigatorKey: navKey,
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            mangaOnly: mangaOnly,
            remoteBookClientLoader: () async => remoteClient,
            remoteBookDownloadDestination: (RemoteBookInfo book) async =>
                File('${pathProviderDir.path}/${book.title.hashCode}.bin'),
            remoteBookImporter: (File file) async => null,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    RemoteBookClient? remoteClient,
    bool mangaOnly = true,
  }) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    navKey = GlobalKey<NavigatorState>();
    // FushiToast 在桌面/测试走自绘 overlay，必须有 navigatorKey 才渲染。
    FushiToast.navigatorKey = navKey;
    await tester.pumpWidget(
      buildApp(remoteClient: remoteClient, mangaOnly: mangaOnly),
    );
    await tester.pumpAndSettle();
  }

  Finder bookCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  Finder remoteCard(String title) => find.byKey(
    ValueKey<String>(
      'remote_book_card_${sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}',
    ),
  );

  Finder remoteSrtCard(String title) => find.byKey(
    ValueKey<String>(
      'remote_srt_card_${sanitizeTtuFilename(title).replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}',
    ),
  );

  bool batchButtonEnabled(WidgetTester tester, String key) => tester
      .widget<FushiIconButton>(find.byKey(ValueKey<String>(key)))
      .enabled;

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(FushiIcons.checklist));
    await tester.pumpAndSettle();
  }

  testWidgets('本地在线漫画可批量下载：跳过本地卷、已下载、已排队与锁定章节', (
    WidgetTester tester,
  ) async {
    final String onlineKey = await seedOnlineManga();
    final String volumeKey = await seedLocalVolume();
    final OnlineMangaLibraryEntry entry = _onlineEntry();

    // 已排队：第 3 章已有 queued 任务。
    await appModel.mangaDownloadService.enqueueChapter(
      entry: entry,
      chapter: _chapters[1],
      autoOcr: false,
    );
    // 已下载：第 2 章完整落盘。
    _writeDownloadedChapter(
      await MangaStorage.bookPath(onlineKey),
      '/chapter/2',
    );

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(bookCard(onlineKey));
    await tester.pumpAndSettle();
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isTrue,
      reason: '选中本地在线漫画时必须启用批量下载',
    );

    await tester.tap(bookCard(volumeKey));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 批量下载要读磁盘上的「已下载」判据：真实文件 IO 在 fake async 区里不会
    // 自己推进，和作品页的下载测试一样用 runAsync 放真时间再 pump。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
      );
      await tester.pump();
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find
            .textContaining(t.manga_series_download_all_queued(count: 1))
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.textContaining(t.batch_download_local_volumes_skipped(count: 1)),
      findsOneWidget,
      reason: '混合选中时要提示跳过的本地卷数量',
    );
    expect(
      find.textContaining(t.manga_series_download_all_locked_skipped(count: 1)),
      findsOneWidget,
      reason: '锁定章节按既有规则跳过并提示',
    );
    expect(
      find.textContaining(t.manga_series_download_all_queued(count: 1)),
      findsOneWidget,
      reason: '只有第 1 章需要新入队',
    );

    final List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(
      jobs
          .where((MangaDownloadJobRow job) => job.bookKey == onlineKey)
          .map((MangaDownloadJobRow job) => job.chapterKey)
          .toSet(),
      <String>{'/chapter/1', '/chapter/3'},
      reason: '已排队第 3 章保留、未下载第 1 章入队；已下载第 2 章与锁定第 4 章不入队',
    );
    expect(
      jobs.any((MangaDownloadJobRow job) => job.bookKey == volumeKey),
      isFalse,
      reason: '本地卷没有下载动作',
    );
    expect(
      find.byIcon(FushiIcons.checklist),
      findsOneWidget,
      reason: '批量下载开始后退出多选态',
    );
  });

  testWidgets('只选中本地卷时批量下载按钮禁用', (WidgetTester tester) async {
    await seedLocalVolume();
    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(bookCard('manga:local:volume'));
    await tester.pumpAndSettle();

    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isFalse,
      reason: '本地卷没有可下载的章节，下载按钮必须禁用',
    );
  });

  OnlineMangaLibraryService remoteLibrary() => OnlineMangaLibraryService(
    database: db,
    rootDirectory: Directory(p.join(storeDir.path, 'legacy')),
    adapter: _FakeMangaAdapter(_remoteChapters),
  );

  void useRemoteLibrary() {
    appModel = _TestAppModel(
      db: db,
      prefs: prefs,
      storeDir: storeDir,
      library: remoteLibrary(),
    );
  }

  testWidgets('远端章节在线漫画：批量下载先入 Library 再按下载全部规则入队', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[_remoteChapteredBook],
    );
    useRemoteLibrary();
    await pumpPage(tester, remoteClient: client);
    expect(remoteCard('Remote Chaptered'), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard('Remote Chaptered'));
    await tester.pumpAndSettle();
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isTrue,
      reason: '远端章节在线漫画必须启用批量下载',
    );

    final String localBookKey = InterconnectMangaCatalog.localBookKeyFor(
      'peer-chaptered-1',
    );
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
      );
      await tester.pump();
      for (int i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final List<MangaDownloadJobRow> jobs =
            await db.listMangaDownloadJobs();
        if (jobs.any(
          (MangaDownloadJobRow job) =>
              job.bookKey == localBookKey && job.chapterKey == '/remote/ch1',
        )) {
          break;
        }
      }
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      await db.getEpubBook(localBookKey),
      isNotNull,
      reason: '远端章节漫画必须先经收养链加入本机 Library',
    );
    final List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(
      jobs
          .where((MangaDownloadJobRow job) => job.bookKey == localBookKey)
          .map((MangaDownloadJobRow job) => job.chapterKey)
          .toSet(),
      <String>{'/remote/ch1', '/remote/ch2'},
      reason: '收养后按「下载全部」规则入队非锁定章节',
    );
    expect(
      find.textContaining(t.manga_series_download_all_queued(count: 2)),
      findsOneWidget,
      reason: '批量下载要提示入队章数',
    );
    expect(
      find.textContaining(t.manga_series_download_all_locked_skipped(count: 1)),
      findsOneWidget,
      reason: '锁定章按既有规则跳过并提示',
    );
  });

  testWidgets('远端无章节整本包：批量下载仍走整本文件下载', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[_remoteWholeBook],
    );
    await pumpPage(tester, remoteClient: client);
    expect(remoteCard('Remote Whole Book'), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard('Remote Whole Book'));
    await tester.pumpAndSettle();
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isTrue,
      reason: '可下载的远端整本包同样启用批量下载',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
      );
      await tester.pump();
      for (int i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.text(t.remote_book_downloaded).evaluate().isNotEmpty) break;
      }
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      client.fetchedTitles,
      contains('peer-whole-1'),
      reason: '远端整本包走既有整本文件下载链（按 downloadId 拉取），而不是章节收养',
    );
    expect(
      await db.getEpubBook(
        InterconnectMangaCatalog.localBookKeyFor('peer-whole-1'),
      ),
      isNull,
      reason: '整本包下载不创建在线漫画条目',
    );
    expect(
      await db.listMangaDownloadJobs(),
      isEmpty,
      reason: '整本包不产生章节下载任务',
    );
  });

  testWidgets('只选中远端纯 SRT 有声书：批量下载禁用且不发起下载', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[],
      audiobooks: const <RemoteAudiobookInfo>[_remoteSrtAudiobook],
    );
    await pumpPage(tester, remoteClient: client, mangaOnly: false);
    expect(remoteSrtCard('Remote SRT'), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteSrtCard('Remote SRT'));
    await tester.pumpAndSettle();

    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isFalse,
      reason: '远端纯 SRT 有声书不是漫画，批量下载按钮必须禁用',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
    );
    await tester.pumpAndSettle();
    expect(
      client.fetchedAudiobookIds,
      isEmpty,
      reason: '非漫画远端条目不得经批量下载执行',
    );
  });

  testWidgets('只选中非漫画远端书：批量下载禁用且不下载', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[_remoteEpubBook],
    );
    await pumpPage(tester, remoteClient: client, mangaOnly: false);
    expect(remoteCard('Remote Epub'), findsOneWidget);

    await enterSelectionMode(tester);
    await tester.tap(remoteCard('Remote Epub'));
    await tester.pumpAndSettle();

    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isFalse,
      reason: '非漫画远端书（EPUB）不得启用批量下载',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
    );
    await tester.pumpAndSettle();
    expect(
      client.fetchedTitles,
      isEmpty,
      reason: '非漫画远端书不得经批量下载执行',
    );
  });

  testWidgets('混选漫画与非漫画远端条目：只下载漫画目标，其余计入跳过提示', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[_remoteWholeBook, _remoteEpubBook],
      audiobooks: const <RemoteAudiobookInfo>[_remoteSrtAudiobook],
    );
    await pumpPage(tester, remoteClient: client, mangaOnly: false);
    expect(remoteCard('Remote Whole Book'), findsOneWidget);
    expect(remoteCard('Remote Epub'), findsOneWidget);
    expect(remoteSrtCard('Remote SRT'), findsOneWidget);

    await enterSelectionMode(tester);
    for (final Finder card in <Finder>[
      remoteCard('Remote Whole Book'),
      remoteCard('Remote Epub'),
      remoteSrtCard('Remote SRT'),
    ]) {
      await tester.tap(card);
      await tester.pumpAndSettle();
    }
    expect(find.text(t.batch_selected_count(n: 3)), findsOneWidget);
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_download'),
      isTrue,
      reason: '混选里有可下载的漫画整本包，批量下载必须启用',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('reader_shelf_batch_download')),
      );
      await tester.pump();
      for (int i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find
            .textContaining(
              t.batch_download_remote_non_manga_skipped(count: 2),
            )
            .evaluate()
            .isNotEmpty) {
          break;
        }
      }
    });
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      client.fetchedTitles,
      contains('peer-whole-1'),
      reason: '混选里的远端漫画整本包仍要下载',
    );
    expect(
      client.fetchedTitles,
      isNot(contains('peer-epub-1')),
      reason: '非漫画远端书不得下载',
    );
    expect(
      client.fetchedAudiobookIds,
      isEmpty,
      reason: '纯 SRT 有声书不得下载',
    );
    expect(
      find.textContaining(t.batch_download_remote_non_manga_skipped(count: 2)),
      findsOneWidget,
      reason: '混选里被跳过的两个非漫画远端条目要计入提示',
    );
  });

  testWidgets('单卡下载远端章节漫画使用同一套入队与跳过规则', (
    WidgetTester tester,
  ) async {
    final _FakeInterconnectClient client = _FakeInterconnectClient(
      const <RemoteBookInfo>[_remoteChapteredBook],
    );
    useRemoteLibrary();
    await pumpPage(tester, remoteClient: client);
    expect(remoteCard('Remote Chaptered'), findsOneWidget);

    final String localBookKey = InterconnectMangaCatalog.localBookKeyFor(
      'peer-chaptered-1',
    );
    await tester.runAsync(() async {
      await tester.tap(remoteCard('Remote Chaptered'));
      await tester.pump();
      for (int i = 0; i < 300; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        final List<MangaDownloadJobRow> jobs =
            await db.listMangaDownloadJobs();
        if (jobs.any(
          (MangaDownloadJobRow job) =>
              job.bookKey == localBookKey && job.chapterKey == '/remote/ch1',
        )) {
          break;
        }
      }
    });
    await tester.pump(const Duration(milliseconds: 250));

    final List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(
      jobs
          .where((MangaDownloadJobRow job) => job.bookKey == localBookKey)
          .map((MangaDownloadJobRow job) => job.chapterKey)
          .toSet(),
      <String>{'/remote/ch1', '/remote/ch2'},
      reason: '单卡点远端章节漫画同样收养后入队全部可下载章',
    );
    expect(
      find.textContaining(t.manga_series_download_all_locked_skipped(count: 1)),
      findsOneWidget,
      reason: '单卡下载也提示锁定章跳过',
    );
  });
}
