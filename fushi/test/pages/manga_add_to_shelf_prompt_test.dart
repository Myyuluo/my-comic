import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/manga_add_to_shelf_prompt.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

/// manga-library-membership 票 15（review finding 4）：下载完成后的可选
/// 「加入书架？」提示必须是**全局**钩子，不能只在作品页打开期间触发。
///
/// 页面级 seam：真 37 表内存 DB + 可控在线源；宿主挂在 app 根部（测试壳里
/// 直接包住 DownloadsPage / 空页面），只通过任务表状态变化模拟下载完成。
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
  }) async => const <OnlineMangaPageRef>[];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async =>
      Uint8List(0);

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => const <int>[];
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, this._downloads, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final MangaDownloadService _downloads;

  @override
  FushiDatabase get database => _db;

  @override
  MangaDownloadService get mangaDownloadService => _downloads;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

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

Widget _harness({required AppModel appModel, required Widget home}) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: MangaAddToShelfPromptHost(child: home),
        ),
      ),
    );

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
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

const ValueKey<String> _promptKey = ValueKey<String>(
  'manga_series_add_to_shelf_after_download',
);

Future<void> _waitForJobBaseline(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  });
  await tester.pump();
}

Future<void> _insertJob(
  FushiDatabase db, {
  required String jobId,
  required EpubBookRow row,
  required String status,
  required int updatedAt,
}) => db.upsertMangaDownloadJob(
  MangaDownloadJobsCompanion.insert(
    jobId: jobId,
    kind: MangaDownloadJobKind.chapter,
    bookKey: row.bookKey,
    chapterKey: '/chapter/1',
    runtime: 'mihon',
    title: row.title,
    chapterTitle: 'Chapter 1',
    status: Value<String>(status),
    pagesDone: const Value<int>(1),
    pagesTotal: const Value<int>(1),
    createdAt: updatedAt,
    updatedAt: updatedAt,
    completedAt: Value<int?>(
      status == MangaDownloadJobStatus.done ? updatedAt : null,
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;
  late MangaDownloadService downloads;
  late _TestAppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = Directory.systemTemp.createTempSync('manga_add_to_shelf_prompt_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory('${root.path}/legacy'),
      adapter: _FakeAdapter(),
      downloadsRootDirectory: Directory('${root.path}/downloads'),
    );
    downloads = MangaDownloadService(
      database: db,
      serviceFor: (OnlineMangaRuntimeKind runtime) => library,
      saveAsCbz: () => false,
    );
    appModel = _TestAppModel(db, library, downloads, root);
  });

  tearDown(() async {
    downloads.dispose();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('作品页未打开时下载完成也提示；点按钮前绝不自动加入书架', (
    WidgetTester tester,
  ) async {
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_entry);
    });
    await tester.pumpWidget(
      _harness(
        appModel: appModel,
        home: Scaffold(body: Center(child: Text('Library page'))),
      ),
    );
    await _waitForJobBaseline(tester);

    await tester.runAsync(() async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await _insertJob(
        db,
        jobId: 'global-complete',
        row: row,
        status: MangaDownloadJobStatus.done,
        updatedAt: now,
      );
      await pumpUntilFound(tester, find.byKey(_promptKey));
    });
    // 等提示条滑入到位再点动作（刚入树时还在屏幕下方）。
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(_promptKey), findsOneWidget);
    expect(
      (await db.getEpubBook(row.bookKey))!.isInLibrary,
      isFalse,
      reason: '提示不得自动加入书架',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.descendant(
          of: find.byKey(_promptKey),
          matching: find.text(t.mihon_add_to_bookshelf),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    final EpubBookRow after = (await db.getEpubBook(row.bookKey))!;
    expect(after.isInLibrary, isTrue, reason: '点提示按钮后才加入书架');
    expect(after.bookKey, row.bookKey, reason: '翻转同一条非书架行');
    expect(after.uid, row.uid);
  });

  testWidgets('下载页上重试完成也提示（不依赖作品页状态）', (
    WidgetTester tester,
  ) async {
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_entry);
      await _insertJob(
        db,
        jobId: 'retried-on-downloads',
        row: row,
        status: MangaDownloadJobStatus.failed,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    });
    await tester.pumpWidget(
      _harness(
        appModel: appModel,
        home: Scaffold(
          body: DownloadsPage(downloadsOverride: downloads),
        ),
      ),
    );
    await _waitForJobBaseline(tester);
    expect(find.byKey(_promptKey), findsNothing, reason: '失败任务不提示');

    await tester.runAsync(() async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      await _insertJob(
        db,
        jobId: 'retried-on-downloads',
        row: row,
        status: MangaDownloadJobStatus.done,
        updatedAt: now,
      );
      await pumpUntilFound(tester, find.byKey(_promptKey));
    });

    expect(find.byKey(_promptKey), findsOneWidget);
    expect(
      (await db.getEpubBook(row.bookKey))!.isInLibrary,
      isFalse,
      reason: '重试成功也只是可选提示',
    );
  });

  testWidgets('挂载前就已完成的任务不追问', (WidgetTester tester) async {
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.ensureNonLibrary(_entry);
      final int before = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      await _insertJob(
        db,
        jobId: 'pre-existing-done',
        row: row,
        status: MangaDownloadJobStatus.done,
        updatedAt: before,
      );
    });
    await tester.pumpWidget(
      _harness(
        appModel: appModel,
        home: Scaffold(body: Center(child: Text('Library page'))),
      ),
    );
    await _waitForJobBaseline(tester);

    expect(find.byKey(_promptKey), findsNothing);
    expect((await db.getEpubBook(row.bookKey))!.isInLibrary, isFalse);
  });
}
