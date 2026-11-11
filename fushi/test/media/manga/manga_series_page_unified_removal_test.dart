import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
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
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_engine/media/manga/reader_position.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// 票 01：在线 / 本地 Manga 作品页的「移出书架」共用一个轻量确认弹窗——只有标题、
/// 说明、两个默认不勾选的选项与取消/删除。文件删除先于数据库删除，失败保留作品；
/// History 不随移出删除。
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
  _TestAppModel(this._db, this._library, this._paths, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;

  @override
  AppPaths? get appPathsOrNull => _paths;

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

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 12}) async {
  for (int i = 0; i < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

Future<void> _openRemovalDialog(
  WidgetTester tester,
  AppModel appModel,
  String bookKey,
) async {
  await tester.pumpWidget(_harness(appModel, bookKey));
  await _pumpUntil(
    tester,
    find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
  );
  await tester.tap(
    find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
  );
  await _pumpUntil(tester, find.text(t.dialog_delete));
}

Future<Directory> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
) async {
  final Directory chapterDir = Directory(p.join(bookDir, 'Chapter 1'));
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: '/chapter/1',
    folderName: 'Chapter 1',
    updatedAt: 1,
  );
  return chapterDir;
}

Future<EpubBookRow> _insertLocalMangaRow(
  FushiDatabase db, {
  required String title,
  required Directory mangaDir,
  required String relativePath,
}) async {
  mangaDir.createSync(recursive: true);
  final Directory chapterDir = Directory(p.join(mangaDir.path, 'Ch 1'))
    ..createSync(recursive: true);
  File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
  final String bookKey = localSourceBookKeyFor(mangaDir.path);
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
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
        LocalSourceMetadata(relativePath: relativePath).encode(),
      ),
    ),
  );
  return (await db.getEpubBook(bookKey))!;
}

void main() {
  late Directory root;
  late AppPaths paths;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('manga_series_unified_rm_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    paths = await AppPaths.resolve();
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      // 与 AppPaths 解析出的 Download library 根一致（FUSHI_TEST_ROOT 下是
      // `<root>/content/downloads`）；移出时「删除本地文件」只允许删这个根
      // 内的文件。
      downloadsRootDirectory: paths.downloadsRoot,
      adapter: _FakeAdapter(),
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('在线作品页移出弹窗只有标题、说明、两个默认不勾选项；无披露块/记住选择/同步提示', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late String bookKey;
    late Directory chapterDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await _pumpUntil(tester, find.text(t.manga_series_remove_confirm));
    });

    expect(
      find.text(t.manga_series_remove_confirm),
      findsOneWidget,
      reason: '单本说明使用统一文案',
    );
    expect(find.text(t.delete_local_files), findsOneWidget);
    expect(find.text(t.delete_statistics), findsNothing,
        reason: 'ticket 05：统计删除选项已移除');
    expect(
      find.text(t.delete_disclosure_will_delete_label),
      findsNothing,
      reason: '粉色「会被删除」披露块已移除',
    );
    expect(
      find.text(t.delete_disclosure_will_keep_label),
      findsNothing,
      reason: '蓝色「会被保留」披露块已移除',
    );
    expect(
      find.text(t.delete_choices_remember),
      findsNothing,
      reason: '「记住这些选择」已移除',
    );
    expect(
      find.text(t.delete_scope_sync_everywhere),
      findsNothing,
      reason: '「从所有设备删除」不再出现',
    );
    expect(
      find.text(t.delete_scope_no_channel),
      findsNothing,
      reason: '同步能力提示不再出现',
    );

    // 默认两个选项都不勾：只移出书架，行与已下载章节文件都保留。
    await tester.runAsync(() async {
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });
    expect(
      (await db.getEpubBook(bookKey))?.isInLibrary,
      isFalse,
      reason: '默认移出只清 Library membership，不删除 Manga 行',
    );
    expect(chapterDir.existsSync(), isTrue, reason: '未勾选「同时删除本地文件」时已下载章节保留');
  });

  testWidgets('在线作品页：默认移出只清 membership，保留进度/已读/下载任务/映射/History，移除 Tag 与订阅', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    const String jobId = 'job-unified-online-default';
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
        lastPage: 3,
        readAt: 1,
      );
      await ReaderPositionRepository(
        db,
      ).save(bookUid: row.uid, sectionIndex: 1, normCharOffset: 20);
      final int tagId = await db.getOrCreateTagByName('Tag A');
      await db.addTagToBook(row.bookKey, tagId);
      await library.setSubscription(
        bookKey: row.bookKey,
        entry: _entry(),
        subscribed: true,
        autoDownload: true,
      );
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: _entry());
      await db.upsertStudySegment(
        StudySegmentsCompanion.insert(
          uid: FushiDatabase.newStudySegmentUid(),
          deviceId: 'dev-test',
          mediaKind: kActivityMediaBook,
          mediaKey: row.bookKey,
          title: row.title,
          startAt: 1000,
          endAt: 61000,
          dateKey: '2026-11-07',
          hour: 10,
          updatedAt: 61000,
        ),
      );
      await db.upsertMangaDownloadJob(
        MangaDownloadJobsCompanion.insert(
          jobId: jobId,
          kind: MangaDownloadJobKind.chapter,
          bookKey: row.bookKey,
          chapterKey: '/chapter/1',
          runtime: 'mihon',
          title: row.title,
          chapterTitle: 'Chapter 1',
          status: const Value<String>(MangaDownloadJobStatus.queued),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await _pumpUntil(tester, find.text(t.dialog_delete));
      // 两个选项都保持默认（不勾）。
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    final EpubBookRow? after = await db.getEpubBook(row.bookKey);
    expect(after, isNotNull, reason: '移出不删除 Manga 行');
    expect(after!.isInLibrary, isFalse, reason: 'Library membership 已清除');
    expect(after.uid, row.uid, reason: 'uid 不变');
    expect(chapterDir.existsSync(), isTrue, reason: '默认不删本地文件');
    expect(
      await db.getMangaChapterStates(row.uid),
      hasLength(1),
      reason: 'Chapter 已读标记保留',
    );
    expect(
      await ReaderPositionRepository(db).findByBookUid(row.uid),
      isNotNull,
      reason: 'Reading progress 保留',
    );
    expect(
      await db.getTagsForBook(row.bookKey),
      isEmpty,
      reason: 'Tag 分配随移出删除',
    );
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: row.bookKey,
      ),
      hasLength(1),
      reason: '默认不删统计数据',
    );
    expect(await loadMangaHistory(db), hasLength(1), reason: '移出书架不删除 History');
    expect(
      await db.getMangaChapterDir(row.bookKey, '/chapter/1'),
      isNotNull,
      reason: '下载索引（章目录映射）保留',
    );
    expect(
      await db.getMangaDownloadJob(jobId),
      isNotNull,
      reason: '默认移出保留排队中的下载任务',
    );
    final OnlineMangaLibraryEntry afterEntry =
        OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!;
    expect(afterEntry.subscribed, isFalse, reason: '移出后订阅被移除');
    expect(afterEntry.autoDownload, isFalse, reason: '移出后自动追更被移除');
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
      reason: '页面切回「加入书架」',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_subscribe')),
      findsNothing,
      reason: '非书架作品不再显示订阅入口',
    );
  });

  testWidgets('在线作品页：勾选「同时删除本地文件」→ 文件与下载索引删除，非书架行与阅读状态保留', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    const String jobId = 'job-unified-online-delete-files';
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
        lastPage: 2,
        readAt: 1,
      );
      await db.upsertMangaDownloadJob(
        MangaDownloadJobsCompanion.insert(
          jobId: jobId,
          kind: MangaDownloadJobKind.chapter,
          bookKey: row.bookKey,
          chapterKey: '/chapter/1',
          runtime: 'mihon',
          title: row.title,
          chapterTitle: 'Chapter 1',
          status: const Value<String>(MangaDownloadJobStatus.done),
          createdAt: 1,
          updatedAt: 1,
        ),
      );
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: _entry());
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    final EpubBookRow? after = await db.getEpubBook(row.bookKey);
    expect(after, isNotNull, reason: '在线作品删文件后仍保留非书架行');
    expect(after!.isInLibrary, isFalse);
    expect(chapterDir.existsSync(), isFalse, reason: '已下载章节目录删除');
    expect(Directory(row.extractDir).existsSync(), isFalse, reason: '作品目录删除');
    expect(
      await db.getMangaChapterDir(row.bookKey, '/chapter/1'),
      isNull,
      reason: '下载索引随删文件清除',
    );
    expect(
      await db.getMangaDownloadJob(jobId),
      isNull,
      reason: '指向已删文件的任务清除',
    );
    expect(
      await db.getMangaChapterStates(row.uid),
      hasLength(1),
      reason: '阅读状态保留',
    );
    expect(
      await loadMangaHistory(db),
      hasLength(1),
      reason: '即使删了文件，History 也保留',
    );
  });

  testWidgets(
    '在线作品页：extractDir 指向 local 原作时勾选「删除本地文件」不删原作，只移出书架',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

      late EpubBookRow row;
      late Directory localOriginal;
      await tester.runAsync(() async {
        row = await library.add(_entry());
        // Ticket 12：重建/导入可以把在线行的 extractDir 关联到 local 中带
        // pages.json 的目录。这里的文件是用户的原作，不是可删的下载副本。
        localOriginal = Directory(
          p.join(paths.localComicRoot.path, 'Local original'),
        );
        await localOriginal.create(recursive: true);
        await File(
          p.join(localOriginal.path, '001.jpg'),
        ).writeAsBytes(<int>[1, 2, 3]);
        await db.updateEpubBookContentPaths(
          row.bookKey,
          extractDir: localOriginal.path,
        );
        row = (await db.getEpubBook(row.bookKey))!;
        await _writeDownloadedChapter(db, row.bookKey, localOriginal.path);
        await _openRemovalDialog(tester, appModel, row.bookKey);
        await tester.tap(find.text(t.delete_local_files));
        await tester.pump();
        await tester.tap(find.text(t.dialog_delete));
        await _pumpUntil(
          tester,
          find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
        );
      });

      expect(
        localOriginal.existsSync(),
        isTrue,
        reason: 'local 原作绝不因在线作品的「删除本地文件」被删除',
      );
      expect(
        File(p.join(localOriginal.path, '001.jpg')).existsSync(),
        isTrue,
        reason: 'local 原作文件保留',
      );
      final EpubBookRow after = (await db.getEpubBook(row.bookKey))!;
      expect(after.isInLibrary, isFalse, reason: '作品仍按非破坏语义移出书架');
      expect(
        await db.getMangaChapterDir(row.bookKey, '/chapter/1'),
        isNotNull,
        reason: '文件没有删除时下载索引原样保留',
      );
    },
  );

  testWidgets('在线作品页：统计删除入口已移除 → 移出保留统计，已下载文件保留', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      await db.upsertStudySegment(
        StudySegmentsCompanion.insert(
          uid: FushiDatabase.newStudySegmentUid(),
          deviceId: 'dev-test',
          mediaKind: kActivityMediaBook,
          mediaKey: row.bookKey,
          title: row.title,
          startAt: 1000,
          endAt: 61000,
          dateKey: '2026-11-07',
          hour: 10,
          updatedAt: 61000,
        ),
      );
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isFalse,
      reason: '移出只清 membership，不删 Manga 行',
    );
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: row.bookKey,
      ),
      hasLength(1),
      reason: 'ticket 05：移出书架不再提供统计删除',
    );
    final List<StudySegmentTombstoneRow> tombstones = await db
        .getStudySegmentTombstones();
    expect(
      tombstones.where(
        (StudySegmentTombstoneRow t) => t.mediaKey == row.bookKey,
      ),
      isEmpty,
      reason: '统计未删除，不写墓碑',
    );
    expect(chapterDir.existsSync(), isTrue, reason: '未勾选删文件时章节文件保留');
  });

  testWidgets('在线作品页：文件删除失败时作品留在 Library 并显示失败提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    RandomAccessFile? openFile;
    addTearDown(() {
      openFile?.closeSync();
      openFile = null;
    });
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      // Windows 上被占用的文件无法随目录递归删除：稳定地制造一次文件删除失败。
      openFile = File(
        p.join(chapterDir.path, '001.jpg'),
      ).openSync(mode: FileMode.write);
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(tester, find.textContaining(t.epub_delete_error));
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isTrue,
      reason: '文件删除失败时作品必须留在 Library',
    );
    expect(chapterDir.existsSync(), isTrue);
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
      reason: '页面仍显示在库态，可稍后重试',
    );
    openFile?.closeSync();
    openFile = null;
  });

  testWidgets('在线作品页：文件本来就不存在时视为已删除', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      final Directory workDir = Directory(row.extractDir);
      if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isFalse,
      reason: '缺失文件不阻塞移出',
    );
    expect(
      find.textContaining(t.epub_delete_error),
      findsNothing,
      reason: '文件已不存在不算失败',
    );
  });

  testWidgets('在线作品页：记住选择偏好不再影响弹窗默认值', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      await _openRemovalDialog(tester, appModel, row.bookKey);
      // 上次记住的是「删除本地文件」，本次必须仍然默认不勾。
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isFalse,
    );
    expect(chapterDir.existsSync(), isTrue, reason: '旧「记住这些选择」值被忽略，文件没有被误删');
  });

  testWidgets('在线作品页：点取消不产生任何数据变化', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory chapterDir;
    late int tagId;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      chapterDir = await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
      );
      tagId = await db.getOrCreateTagByName('Tag A');
      await db.addTagToBook(row.bookKey, tagId);
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: _entry());
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.dialog_cancel));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(await db.getEpubBook(row.bookKey), isNotNull);
    expect(chapterDir.existsSync(), isTrue);
    expect(await db.getTagsForBook(row.bookKey), hasLength(1));
    expect(await loadMangaHistory(db), hasLength(1));
  });

  testWidgets('本地作品页：默认移出只清 membership，保留原作文件/进度/已读/History，移除 Tag', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory mangaDir;
    await tester.runAsync(() async {
      mangaDir = Directory(p.join(paths.localComicRoot.path, 'Local series'));
      row = await _insertLocalMangaRow(
        db,
        title: 'Local series',
        mangaDir: mangaDir,
        relativePath: 'Local series',
      );
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'ch1',
        lastPage: 2,
        readAt: 1,
      );
      await ReaderPositionRepository(
        db,
      ).save(bookUid: row.uid, sectionIndex: 1, normCharOffset: 5);
      final int tagId = await db.getOrCreateTagByName('Tag A');
      await db.addTagToBook(row.bookKey, tagId);
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);
      await _openRemovalDialog(tester, appModel, row.bookKey);
    });

    expect(find.text(t.manga_series_remove_confirm), findsOneWidget);
    expect(find.text(t.delete_local_files), findsOneWidget);
    expect(find.text(t.delete_statistics), findsNothing,
        reason: 'ticket 05：统计删除选项已移除');
    expect(find.text(t.delete_disclosure_will_delete_label), findsNothing);
    expect(find.text(t.delete_disclosure_will_keep_label), findsNothing);
    expect(find.text(t.delete_choices_remember), findsNothing);
    expect(find.text(t.delete_scope_no_channel), findsNothing);

    await tester.runAsync(() async {
      // 两个选项保持默认（不勾）。
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    final EpubBookRow? after = await db.getEpubBook(row.bookKey);
    expect(after, isNotNull, reason: '本地作品移出不删除 Manga 行');
    expect(after!.isInLibrary, isFalse, reason: 'Library membership 已清除');
    expect(mangaDir.existsSync(), isTrue, reason: '默认保留 local 原作文件夹');
    expect(
      await db.getMangaChapterStates(row.uid),
      hasLength(1),
      reason: 'Chapter 已读标记保留',
    );
    expect(
      await ReaderPositionRepository(db).findByBookUid(row.uid),
      isNotNull,
      reason: 'Reading progress 保留',
    );
    expect(await db.getTagsForBook(row.bookKey), isEmpty);
    expect(await loadMangaHistory(db), hasLength(1), reason: 'History 保留');
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsNothing,
      reason: '移出后不再显示「移出书架」',
    );
  });

  testWidgets('本地作品页：勾选「同时删除本地文件」→ local 原作文件夹删除，History 保留', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory mangaDir;
    await tester.runAsync(() async {
      mangaDir = Directory(p.join(paths.localComicRoot.path, 'Local series'));
      row = await _insertLocalMangaRow(
        db,
        title: 'Local series',
        mangaDir: mangaDir,
        relativePath: 'Local series',
      );
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    expect(await db.getEpubBook(row.bookKey), isNull);
    expect(mangaDir.existsSync(), isFalse, reason: '勾选后删除原作文件夹');
    expect(await loadMangaHistory(db), hasLength(1), reason: 'History 保留');
  });

  testWidgets('本地作品页：统计删除入口已移除 → 统计保留', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    await tester.runAsync(() async {
      final Directory mangaDir = Directory(
        p.join(paths.localComicRoot.path, 'Local series'),
      );
      row = await _insertLocalMangaRow(
        db,
        title: 'Local series',
        mangaDir: mangaDir,
        relativePath: 'Local series',
      );
      await db.upsertStudySegment(
        StudySegmentsCompanion.insert(
          uid: FushiDatabase.newStudySegmentUid(),
          deviceId: 'dev-test',
          mediaKind: kActivityMediaBook,
          mediaKey: row.bookKey,
          title: row.title,
          startAt: 1000,
          endAt: 61000,
          dateKey: '2026-11-07',
          hour: 10,
          updatedAt: 61000,
        ),
      );
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isFalse,
      reason: '移出只清 membership，不删行',
    );
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: row.bookKey,
      ),
      hasLength(1),
      reason: 'ticket 05：移出书架不再提供统计删除',
    );
    final List<StudySegmentTombstoneRow> tombstones = await db
        .getStudySegmentTombstones();
    expect(
      tombstones.where(
        (StudySegmentTombstoneRow t) => t.mediaKey == row.bookKey,
      ),
      isEmpty,
    );
  });

  testWidgets('本地作品页：文件删除失败时作品留在 Library 并显示失败提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    late Directory mangaDir;
    RandomAccessFile? openFile;
    addTearDown(() {
      openFile?.closeSync();
      openFile = null;
    });
    await tester.runAsync(() async {
      mangaDir = Directory(p.join(paths.localComicRoot.path, 'Local series'));
      row = await _insertLocalMangaRow(
        db,
        title: 'Local series',
        mangaDir: mangaDir,
        relativePath: 'Local series',
      );
      openFile = File(
        p.join(mangaDir.path, 'Ch 1', '001.jpg'),
      ).openSync(mode: FileMode.write);
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(tester, find.textContaining(t.epub_delete_error));
    });

    expect(
      (await db.getEpubBook(row.bookKey))?.isInLibrary,
      isTrue,
      reason: '文件删除失败时作品必须留在 Library',
    );
    expect(mangaDir.existsSync(), isTrue);
    openFile?.closeSync();
    openFile = null;
  });

  testWidgets('本地作品页：原作文件夹本来就不存在时视为已删除', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _TestAppModel appModel = _TestAppModel(db, library, paths, root);

    late EpubBookRow row;
    await tester.runAsync(() async {
      final Directory mangaDir = Directory(
        p.join(paths.localComicRoot.path, 'Local series'),
      );
      row = await _insertLocalMangaRow(
        db,
        title: 'Local series',
        mangaDir: mangaDir,
        relativePath: 'Local series',
      );
      mangaDir.deleteSync(recursive: true);
      await _openRemovalDialog(tester, appModel, row.bookKey);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    expect(
      await db.getEpubBook(row.bookKey),
      isNull,
      reason: '本地作品删文件移出时连行一起删除；缺失文件不阻塞',
    );
    expect(find.textContaining(t.epub_delete_error), findsNothing);
  });

  test('zh-CN 文案与票面一致', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(t.manga_series_remove_from_bookshelf, '移出漫画书架');
    expect(
      t.manga_series_remove_confirm,
      '把这部作品移出书架？阅读进度、已读标记、已下载章节与 History 会保留。',
    );
    expect(
      t.manga_series_remove_confirm_batch(n: 3),
      '确定把选中的 3 部作品移出书架？阅读进度、已读标记、已下载章节与 History 会保留。',
    );
    expect(t.delete_local_files_download_desc, '已下载的章节文件会从本机删除，且无法恢复。');
  });
}
