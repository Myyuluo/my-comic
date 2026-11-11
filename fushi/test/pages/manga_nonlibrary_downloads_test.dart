import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_add_to_shelf_prompt.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

/// 非书架在线作品的下载（manga-library-membership 票 08）页面级 seam：
/// 真 [MangaSeriesPage] + 真 37 表内存 DB + 可控 Source/下载服务 + 真实临时
/// `downloads` 根。断言只落在用户可见行为与数据结果上：没有 Library 行也能从
/// 源页下载单章 / 全部、任务落到真实（非书架）行、详情页立即显示已下载、删除
/// 下载释放文件与映射、下载完成给可选「加入书架？」提示。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
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
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async => <OnlineMangaPageRef>[
    for (int index = 0; index < 2; index++)
      HttpMangaPageRef(
        index: index,
        url: 'https://example.invalid${chapter.key}/$index.png',
        referer: 'https://example.invalid',
      ),
  ];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async => png;

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _TestAppModel extends AppModel {
  _TestAppModel(
    this._db,
    this._library,
    this._downloads,
    Directory root, {
    this.paths,
    this.libraryThrows = false,
  }) : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final MangaDownloadService _downloads;
  final AppPaths? paths;
  final bool libraryThrows;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => paths ?? super.appPaths;

  @override
  AppPaths? get appPathsOrNull => paths;

  @override
  MangaDownloadService get mangaDownloadService => _downloads;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) {
    if (libraryThrows) {
      throw StateError('the series page cannot reach the shelf in this test');
    }
    return _library;
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

Widget _harness(AppModel appModel, Widget home) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      // 下载完成提示由全局宿主负责（票 15 finding 4）。
      home: MangaAddToShelfPromptHost(child: home),
    ),
  ),
);

Widget _downloadsHarness(MangaDownloadService downloads) => ProviderScope(
  child: TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: DownloadsPage(downloadsOverride: downloads)),
    ),
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

const OnlineMangaLibraryEntry _seed = OnlineMangaLibraryEntry(
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

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

Finder _taskCard(String chapterTitle) => find.ancestor(
  of: find.text(chapterTitle),
  matching: find.byType(DownloadTaskCard),
);

Future<void> _openChapterMenu(WidgetTester tester, String title) async {
  await tester.tap(
    find.descendant(
      of: _chapterRow(title),
      matching: find.byType(FushiOverflowMenu<String>),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapMenuItem(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  for (int i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

/// 写一章完整下载（页图 + pages.json）；不写 DB 映射 / 行。
Future<void> _writeManifestChapter(
  Directory mangaDir,
  String containerName,
  String chapterKey,
  String chapterName,
) async {
  final Directory chapterDir = downloadChapterDirectory(
    mangaDir.path,
    containerName,
  );
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.png')).writeAsBytes(_FakeAdapter.png);
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
      payload: MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.png',
            size: MokuroSize(60, 90),
            blocks: const <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 10),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late AppPaths paths;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late MangaDownloadService downloads;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = Directory.systemTemp.createTempSync('manga_nonlibrary_downloads_');
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
    downloads = MangaDownloadService(
      database: db,
      serviceFor: (OnlineMangaRuntimeKind runtime) => library,
      saveAsCbz: () => false,
    );
    await downloads.start();
  });

  tearDown(() async {
    downloads.dispose();
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSourcePage(
    WidgetTester tester,
    AppModel appModel, {
    Key? pageKey,
  }) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        appModel,
        MangaSeriesPage(
          key: pageKey,
          target: SourceMangaSeriesTarget(
            adapter: adapter,
            seed: _seed,
            // 页面拿不到书架半边：本用例刻意覆盖「没有 Library 行」的源页。
            sourceLabel: 'Fake',
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Chapter 1'));
  }

  testWidgets('无 Library 行也能从源页下载单章：补非书架行、立即显示已下载并提示加入书架', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(
      db,
      library,
      downloads,
      root,
      paths: paths,
      libraryThrows: true,
    );

    await tester.runAsync(() async {
      await pumpSourcePage(tester, appModel);
      expect(await db.getAllEpubBooks(), isEmpty, reason: '页面还没有 Library 行');

      await _openChapterMenu(tester, 'Chapter 1');
      await _tapMenuItem(tester, t.manga_chapter_download_action);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_add_to_shelf_after_download'),
        ),
      );
    });

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.isInLibrary, isFalse, reason: '下载不等于加入书架');
    expect(
      await db.getMangaChapterDir(row.bookKey, '/chapter/1'),
      isNotNull,
      reason: '下载映射必须落在真实的非书架行上',
    );
    expect(
      Directory(row.extractDir).existsSync(),
      isTrue,
      reason: '下载目录由非书架行解析',
    );
    expect(
      find.text(
        t.manga_series_add_to_shelf_after_download(title: 'Fixture series'),
      ),
      findsOneWidget,
      reason: '下载完成后给出可选「加入书架？」提示',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsOneWidget,
      reason: '下载完成后详情页状态立即更新',
    );
    expect((await db.getEpubBook(row.bookKey))!.inLibrary, isFalse);
  });

  testWidgets('没有 Library 行时按下载身份删除已下载章节：释放文件并立即刷新状态', (
    WidgetTester tester,
  ) async {
    final Directory mangaDir = Directory(
      p.join(paths.downloadsRoot.path, 'Fake', 'Fixture series'),
    );
    await tester.runAsync(
      () => _writeManifestChapter(
        mangaDir,
        'Chapter 1',
        '/chapter/1',
        'Chapter 1',
      ),
    );
    final _TestAppModel appModel = _TestAppModel(
      db,
      library,
      downloads,
      root,
      paths: paths,
      libraryThrows: true,
    );

    await tester.runAsync(() async {
      await pumpSourcePage(tester, appModel);
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      expect(await db.getAllEpubBooks(), isEmpty, reason: '本用例刻意没有行');

      await _openChapterMenu(tester, 'Chapter 1');
      await pumpUntilFound(
        tester,
        find.text(t.manga_chapter_download_delete_action),
      );
      await _tapMenuItem(tester, t.manga_chapter_download_delete_action);
      await pumpUntilFound(tester, find.text(t.dialog_delete));
      await tester.tap(find.text(t.dialog_delete));
      // 删除会触发一次磁盘重扫；固定真实等待，避免失败路径卡在 runAsync 里。
      for (int i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pump();

    expect(
      downloadChapterDirectory(mangaDir.path, 'Chapter 1').existsSync(),
      isFalse,
      reason: '删除下载必须释放按身份匹配到的章节目录',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsNothing,
      reason: '删除后详情页状态立即更新',
    );
    expect(
      find.byKey(
        const ValueKey<String>('manga_chapter_download_notDownloaded'),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('非书架作品可下载全部章节，任务挂在非书架行上', (WidgetTester tester) async {
    final _TestAppModel appModel = _TestAppModel(
      db,
      library,
      downloads,
      root,
      paths: paths,
    );

    late EpubBookRow row;
    await tester.runAsync(() async {
      await pumpSourcePage(tester, appModel);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );
      // 两章都完成：两个章节行都切到已下载。
      for (int i = 0; i < 60; i++) {
        if (find
                .byKey(
                  const ValueKey<String>('manga_chapter_download_downloaded'),
                )
                .evaluate()
                .length ==
            2) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
      row = (await db.getAllEpubBooks()).single;
    });

    expect(row.isInLibrary, isFalse);
    final List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(jobs, hasLength(2));
    expect(
      jobs.every((MangaDownloadJobRow job) => job.bookKey == row.bookKey),
      isTrue,
      reason: '任务必须挂在真实的非书架行上',
    );
    expect(
      jobs.every(
        (MangaDownloadJobRow job) => job.status == MangaDownloadJobStatus.done,
      ),
      isTrue,
    );
    for (final OnlineMangaChapter chapter in _chapters) {
      expect(await db.getMangaChapterDir(row.bookKey, chapter.key), isNotNull);
    }
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      findsNWidgets(2),
      reason: '下载全部完成后详情页状态立即更新',
    );
  });

  testWidgets('非书架作品的任务出现在下载页，可暂停 / 恢复 / 取消 / 重试', (WidgetTester tester) async {
    final MangaDownloadService idle = MangaDownloadService(
      database: db,
      serviceFor: (OnlineMangaRuntimeKind runtime) => library,
      saveAsCbz: () => false,
    );
    addTearDown(idle.dispose);

    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_seed);
      await idle.enqueueChapter(
        entry: _seed,
        chapter: _chapters[1],
        autoOcr: false,
      );
      await idle.enqueueChapter(
        entry: _seed,
        chapter: _chapters[0],
        autoOcr: false,
      );
    });
    final List<MangaDownloadJobRow> queued = await db.listMangaDownloadJobs();
    expect(queued, hasLength(2));
    final MangaDownloadJobRow failed = queued.firstWhere(
      (MangaDownloadJobRow job) => job.chapterKey == '/chapter/2',
    );
    await db.updateMangaDownloadJobStatus(
      failed.jobId,
      status: MangaDownloadJobStatus.failed,
      updatedAt: 2,
      lastError: 'boom',
      attemptCount: 3,
    );

    await tester.pumpWidget(_downloadsHarness(idle));
    await tester.pumpAndSettle();

    expect(find.byType(DownloadTaskCard), findsNWidgets(2));
    expect(
      find.descendant(
        of: _taskCard('Chapter 2'),
        matching: find.byTooltip(t.download_resume),
      ),
      findsOneWidget,
      reason: '失败的非书架任务可重试',
    );
    expect(
      find.descendant(
        of: _taskCard('Chapter 2'),
        matching: find.byTooltip(t.dialog_cancel),
      ),
      findsOneWidget,
      reason: '失败的非书架任务可取消',
    );
    expect(
      find.descendant(
        of: _taskCard('Chapter 1'),
        matching: find.byTooltip(t.dialog_cancel),
      ),
      findsOneWidget,
      reason: '排队中的非书架任务可取消',
    );

    // 重试失败任务：同一行回到排队。
    await tester.tap(
      find.descendant(
        of: _taskCard('Chapter 2'),
        matching: find.byTooltip(t.download_resume),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await db.getMangaDownloadJob(failed.jobId))!.status,
      MangaDownloadJobStatus.queued,
    );

    // 全局暂停 / 恢复。
    await tester.tap(
      find.byKey(const ValueKey<String>('downloads-global-toggle-fab')),
    );
    await tester.pumpAndSettle();
    expect(
      (await db.listMangaDownloadJobs()).every(
        (MangaDownloadJobRow job) =>
            job.status == MangaDownloadJobStatus.paused,
      ),
      isTrue,
      reason: '暂停作用于非书架任务',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('downloads-global-toggle-fab')),
    );
    await tester.pumpAndSettle();
    expect(
      (await db.listMangaDownloadJobs()).every(
        (MangaDownloadJobRow job) =>
            job.status == MangaDownloadJobStatus.queued,
      ),
      isTrue,
      reason: '恢复作用于非书架任务',
    );

    // 取消一条排队任务：行从列表与数据库中消失。
    final MangaDownloadJobRow toCancel = (await db.listMangaDownloadJobs())
        .firstWhere(
          (MangaDownloadJobRow job) => job.chapterKey == '/chapter/1',
        );
    await tester.tap(
      find.descendant(
        of: _taskCard('Chapter 1'),
        matching: find.byTooltip(t.dialog_cancel),
      ),
    );
    await tester.pumpAndSettle();
    expect(await db.getMangaDownloadJob(toCancel.jobId), isNull);
    expect(find.byType(DownloadTaskCard), findsOneWidget);
    expect(row.isInLibrary, isFalse);
  });
}
