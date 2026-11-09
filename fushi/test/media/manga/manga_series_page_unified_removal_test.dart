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
import 'package:fushi/src/sync/deletion_prompt_preferences.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
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
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
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
    expect(find.text(t.delete_statistics), findsOneWidget);
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

    // 默认两个选项都不勾：直接删除只移出书架，已下载章节文件保留。
    await tester.runAsync(() async {
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });
    expect(await db.getEpubBook(bookKey), isNull);
    expect(chapterDir.existsSync(), isTrue, reason: '未勾选「同时删除本地文件」时已下载章节保留');
  });

  testWidgets('在线作品页：不勾选任何选项只移出书架，文件与统计保留，进度/已读/标签删除，History 保留', (
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

    expect(await db.getEpubBook(row.bookKey), isNull, reason: 'Library 条目已删');
    expect(chapterDir.existsSync(), isTrue, reason: '默认不删本地文件');
    expect(
      await db.getMangaChapterStates(row.uid),
      isEmpty,
      reason: 'Chapter 已读标记随移出删除',
    );
    expect(
      await ReaderPositionRepository(db).findByBookUid(row.uid),
      isNull,
      reason: 'Reading progress 随移出删除',
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
  });

  testWidgets('在线作品页：勾选「同时删除本地文件」→ 已下载章节文件删除，History 保留', (
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

    expect(await db.getEpubBook(row.bookKey), isNull);
    expect(chapterDir.existsSync(), isFalse, reason: '已下载章节目录删除');
    expect(Directory(row.extractDir).existsSync(), isFalse, reason: '作品目录删除');
    expect(
      await loadMangaHistory(db),
      hasLength(1),
      reason: '即使删了文件，History 也保留',
    );
  });

  testWidgets('在线作品页：勾选「同时删除统计数据」→ 统计与墓碑写入，已下载文件保留', (
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
      await tester.tap(find.text(t.delete_statistics));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(await db.getEpubBook(row.bookKey), isNull);
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: row.bookKey,
      ),
      isEmpty,
      reason: '统计事实随勾选删除',
    );
    final List<StudySegmentTombstoneRow> tombstones = await db
        .getStudySegmentTombstones();
    expect(
      tombstones.where(
        (StudySegmentTombstoneRow t) => t.mediaKey == row.bookKey,
      ),
      hasLength(1),
      reason: '删除写墓碑，防止其他路径把统计加回',
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
      await db.getEpubBook(row.bookKey),
      isNotNull,
      reason: '文件删除失败时 Library 条目必须保留',
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

    expect(await db.getEpubBook(row.bookKey), isNull, reason: '缺失文件不阻塞移出');
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
      await DeletePromptPreferenceStore(db).write(
        const DeletePromptRememberedChoices(
          syncEverywhere: true,
          deleteLocalFiles: true,
        ),
      );
      await _openRemovalDialog(tester, appModel, row.bookKey);
      // 上次记住的是「删除本地文件」，本次必须仍然默认不勾。
      await tester.tap(find.text(t.dialog_delete));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
    });

    expect(await db.getEpubBook(row.bookKey), isNull);
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

  testWidgets('本地作品页：与在线共用同一弹窗，默认只移出书架（保留原作文件），进度/已读/标签删除，History 保留', (
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
    expect(find.text(t.delete_statistics), findsOneWidget);
    expect(find.text(t.delete_disclosure_will_delete_label), findsNothing);
    expect(find.text(t.delete_disclosure_will_keep_label), findsNothing);
    expect(find.text(t.delete_choices_remember), findsNothing);
    expect(find.text(t.delete_scope_no_channel), findsNothing);

    await tester.runAsync(() async {
      // 两个选项保持默认（不勾）。
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    expect(await db.getEpubBook(row.bookKey), isNull, reason: 'Library 条目已删');
    expect(mangaDir.existsSync(), isTrue, reason: '默认保留 local 原作文件夹');
    expect(await db.getMangaChapterStates(row.uid), isEmpty);
    expect(await ReaderPositionRepository(db).findByBookUid(row.uid), isNull);
    expect(await db.getTagsForBook(row.bookKey), isEmpty);
    expect(await loadMangaHistory(db), hasLength(1), reason: 'History 保留');
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

  testWidgets('本地作品页：勾选「同时删除统计数据」→ 统计移除', (WidgetTester tester) async {
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
      await tester.tap(find.text(t.delete_statistics));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await _pumpFrames(tester);
    });

    expect(await db.getEpubBook(row.bookKey), isNull);
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: row.bookKey,
      ),
      isEmpty,
    );
    final List<StudySegmentTombstoneRow> tombstones = await db
        .getStudySegmentTombstones();
    expect(
      tombstones.where(
        (StudySegmentTombstoneRow t) => t.mediaKey == row.bookKey,
      ),
      hasLength(1),
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
      await db.getEpubBook(row.bookKey),
      isNotNull,
      reason: '文件删除失败时 Library 条目必须保留',
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

    expect(await db.getEpubBook(row.bookKey), isNull, reason: '缺失文件不阻塞移出');
    expect(find.textContaining(t.epub_delete_error), findsNothing);
  });

  test('zh-CN 文案与票面一致', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(t.manga_series_remove_from_bookshelf, '移出漫画书架');
    expect(t.manga_series_remove_confirm, '把这部作品移出书架？阅读进度与已读标记会一并删除。');
    expect(t.delete_local_files_download_desc, '已下载的章节文件会从本机删除，且无法恢复。');
    expect(t.delete_statistics_manga_desc, '该作品的阅读时长、页数与查词/制卡计数将从统计中移除，且无法恢复。');
  });
}
