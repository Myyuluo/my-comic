import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_removal_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 07：详情页的已下载状态不再要求 Library 行。
///
/// 页面级 seam（真实 DB + 可控 Source/下载服务 + 真实下载目录）：源页/书架页
/// 都从 entry 身份算已下载；无行时扫描 `downloads` 与带 manifest 的 `local`；
/// 无 manifest 的 `local` 目录不按标题猜测。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
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
    this.paths,
    this.libraryThrows = false,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService? library;
  final AppPaths? paths;
  final bool libraryThrows;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => paths ?? super.appPaths;

  @override
  AppPaths? get appPathsOrNull => paths;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) {
    if (libraryThrows) {
      throw StateError('the library service is unavailable in this test');
    }
    return library!;
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

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
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

const OnlineMangaLibraryEntry _entry = OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
);

MangaPagesManifest _manifest(String chapterKey, String chapterName) =>
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
      downloadedAt: DateTime.utc(2026, 11, 8),
    );

/// 写一章完整下载（页图 + pages.json）；不写 DB 映射。
Future<void> _writeManifestChapter(
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
    _manifest(chapterKey, chapterName),
  );
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 120; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// 真实异步（DB / 磁盘扫描）落地；fake 时钟推不动它们。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

Finder _filterChip() =>
    find.byKey(const ValueKey<String>('manga_chapter_download_filter'));

Finder _downloadedStatus() =>
    find.byKey(const ValueKey<String>('manga_chapter_download_downloaded'));

Future<void> _pickDownloadedFilter(WidgetTester tester) async {
  await tester.tap(_filterChip());
  await tester.pump();
}

void main() {
  late Directory root;
  late AppPaths paths;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;
  late _FakeAdapter adapter;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = Directory.systemTemp.createTempSync('manga_series_downloaded_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    paths = await AppPaths.resolve();
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
      downloadsRootDirectory: paths.downloadsRoot,
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('非书架作品在源页显示已下载章节', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_entry);
      expect(row.isInLibrary, isFalse);
      // 下载目录里有完整章与 manifest，但没有写 manga_chapter_dirs 映射。
      await _writeManifestChapter(
        row.extractDir,
        'Ch 1',
        '/chapter/1',
        'Chapter 1',
      );
    });
    final _TestAppModel appModel = _TestAppModel(
      db,
      root,
      library: library,
      paths: paths,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(
          appModel,
          SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _entry,
            service: library,
            sourceLabel: 'Fake',
          ),
        ),
      );
      await _pumpUntil(tester, _downloadedStatus());
    });

    expect(_downloadedStatus(), findsOneWidget);
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
    await tester.runAsync(() async {
      expect((await db.getEpubBook(row.bookKey))!.isInLibrary, isFalse);
    });
  });

  testWidgets('完全没有 Library 行时，源页仍按 manifest 身份显示已下载', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await _writeManifestChapter(
        p.join(paths.downloadsRoot.path, 'Some Source', 'Not in library'),
        'Ch 1',
        '/chapter/1',
        'Chapter 1',
      );
    });
    final _TestAppModel appModel = _TestAppModel(
      db,
      root,
      paths: paths,
      libraryThrows: true,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(
          appModel,
          SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _entry,
            sourceLabel: 'Fake',
          ),
        ),
      );
      await _pumpUntil(tester, _downloadedStatus());
    });

    await tester.runAsync(() async {
      expect(
        await db.getEpubBook(OnlineMangaLibraryService.bookKeyOf(_entry)),
        isNull,
        reason: '本用例刻意没有 Library 行',
      );
    });
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
  });

  testWidgets('重新加入书架的作品显示移出前已下载的章节', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late EpubBookRow row;
    late _TestAppModel appModel;
    await tester.runAsync(() async {
      row = await library.add(_entry);
      await _writeManifestChapter(
        row.extractDir,
        'Ch 1',
        '/chapter/1',
        'Chapter 1',
      );
      await db.upsertMangaChapterDir(
        bookKey: row.bookKey,
        chapterKey: '/chapter/1',
        folderName: 'Ch 1',
        updatedAt: 1,
      );
      appModel = _TestAppModel(db, root, library: library, paths: paths);
      await removeMangaFromLibrary(
        db: db,
        bookKey: row.bookKey,
        downloadService: appModel.mangaDownloadService,
      );
      expect((await db.getEpubBook(row.bookKey))!.isInLibrary, isFalse);
      await library.add(_entry);
      expect((await db.getEpubBook(row.bookKey))!.isInLibrary, isTrue);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(appModel, ShelfMangaSeriesTarget(row.bookKey)),
      );
      await _pumpUntil(tester, _downloadedStatus());
    });

    expect(_downloadedStatus(), findsOneWidget);
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
  });

  testWidgets('local 中带 manifest 的文件夹关联到在线作品', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.ensureNonLibrary(_entry);
      // 目录名与作品标题不同；只有 pages.json 能证明身份。
      await _writeManifestChapter(
        p.join(paths.localComicRoot.path, '完全不同的本地目录'),
        'Local Ch 1',
        '/chapter/1',
        'Chapter 1',
      );
    });
    final _TestAppModel appModel = _TestAppModel(
      db,
      root,
      library: library,
      paths: paths,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(
          appModel,
          SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _entry,
            service: library,
            sourceLabel: 'Fake',
          ),
        ),
      );
      await _pumpUntil(tester, _downloadedStatus());
    });

    expect(_downloadedStatus(), findsOneWidget);
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
  });

  testWidgets('重建下载索引完成后已打开的详情页刷新已下载状态', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.add(_entry);
    });
    final _TestAppModel appModel = _TestAppModel(
      db,
      root,
      library: library,
      paths: paths,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(
          appModel,
          SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _entry,
            service: library,
            sourceLabel: 'Fake',
          ),
        ),
      );
    });
    await _settle(tester);
    expect(_downloadedStatus(), findsNothing, reason: '页面打开时还没有下载文件');

    await tester.runAsync(() async {
      // 页面保持打开：用户把带 manifest 的文件复制进 local，然后运行重建。
      await _writeManifestChapter(
        p.join(paths.localComicRoot.path, '页面打开后放入的目录'),
        'Local Ch 1',
        '/chapter/1',
        'Chapter 1',
      );
      await RebuildDownloadIndexService(
        database: db,
        downloadsRoot: paths.downloadsRoot,
        localComicRoot: paths.localComicRoot,
      ).run();
      for (int i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
        if (_downloadedStatus().evaluate().isNotEmpty) return;
      }
    });

    expect(_downloadedStatus(), findsOneWidget);
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Chapter 2'), findsNothing);
  });

  testWidgets('local 中无 manifest 的文件夹不按标题关联', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await library.ensureNonLibrary(_entry);
      // 目录名 == 作品标题，也有可读页图，但没有 pages.json 身份。
      final Directory chapterDir = Directory(
        p.join(paths.localComicRoot.path, 'Fixture series', 'Ch 1'),
      )..createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);
    });
    final _TestAppModel appModel = _TestAppModel(
      db,
      root,
      library: library,
      paths: paths,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _harness(
          appModel,
          SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _entry,
            service: library,
            sourceLabel: 'Fake',
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Chapter 1'));
    });
    await _settle(tester);

    expect(_downloadedStatus(), findsNothing, reason: '无 manifest 不得按标题猜测');
    await _pickDownloadedFilter(tester);
    expect(find.text('Chapter 1'), findsNothing);
    expect(find.text('Chapter 2'), findsNothing);
    expect(find.text(t.manga_series_no_chapters_match_filter), findsOneWidget);
  });
}
