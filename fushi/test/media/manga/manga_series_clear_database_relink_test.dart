import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 05 的页面级证据：清库 → 从来源页重开 → 章节显示已下载 → 多选批量
/// 删除直接可用；批量删除不依赖 Manga 行或数据库映射，按 `pages.json` 身份
/// 回退删除 `downloads` 容器，`local` 原件不动。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  /// 来源详情页拉回的章节表；清库重开时 seed 通常没有章节。
  List<OnlineMangaChapter> fetchedChapters = const <OnlineMangaChapter>[];

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async => OnlineMangaRefreshResult(
    series: entry.series,
    chapters: fetchedChapters.isEmpty ? entry.chapters : fetchedChapters,
  );

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw StateError('the series page must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the series page must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _TestAppModel extends AppModel {
  _TestAppModel(
    this._db,
    Directory root, {
    this.library,
    this.libraryThrows = false,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService? library;
  final bool libraryThrows;

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) {
    final OnlineMangaLibraryService? service = library;
    if (libraryThrows || service == null) {
      throw StateError('the series page cannot reach the shelf in this test');
    }
    return service;
  }

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
  }) async {}
}

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

OnlineMangaLibraryEntry _entryWith(List<OnlineMangaChapter> chapters) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: chapters,
    );

const ValueKey<String> _deleteDownloadsKey = ValueKey<String>(
  'manga_series_batch_delete_downloads',
);

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

MediaDetailItemRow _rowWidget(WidgetTester tester, String title) =>
    tester.widget<MediaDetailItemRow>(_chapterRow(title));

bool _enabled(WidgetTester tester, ValueKey<String> key) =>
    tester.widget<FushiIconButton>(find.byKey(key)).enabled;

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 交替让真实事件循环跑一步（runAsync）与推帧：FakeAsync 区里 await 文件 IO
/// 永远不会自己结束，而 IO 的续体又排回 fake zone，两者只能一轮一轮推进。
Future<void> _advanceUntil(WidgetTester tester, bool Function() done) async {
  for (int i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (!done()) continue;
    for (int j = 0; j < 10; j++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await _settle(tester);
    return;
  }
  fail('等待删除完成超时');
}

Future<void> _writeDownloadedChapter(
  String mangaDir,
  String containerName,
  String chapterKey,
  String chapterName,
) async {
  final Directory chapterDir = downloadChapterDirectory(
    mangaDir,
    containerName,
  );
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
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
      chapterName: chapterName,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 10),
    ),
  );
}

Widget _harness(
  AppModel appModel, {
  required _FakeAdapter adapter,
  required OnlineMangaLibraryEntry seed,
  required OnlineMangaLibraryService? service,
}) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: MangaSeriesPage(
        target: SourceMangaSeriesTarget(
          adapter: adapter,
          seed: seed,
          service: service,
          sourceLabel: 'Fake',
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late String downloadsDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_clear_relink_page_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
    downloadsDir = p.join(root.path, 'downloads', 'Fake', 'Fixture series');
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    AppModel appModel,
    OnlineMangaLibraryEntry seed, {
    OnlineMangaLibraryService? service,
  }) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(appModel, adapter: adapter, seed: seed, service: service),
    );
    await pumpUntilFound(tester, find.text('Chapter 1'));
  }

  testWidgets('清库后从来源页重开：自动重链、显示已下载、批量删除直接可用', (WidgetTester tester) async {
    final _TestAppModel appModel = _TestAppModel(db, root, library: library);
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_entryWith(_chapters));
      await _writeDownloadedChapter(
        row.extractDir,
        'Chapter 1',
        '/chapter/1',
        'Chapter 1',
      );
      await _writeDownloadedChapter(
        row.extractDir,
        'Chapter 2',
        '/chapter/2',
        'Chapter 2',
      );
      for (final OnlineMangaChapter chapter in _chapters) {
        await db.upsertMangaChapterDir(
          bookKey: row.bookKey,
          chapterKey: chapter.key,
          folderName: chapter.name,
          updatedAt: 1,
        );
      }
      final MangaDatabaseClearService clear = MangaDatabaseClearService(
        database: db,
      );
      final List<MangaDatabaseClearSource> sources = await clear
          .measureSources();
      await clear.run(
        sourceKeys: <String>{sources.single.key},
        keepRead: false,
      );
      expect(await db.getEpubBook(row.bookKey), isNull, reason: '清库只删记录');
      expect(Directory(row.extractDir).existsSync(), isTrue, reason: '磁盘文件保留');
    });

    // 源网格 seed 只有标题没有章节；页面重新入库并从来源拉回章节。
    adapter.fetchedChapters = _chapters;
    final OnlineMangaLibraryEntry seed = _entryWith(
      const <OnlineMangaChapter>[],
    );
    await tester.runAsync(() async {
      await pumpPage(tester, appModel, seed);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
    });

    // 重开后自动重链：extractDir 与章节映射都恢复，无需手动重建索引。
    late EpubBookRow reopened;
    await tester.runAsync(() async {
      reopened = (await db.getAllEpubBooks()).single;
      expect(reopened.isInLibrary, isFalse);
      expect(reopened.extractDir, row.extractDir);
      expect(
        (await db.getMangaChapterDir(
          reopened.bookKey,
          '/chapter/1',
        ))?.folderName,
        'Chapter 1',
      );
      expect(
        (await db.getMangaChapterDir(
          reopened.bookKey,
          '/chapter/2',
        ))?.folderName,
        'Chapter 2',
      );
      // 保留一份章级阅读状态，验证删文件不等于清空阅读记录。
      await db.saveMangaChapterState(
        bookUid: reopened.uid,
        chapterKey: '/chapter/1',
        lastPage: 5,
        pageCount: 10,
        readAt: 1,
      );
    });
    expect(
      _rowWidget(tester, 'Chapter 1').downloadState,
      MediaDetailDownloadState.downloaded,
    );
    expect(
      _rowWidget(tester, 'Chapter 2').downloadState,
      MediaDetailDownloadState.downloaded,
    );

    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(BatchActionBar),
        matching: find.text(t.batch_select_all),
      ),
    );
    await _settle(tester);
    expect(_enabled(tester, _deleteDownloadsKey), isTrue);
    await tester.tap(find.byKey(_deleteDownloadsKey));
    await _settle(tester);
    expect(
      find.text(t.manga_series_delete_downloads_confirm(count: 2)),
      findsOneWidget,
    );
    await tester.tap(find.text(t.dialog_delete));
    await _advanceUntil(
      tester,
      () =>
          !downloadChapterDirectory(row.extractDir, 'Chapter 1').existsSync() &&
          !downloadChapterDirectory(row.extractDir, 'Chapter 2').existsSync() &&
          !Directory(row.extractDir).existsSync() &&
          !Directory(p.dirname(row.extractDir)).existsSync(),
    );

    expect(
      downloadChapterDirectory(row.extractDir, 'Chapter 1').existsSync(),
      isFalse,
    );
    expect(
      downloadChapterDirectory(row.extractDir, 'Chapter 2').existsSync(),
      isFalse,
    );
    expect(
      Directory(row.extractDir).existsSync(),
      isFalse,
      reason: '删完最后一章后清理空的 manga 目录',
    );
    expect(
      Directory(p.dirname(row.extractDir)).existsSync(),
      isFalse,
      reason: 'source 目录空了也清理',
    );
    expect(
      _rowWidget(tester, 'Chapter 1').downloadState,
      MediaDetailDownloadState.none,
    );
    MangaChapterStateRow? read;
    await tester.runAsync(() async {
      read = await db.getMangaChapterState(
        bookUid: reopened.uid,
        chapterKey: '/chapter/1',
      );
    });
    final MangaChapterStateRow kept = read!;
    expect(kept.readAt, 1);
    expect(kept.lastPage, 5);
  });

  testWidgets('没有 Manga 行 / 映射时批量删除按身份回退，不要求书架归属', (WidgetTester tester) async {
    // 清库后只剩磁盘 pages.json；页面拿不到书架半边（没有 Manga 行）。
    await tester.runAsync(
      () => _writeDownloadedChapter(
        downloadsDir,
        'Chapter 1',
        '/chapter/1',
        'Chapter 1',
      ),
    );
    final _TestAppModel appModel = _TestAppModel(db, root, libraryThrows: true);
    await tester.runAsync(() async {
      await pumpPage(tester, appModel, _entryWith(_chapters), service: null);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      expect(await db.getAllEpubBooks(), isEmpty, reason: '本用例刻意没有行');
    });

    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    expect(
      _enabled(tester, _deleteDownloadsKey),
      isTrue,
      reason: '已下载状态来自磁盘身份扫描，不要求 Manga 行',
    );
    await tester.tap(find.byKey(_deleteDownloadsKey));
    await _settle(tester);
    await tester.tap(find.text(t.dialog_delete));
    await _advanceUntil(
      tester,
      () => !downloadChapterDirectory(downloadsDir, 'Chapter 1').existsSync(),
    );

    expect(
      downloadChapterDirectory(downloadsDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '身份回退删除 downloads 里的容器',
    );
    final List<EpubBookRow> books = (await tester.runAsync(
      db.getAllEpubBooks,
    ))!;
    expect(books, isEmpty, reason: '全程不需要 Manga 行');
  });
}
