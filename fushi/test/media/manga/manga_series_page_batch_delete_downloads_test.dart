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
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 07（manga-ux-batch）的页面级证据：批量删除已完成的在线下载。
///
/// 真实 37 表内存库 + 真实偏好库 + 真实作品页与真实 Download library 目录；
/// 在线 Source 用可控 fake。只断言用户可见行为（批量栏动作、确认框、章节行
/// 下载状态）与磁盘 / 数据库真实结果。

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
  _TestAppModel(this._db, Directory root, {this.library, this.paths})
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService? library;
  final AppPaths? paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => paths ?? super.appPaths;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => library!;

  /// 开阅读器的副作用与本测试无关。
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

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
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

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/5',
    name: 'Chapter 5',
    number: 5,
    raw: <String, Object?>{'url': '/chapter/5'},
  ),
  OnlineMangaChapter(
    key: '/chapter/4',
    name: 'Chapter 4',
    number: 4,
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

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
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

/// 同一 Source 下标题相同的另一部作品（ticket 03：共享同一个下载目录）。
OnlineMangaLibraryEntry _otherEntry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/other',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/other'},
  ),
  chapters: <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: '/other/1',
      name: 'Other Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/other/1'},
    ),
  ],
);

/// 在 Download library 里放一章完整下载（章目录 + pages.json + 页图 + 映射行）。
Future<void> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
  String chapterKey,
  String chapterName, {
  String mangaKey = '/series/fixture',
  String mangaTitle = 'Fixture series',
}) async {
  final Directory chapterDir = downloadChapterDirectory(bookDir, chapterName);
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await writePagesManifestAtomically(
    chapterDir,
    MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: mangaKey,
      mangaTitle: mangaTitle,
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
    ),
  );
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapterKey,
    folderName: chapterName,
    updatedAt: 1,
  );
}

Future<void> _insertJob(
  FushiDatabase db, {
  required String bookKey,
  required String chapterKey,
  required String status,
}) => db.upsertMangaDownloadJob(
  MangaDownloadJobsCompanion.insert(
    jobId: 'job-$chapterKey',
    kind: MangaDownloadJobKind.chapter,
    bookKey: bookKey,
    chapterKey: chapterKey,
    runtime: 'mihon',
    title: 'Fixture series',
    chapterTitle: chapterKey,
    status: Value<String>(status),
    pagesDone: const Value<int>(0),
    pagesTotal: const Value<int>(0),
    attemptCount: const Value<int>(0),
    autoOcr: const Value<bool>(false),
    createdAt: 1,
    updatedAt: 1,
  ),
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

/// 推进弹簧 / 进场 / 弹窗动画。只用假时钟 pump，手势必须在 `runAsync` 之外。
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
    // 收尾的数据库写入 / 下载状态刷新还需要几轮。
    for (int j = 0; j < 10; j++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await _settle(tester);
    return;
  }
  fail('等待批量删除完成超时');
}

void main() {
  group('在线源', () {
    late Directory root;
    late FushiDatabase db;
    late OnlineMangaLibraryService library;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      root = await Directory.systemTemp.createTemp('manga_batch_delete_');
      EpubStorage.debugBaseDirectoryOverride = root.path;
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
      library = OnlineMangaLibraryService(
        database: db,
        rootDirectory: Directory(p.join(root.path, 'legacy')),
        adapter: _FakeAdapter(),
      );
    });

    tearDown(() async {
      EpubStorage.debugBaseDirectoryOverride = null;
      await db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    void sizeView(WidgetTester tester) {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    /// 已完成 / 排队 / 暂停 / 文件缺失各一杯，外加一个未下载章。
    Future<EpubBookRow> seedMixedStates() async {
      final EpubBookRow row = await library.add(_entry());
      await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
        '/chapter/1',
        'Chapter 1',
      );
      await _insertJob(
        db,
        bookKey: row.bookKey,
        chapterKey: '/chapter/3',
        status: MangaDownloadJobStatus.queued,
      );
      await _insertJob(
        db,
        bookKey: row.bookKey,
        chapterKey: '/chapter/4',
        status: MangaDownloadJobStatus.paused,
      );
      await _insertJob(
        db,
        bookKey: row.bookKey,
        chapterKey: '/chapter/5',
        status: MangaDownloadJobStatus.done,
      );
      return row;
    }

    testWidgets('垃圾桶只对已完成的在线下载可用，取消确认不删除', (WidgetTester tester) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      await tester.runAsync(() async {
        row = await seedMixedStates();
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });

      // 选「排队中」的章：垃圾桶在，但置灰。
      await tester.longPress(_chapterRow('Chapter 3'));
      await _settle(tester);
      expect(find.byKey(_deleteDownloadsKey), findsOneWidget);
      expect(
        _enabled(tester, _deleteDownloadsKey),
        isFalse,
        reason: '排队中的章不参与批量删除',
      );

      // 加选一个已完成的下载：动作可用。
      await tester.tap(_chapterRow('Chapter 1'));
      await _settle(tester);
      expect(_enabled(tester, _deleteDownloadsKey), isTrue);

      // 混合选择（已完成 + 排队 + 暂停 + 文件缺失）：动作仍可用，确认框只报
      // 适用子集（1 章）。
      await tester.tap(_chapterRow('Chapter 4'));
      await tester.tap(_chapterRow('Chapter 5'));
      await _settle(tester);
      expect(_enabled(tester, _deleteDownloadsKey), isTrue);

      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      expect(find.text(t.manga_series_delete_downloads), findsOneWidget);
      expect(
        find.text(t.manga_series_delete_downloads_confirm(count: 1)),
        findsOneWidget,
        reason: '确认框只说适用子集的数量',
      );

      // 取消：文件与下载状态原样保留。
      await tester.tap(find.text(t.dialog_cancel));
      await _settle(tester);
      expect(
        downloadChapterDirectory(row.extractDir, 'Chapter 1').existsSync(),
        isTrue,
      );
      expect(
        _rowWidget(tester, 'Chapter 1').downloadState,
        MediaDetailDownloadState.downloaded,
      );
    });

    testWidgets('确认后只删已完成下载，章节回到未下载且保留已读与进度', (WidgetTester tester) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      await tester.runAsync(() async {
        row = await seedMixedStates();
        // 第二章也完整下载，并保留一个 done 任务行（删文件时必须一并清掉，
        // 否则会被误显示成 Missing）。
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/2',
          'Chapter 2',
        );
        await _insertJob(
          db,
          bookKey: row.bookKey,
          chapterKey: '/chapter/2',
          status: MangaDownloadJobStatus.done,
        );
        // 第一章已读、第二章读了一半：批量删除不得动章级阅读状态。
        await db.saveMangaChapterState(
          bookUid: row.uid,
          chapterKey: '/chapter/1',
          lastPage: 5,
          pageCount: 10,
          readAt: 1,
        );
        await db.saveMangaChapterState(
          bookUid: row.uid,
          chapterKey: '/chapter/2',
          lastPage: 2,
          pageCount: 10,
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });

      // 全选：5 章里只有 1、2 是已完成下载，垃圾桶可用。
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

      // 删除链里有真实文件 IO：FakeAsync 区里 await 文件 IO 不会自己结束，
      // 必须交替让真实事件循环跑一步（runAsync）再推帧 flush 掉落回 fake
      // zone 的续体。以两章磁盘容器都消失作为删除完成的信号。
      await _advanceUntil(tester, () {
        return !downloadChapterDirectory(
              row.extractDir,
              'Chapter 1',
            ).existsSync() &&
            !downloadChapterDirectory(
              row.extractDir,
              'Chapter 2',
            ).existsSync() &&
            _rowWidget(tester, 'Chapter 1').downloadState ==
                MediaDetailDownloadState.none &&
            _rowWidget(tester, 'Chapter 2').downloadState ==
                MediaDetailDownloadState.none;
      });

      // 磁盘：适用子集的两章被删，未选 / 不适用的章不动。
      expect(
        downloadChapterDirectory(row.extractDir, 'Chapter 1').existsSync(),
        isFalse,
      );
      expect(
        downloadChapterDirectory(row.extractDir, 'Chapter 2').existsSync(),
        isFalse,
      );
      expect(await db.getMangaDownloadJob('job-/chapter/2'), isNull);
      expect(await db.getMangaDownloadJob('job-/chapter/3'), isNotNull);
      expect(await db.getMangaDownloadJob('job-/chapter/4'), isNotNull);
      expect(await db.getMangaDownloadJob('job-/chapter/5'), isNotNull);

      // 章节行回到「未下载」；排队 / 暂停 / 缺失的章保持原状态。
      expect(
        _rowWidget(tester, 'Chapter 1').downloadState,
        MediaDetailDownloadState.none,
      );
      expect(
        _rowWidget(tester, 'Chapter 2').downloadState,
        MediaDetailDownloadState.none,
      );
      expect(
        _rowWidget(tester, 'Chapter 3').downloadState,
        MediaDetailDownloadState.queued,
      );
      expect(
        _rowWidget(tester, 'Chapter 4').downloadState,
        MediaDetailDownloadState.queued,
      );
      expect(
        _rowWidget(tester, 'Chapter 5').downloadState,
        MediaDetailDownloadState.missing,
      );

      // 已读标记与章内进度保留。
      final MangaChapterStateRow first = (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
      ))!;
      expect(first.readAt, 1);
      expect(first.lastPage, 5);
      expect(first.pageCount, 10);
      final MangaChapterStateRow second = (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/2',
      ))!;
      expect(second.readAt, isNull);
      expect(second.lastPage, 2);
      expect(second.pageCount, 10);

      // 没有适用项后垃圾桶置灰。
      expect(_enabled(tester, _deleteDownloadsKey), isFalse);
    });

    testWidgets('共享目录：批量删除只删本作品的章节，保留另一部作品的文件', (WidgetTester tester) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      late EpubBookRow otherRow;
      late Directory otherChapterDir;
      await tester.runAsync(() async {
        row = await library.add(_entry());
        otherRow = await library.add(_otherEntry());
        expect(
          p.equals(otherRow.extractDir, row.extractDir),
          isTrue,
          reason: '同一 Source 下同名作品共用下载目录',
        );
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/1',
          'Chapter 1',
        );
        otherChapterDir = downloadChapterDirectory(
          otherRow.extractDir,
          'Other Chapter 1',
        );
        await _writeDownloadedChapter(
          db,
          otherRow.bookKey,
          otherRow.extractDir,
          '/other/1',
          'Other Chapter 1',
          mangaKey: '/series/other',
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });

      await tester.longPress(_chapterRow('Chapter 1'));
      await _settle(tester);
      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      await tester.tap(find.text(t.dialog_delete));
      await _advanceUntil(tester, () {
        return !downloadChapterDirectory(
          row.extractDir,
          'Chapter 1',
        ).existsSync();
      });

      expect(
        downloadChapterDirectory(row.extractDir, 'Chapter 1').existsSync(),
        isFalse,
      );
      expect(otherChapterDir.existsSync(), isTrue, reason: '共享目录里另一部作品的容器必须保留');
      expect(
        File(p.join(otherChapterDir.path, '001.jpg')).existsSync(),
        isTrue,
      );
      expect(
        await db.getMangaChapterDir(otherRow.bookKey, '/other/1'),
        isNotNull,
        reason: '另一部作品的映射不得被删除',
      );
      expect(
        Directory(row.extractDir).existsSync(),
        isTrue,
        reason: '另一部作品还在使用共享目录',
      );
      expect(
        _rowWidget(tester, 'Chapter 1').downloadState,
        MediaDetailDownloadState.none,
      );
    });

    testWidgets('重建关联的无 manifest 文件夹显示已下载并可批量删除（来源未安装）', (
      WidgetTester tester,
    ) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      late Directory userChapter;
      await tester.runAsync(() async {
        row = await library.add(_entry());
        // 用户提供的普通文件夹：没有 pages.json；来源安装状态无关。
        userChapter = downloadChapterDirectory(row.extractDir, 'Chapter 1');
        await userChapter.create(recursive: true);
        await File(p.join(userChapter.path, '001.jpg')).writeAsBytes(<int>[1]);
        await RebuildDownloadIndexService(
          database: db,
          downloadsRoot: Directory(p.join(root.path, 'downloads')),
          localComicRoot: Directory(p.join(root.path, 'local')),
        ).run();
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });
      await _settle(tester);

      expect(
        _rowWidget(tester, 'Chapter 1').downloadState,
        MediaDetailDownloadState.downloaded,
        reason: '重建按容器名关联后，无 manifest 的可读容器视为已下载',
      );

      await tester.longPress(_chapterRow('Chapter 1'));
      await _settle(tester);
      expect(_enabled(tester, _deleteDownloadsKey), isTrue);
      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      await tester.tap(find.text(t.dialog_delete));
      await _advanceUntil(tester, () {
        return !userChapter.existsSync() &&
            !Directory(row.extractDir).existsSync() &&
            _rowWidget(tester, 'Chapter 1').downloadState ==
                MediaDetailDownloadState.none;
      });

      expect(userChapter.existsSync(), isFalse, reason: '删除 downloads 里的容器');
      expect(Directory(row.extractDir).existsSync(), isFalse);
      expect(await db.getEpubBook(row.bookKey), isNotNull, reason: '作品条目保留');
    });

    testWidgets('根 manifest 单章显示已下载；删除清空负载但保留条目与阅读进度', (
      WidgetTester tester,
    ) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      await tester.runAsync(() async {
        row = await library.add(
          OnlineMangaLibraryEntry(
            runtime: OnlineMangaRuntimeKind.mihon,
            extensionPackage: 'org.example.fixture',
            sourceId: '1',
            series: const OnlineMangaSeries(
              key: '/series/fixture',
              title: 'Fixture series',
              raw: <String, Object?>{'url': '/series/fixture'},
            ),
            chapters: const <OnlineMangaChapter>[
              OnlineMangaChapter(
                key: '/chapter/1',
                name: 'Chapter 1',
                number: 1,
                raw: <String, Object?>{'url': '/chapter/1'},
              ),
            ],
          ),
        );
        // 单章作品：pages.json + 页图直接住在漫画目录根。
        await Directory(row.extractDir).create(recursive: true);
        await File(p.join(row.extractDir, '001.jpg')).writeAsBytes(<int>[1]);
        await writePagesManifestAtomically(
          Directory(row.extractDir),
          MangaPagesManifest(
            sourceRuntime: 'mihon',
            sourceId: '1',
            sourceName: 'Fake',
            extensionPackage: 'org.example.fixture',
            mangaKey: '/series/fixture',
            mangaTitle: 'Fixture series',
            chapterKey: '/chapter/1',
            chapterName: 'Chapter 1',
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
        await db.saveMangaChapterState(
          bookUid: row.uid,
          chapterKey: '/chapter/1',
          lastPage: 5,
          pageCount: 10,
          readAt: 1,
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });
      await _settle(tester);

      expect(
        _rowWidget(tester, 'Chapter 1').downloadState,
        MediaDetailDownloadState.downloaded,
        reason: '根 pages.json + 页负载可读即视为已下载',
      );

      await tester.longPress(_chapterRow('Chapter 1'));
      await _settle(tester);
      expect(_enabled(tester, _deleteDownloadsKey), isTrue);
      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      await tester.tap(find.text(t.dialog_delete));
      await _advanceUntil(tester, () {
        return !File(p.join(row.extractDir, 'pages.json')).existsSync() &&
            !Directory(row.extractDir).existsSync() &&
            _rowWidget(tester, 'Chapter 1').downloadState ==
                MediaDetailDownloadState.none;
      });

      expect(File(p.join(row.extractDir, 'pages.json')).existsSync(), isFalse);
      expect(File(p.join(row.extractDir, '001.jpg')).existsSync(), isFalse);
      expect(Directory(row.extractDir).existsSync(), isFalse);
      expect(await db.getEpubBook(row.bookKey), isNotNull, reason: '作品条目保留');
      final MangaChapterStateRow? state = await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
      );
      expect(state?.readAt, 1);
      expect(state?.lastPage, 5);
      expect(state?.pageCount, 10);
    });

    testWidgets('重链到 local 根根 manifest 的章不提供删除下载动作', (
      WidgetTester tester,
    ) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      late Directory localMangaDir;
      await tester.runAsync(() async {
        row = await library.add(_entry());
        // 模拟 Rebuild/Import 把在线作品重链到 Local source root 下的单章
        // 用户原件：pages.json + 页图直接住在作品目录根。
        localMangaDir = Directory(p.join(root.path, 'local', 'Fixture series'))
          ..createSync(recursive: true);
        File(p.join(localMangaDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);
        await writePagesManifestAtomically(
          localMangaDir,
          MangaPagesManifest(
            sourceRuntime: 'mihon',
            sourceId: '1',
            sourceName: 'Fake',
            extensionPackage: 'org.example.fixture',
            mangaKey: '/series/fixture',
            mangaTitle: 'Fixture series',
            chapterKey: '/chapter/1',
            chapterName: 'Chapter 1',
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
          ),
        );
        await db.updateEpubBookContentPaths(
          row.bookKey,
          extractDir: localMangaDir.path,
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(
          tester,
          find.byKey(
            const ValueKey<String>('manga_chapter_download_downloaded'),
          ),
        );
      });

      // 单章菜单不出现「删除下载」：local 原件不属于 Download library。
      await tester.tap(
        find.descendant(
          of: _chapterRow('Chapter 1'),
          matching: find.byType(FushiOverflowMenu<String>),
        ),
      );
      await _settle(tester);
      expect(
        find.text(t.manga_chapter_download_delete_action),
        findsNothing,
        reason: '不能提供会静默删除 local 用户原件的动作',
      );
      await tester.tapAt(const Offset(5, 5));
      await _settle(tester);

      // 批量删除同样不可用。
      await tester.longPress(_chapterRow('Chapter 1'));
      await _settle(tester);
      expect(find.byKey(_deleteDownloadsKey), findsOneWidget);
      expect(
        _enabled(tester, _deleteDownloadsKey),
        isFalse,
        reason: '批量删除不得作用于 local 用户原件',
      );
      expect(File(p.join(localMangaDir.path, '001.jpg')).existsSync(), isTrue);
      expect(
        File(p.join(localMangaDir.path, 'pages.json')).existsSync(),
        isTrue,
      );
    });

    testWidgets('批量删除最后一章后清理空的 manga 与 source 目录', (WidgetTester tester) async {
      sizeView(tester);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);
      late EpubBookRow row;
      await tester.runAsync(() async {
        row = await library.add(_entry());
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/1',
          'Chapter 1',
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Chapter 1'));
      });

      await tester.longPress(_chapterRow('Chapter 1'));
      await _settle(tester);
      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      await tester.tap(find.text(t.dialog_delete));
      await _advanceUntil(
        tester,
        () => !Directory(row.extractDir).existsSync(),
      );

      expect(
        Directory(row.extractDir).existsSync(),
        isFalse,
        reason: '删完最后一章后空的 manga 目录应被清理',
      );
      expect(
        Directory(p.dirname(row.extractDir)).existsSync(),
        isFalse,
        reason: '整个 source 目录也空了才清理 source',
      );
      expect(
        Directory(p.join(root.path, 'downloads')).existsSync(),
        isTrue,
        reason: 'Download library 根目录保留',
      );
    });
  });

  group('本地图源', () {
    late Directory tmp;
    late AppPaths paths;
    late Directory mangaDir;
    late FushiDatabase db;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmp = Directory.systemTemp.createTempSync('manga_batch_delete_local_');
      AppPaths.debugTestEnvironment = <String, String>{
        'FUSHI_TEST_ROOT': tmp.path,
      };
      paths = await AppPaths.resolve();
      mangaDir = Directory(p.join(paths.localComicRoot.path, 'Fixture Series'))
        ..createSync(recursive: true);
      for (final String name in <String>['Ch 1', 'Ch 2']) {
        final Directory dir = Directory(p.join(mangaDir.path, name))
          ..createSync(recursive: true);
        File(p.join(dir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
      }
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      AppPaths.debugTestEnvironment = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets('本地图源章节的垃圾桶始终不可用', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final String bookKey = localSourceBookKeyFor(mangaDir.path);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: bookKey,
          title: 'Fixture Series',
          epubPath: '',
          extractDir: mangaDir.path,
          chapterCount: 2,
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
          importedAt: 0,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String>(
            LocalSourceMetadata(relativePath: 'Fixture Series').encode(),
          ),
        ),
      );
      final EpubBookRow row = (await db.getEpubBook(bookKey))!;

      late AppModel appModel;
      await tester.runAsync(() async {
        appModel = _TestAppModel(db, tmp, paths: paths);
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await pumpUntilFound(tester, find.text('Ch 1'));
      });

      await tester.longPress(_chapterRow('Ch 1'));
      await _settle(tester);
      await tester.tap(_chapterRow('Ch 2'));
      await _settle(tester);

      // 本地源章节在磁盘上原样可读，但那些文件属于用户，垃圾桶始终置灰。
      expect(find.byKey(_deleteDownloadsKey), findsOneWidget);
      expect(_enabled(tester, _deleteDownloadsKey), isFalse);

      // 置灰按钮点了不弹确认框、不动文件。
      await tester.tap(find.byKey(_deleteDownloadsKey));
      await _settle(tester);
      expect(find.text(t.manga_series_delete_downloads), findsNothing);
      expect(
        File(p.join(mangaDir.path, 'Ch 1', '001.jpg')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(mangaDir.path, 'Ch 2', '001.jpg')).existsSync(),
        isTrue,
      );
    });
  });
}
