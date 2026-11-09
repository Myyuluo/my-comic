import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 06：作品页章节列表的下载三态筛选。
///
/// 语义钉在页面级（真实 DB + 可控源）：筛选是作品页会话内状态，与「只看未读」
/// AND 联动；「已下载」只认磁盘上可读的章，排队 / 下载中 / 暂停 / 文件缺失都算
/// 未下载；本地图源章节恒为已下载；计数徽章始终显示章节总数。
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

  /// 开阅读器的副作用与本测试无关，只记「被调了」。
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

Future<void> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
  String chapterKey, {
  String chapterName = 'Chapter 1',
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

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

Finder _filterChip() =>
    find.byKey(const ValueKey<String>('manga_chapter_download_filter'));

Finder _chipLabel(String label) =>
    find.descendant(of: _filterChip(), matching: find.text(label));

List<String> _visibleChapterTitles() => <String>[
  for (final String name in <String>[
    'Chapter 4',
    'Chapter 3',
    'Chapter 2',
    'Chapter 1',
  ])
    if (find.text(name).evaluate().isNotEmpty) name,
];

void main() {
  group('在线源', () {
    late Directory root;
    late FushiDatabase db;
    late OnlineMangaLibraryService library;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      root = await Directory.systemTemp.createTemp('manga_series_filter_');
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

    testWidgets('下载筛选按 全部 → 已下载 → 未下载 → 全部 循环，计数徽章始终显示总数', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);

      await tester.runAsync(() async {
        final EpubBookRow row = await library.add(_entry());
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/1',
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await _pumpUntil(tester, find.text('Chapter 1'));
      });

      expect(_filterChip(), findsOneWidget, reason: '章节列表头部要有下载筛选 chip');
      expect(_chipLabel(t.home_filter_all), findsOneWidget);
      expect(_visibleChapterTitles(), <String>[
        'Chapter 4',
        'Chapter 3',
        'Chapter 2',
        'Chapter 1',
      ]);

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_chipLabel(t.shelf_filter_download_downloaded), findsOneWidget);
      expect(_visibleChapterTitles(), <String>['Chapter 1']);

      await tester.tap(_filterChip());
      await tester.pump();
      expect(
        _chipLabel(t.shelf_filter_download_not_downloaded),
        findsOneWidget,
      );
      expect(_visibleChapterTitles(), <String>[
        'Chapter 4',
        'Chapter 3',
        'Chapter 2',
      ]);

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_chipLabel(t.home_filter_all), findsOneWidget);
      expect(_visibleChapterTitles(), <String>[
        'Chapter 4',
        'Chapter 3',
        'Chapter 2',
        'Chapter 1',
      ]);

      // 计数徽章在每一种筛选下都显示章节总数。
      expect(
        find.descendant(
          of: find.byType(MediaDetailSectionHeader),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('已下载只算磁盘可读；排队 / 暂停 / 文件缺失都算未下载', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);

      await tester.runAsync(() async {
        final EpubBookRow row = await library.add(_entry());
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/1',
        );
        await _insertJob(
          db,
          bookKey: row.bookKey,
          chapterKey: '/chapter/2',
          status: MangaDownloadJobStatus.queued,
        );
        await _insertJob(
          db,
          bookKey: row.bookKey,
          chapterKey: '/chapter/3',
          status: MangaDownloadJobStatus.paused,
        );
        // 任务表 done 但磁盘没有文件 = Missing，不是已下载。
        await _insertJob(
          db,
          bookKey: row.bookKey,
          chapterKey: '/chapter/4',
          status: MangaDownloadJobStatus.done,
        );
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await _pumpUntil(tester, find.text('Chapter 1'));
      });

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_visibleChapterTitles(), <String>[
        'Chapter 1',
      ], reason: '排队 / 暂停 / 缺失都不算已下载');

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_visibleChapterTitles(), <String>[
        'Chapter 4',
        'Chapter 3',
        'Chapter 2',
      ]);
    });

    testWidgets('下载筛选与「只看未读」AND 联动', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);

      await tester.runAsync(() async {
        final EpubBookRow row = await library.add(_entry());
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/1',
        );
        await _writeDownloadedChapter(
          db,
          row.bookKey,
          row.extractDir,
          '/chapter/2',
          chapterName: 'Chapter 2',
        );
        // 第 1、4 话已读；第 2、3 话未读。
        for (final String key in <String>['/chapter/1', '/chapter/4']) {
          await db.saveMangaChapterState(
            bookUid: row.uid,
            chapterKey: key,
            lastPage: 0,
            readAt: 1,
          );
        }
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await _pumpUntil(tester, find.text('Chapter 1'));
      });

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_visibleChapterTitles(), <String>[
        'Chapter 2',
        'Chapter 1',
      ], reason: '已下载且已读的章仍然显示');

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_chapter_unread_only')),
      );
      await tester.pump();
      expect(_visibleChapterTitles(), <String>[
        'Chapter 2',
      ], reason: '已下载 AND 未读');

      await tester.tap(_filterChip());
      await tester.pump();
      expect(_visibleChapterTitles(), <String>[
        'Chapter 3',
      ], reason: '未下载 AND 未读；第 4 话未下载但已读，被只看未读滤掉');
    });

    testWidgets('筛选无结果时显示空态，计数徽章仍是总数', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _TestAppModel appModel = _TestAppModel(db, root, library: library);

      await tester.runAsync(() async {
        final EpubBookRow row = await library.add(_entry());
        await tester.pumpWidget(_harness(appModel, row.bookKey));
        await _pumpUntil(tester, find.text('Chapter 1'));
      });

      await tester.tap(_filterChip());
      await tester.pump();

      expect(_visibleChapterTitles(), isEmpty);
      expect(
        find.text(t.manga_series_no_chapters_match_filter),
        findsOneWidget,
        reason: '不是加载失败，是筛选没有匹配的章',
      );
      expect(
        find.text(t.manga_series_all_read),
        findsNothing,
        reason: '没有已下载的章不代表所有章节都读完了',
      );
      expect(
        find.descendant(
          of: find.byType(MediaDetailSectionHeader),
          matching: find.text('4'),
        ),
        findsOneWidget,
        reason: '计数徽章继续显示章节总数，不随筛选变化',
      );
    });
  });

  group('本地图源', () {
    late Directory tmp;
    late AppPaths paths;
    late FushiDatabase db;

    setUp(() async {
      LocaleSettings.setLocale(AppLocale.en);
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmp = Directory.systemTemp.createTempSync('manga_series_filter_local_');
      AppPaths.debugTestEnvironment = <String, String>{
        'FUSHI_TEST_ROOT': tmp.path,
      };
      paths = await AppPaths.resolve();
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      AppPaths.debugTestEnvironment = null;
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    testWidgets('本地图源章节恒为已下载', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final Directory mangaDir = Directory(
        p.join(paths.downloadsRoot.path, 'Example Source', 'Fixture series'),
      );
      final Directory chapterDir = Directory(p.join(mangaDir.path, 'Ch 1'))
        ..createSync(recursive: true);
      File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
      final String bookKey = localSourceBookKeyFor(mangaDir.path);
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
            LocalSourceMetadata(
              relativePath: 'Example Source/Fixture series',
            ).encode(),
          ),
        ),
      );
      final _TestAppModel appModel = _TestAppModel(db, tmp, paths: paths);

      await tester.runAsync(() async {
        await tester.pumpWidget(_harness(appModel, bookKey));
        await _pumpUntil(tester, find.text('Ch 1'));
      });

      expect(_filterChip(), findsOneWidget);
      await tester.tap(_filterChip());
      await tester.pump();
      expect(find.text('Ch 1'), findsOneWidget, reason: '本地图源的章在磁盘上原地可读，恒为已下载');

      await tester.tap(_filterChip());
      await tester.pump();
      expect(find.text('Ch 1'), findsNothing);
      expect(
        find.text(t.manga_series_no_chapters_match_filter),
        findsOneWidget,
      );
    });
  });
}
