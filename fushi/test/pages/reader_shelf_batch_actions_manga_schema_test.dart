// ticket 01：漫画页批量选择栏在 my-comic 37 表 schema 下的回归。
//
// 根因（spec 已确认）：批量动作前的选中项存在性检查无条件查询 `srt_books`，
// 而 my-comic 的漫画-only live schema 只有 37 张表、没有 `srt_books` /
// `audiobooks`。异常让标签 / 重置进度 / 删除在弹窗之前就静默失败。
//
// 本文件用真实的 [FushiDatabase]（37 表 schema）挂载真实漫画书架页，从点击
// 「选择」、勾选漫画、点批量动作一路断言到数据库结果，不 mock 页面内部方法。
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_batch_schema_pp',
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

  late FushiDatabase db;
  late AppModel appModel;
  late Directory storeDir;
  late List<MediaItem> books;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_batch_schema_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    // 长按菜单（MediaItemDialogPage）经 item.getMediaSource 取源，
    // 需要媒体类型表 + 源表都像真实启动那样注册。
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    books = <MediaItem>[];
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> seedManga(String bookKey, String title) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey.mokuro',
        // 每本一个独立解压目录：删除路径会真的清理它，不能指向共享临时根。
        // bookKey 里的 ':' 在 Windows 路径里非法，换成 '_'。
        extractDir: '${pathProviderDir.path}/${bookKey.replaceAll(':', '_')}',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 0,
        format: const Value('manga'),
      ),
    );
    books.add(
      MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
        position: 0,
        duration: 1,
        canDelete: true,
        canEdit: true,
      ),
    );
  }

  Widget buildApp() => ProviderScope(
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
        builder: (BuildContext context, Widget? child) =>
            child ?? const SizedBox.shrink(),
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            mangaOnly: true,
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Finder bookCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  bool batchButtonEnabled(WidgetTester tester, String key) =>
      tester.widget<FushiIconButton>(find.byKey(ValueKey<String>(key))).enabled;

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(FushiIcons.checklist));
    await tester.pumpAndSettle();
  }

  testWidgets('37 表 schema：选中漫画后批量打标签打开选择器并落库', (WidgetTester tester) async {
    const String bookKey = 'manga:schema:tag';
    await seedManga(bookKey, 'Schema Manga');
    final int tagId = await db.createTag('Tag A', 0xFF112233);
    expect(
      await db.hasTable('srt_books'),
      isFalse,
      reason: '前提：my-comic live schema 不含 srt_books',
    );
    expect(
      await db.hasTable('audiobooks'),
      isFalse,
      reason: '前提：my-comic live schema 不含 audiobooks',
    );

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(bookCard(bookKey));
    await tester.pumpAndSettle();

    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsOneWidget,
      reason: '勾选漫画后底栏计数必须更新',
    );
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_tag'),
      isTrue,
      reason: '本地选中集非空，批量标签必须可用',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_tag')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(TagPickerPanel),
      findsOneWidget,
      reason: '批量标签必须真的打开选择器，不能因缺表异常静默失败',
    );
    await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
    await tester.pumpAndSettle();

    final List<BookTagRow> tags = await db.getTagsForBook(bookKey);
    expect(
      tags.map((BookTagRow row) => row.id),
      contains(tagId),
      reason: '批量标签要真的落到 tag_assignments',
    );
    await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
    await tester.pumpAndSettle();
  });

  testWidgets('37 表 schema：全选 / 反选更新「已选 N」并作用于可见漫画', (
    WidgetTester tester,
  ) async {
    const String bookA = 'manga:schema:select:a';
    const String bookB = 'manga:schema:select:b';
    await seedManga(bookA, 'Select Manga A');
    await seedManga(bookB, 'Select Manga B');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);

    await tester.tap(find.text(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_selected_count(n: 2)),
      findsOneWidget,
      reason: '全选要覆盖当前可见的两部漫画',
    );
    expect(
      batchButtonEnabled(tester, 'reader_shelf_batch_tag'),
      isTrue,
      reason: '全选后本地批量动作可用',
    );

    await tester.tap(find.text(t.batch_invert_selection));
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_selected_count(n: 0)),
      findsOneWidget,
      reason: '全选后反选 = 清空',
    );

    // 单选一本再反选：另一本接替被选中，计数仍为 1。
    await tester.tap(bookCard(bookA));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
    await tester.tap(find.text(t.batch_invert_selection));
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsOneWidget,
      reason: '反选必须作用于可见漫画，而不是只改计数',
    );
  });

  testWidgets('37 表 schema：批量重置阅读状态打开确认框并真正归零进度', (WidgetTester tester) async {
    const String bookKey = 'manga:schema:reset';
    await seedManga(bookKey, 'Reset Manga');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: row.uid,
        sectionIndex: 5,
        normCharOffset: 0,
        updatedAt: 1000,
      ),
    );
    await db.setEpubBookCompleted(
      bookKey,
      DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(bookCard(bookKey));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_reset_progress')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.library_progress_reset_action),
      findsOneWidget,
      reason: '批量重置必须真的弹出共享重置对话框',
    );

    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();

    expect(
      (await db.getEpubBook(bookKey))?.completedAt,
      isNull,
      reason: '重置后必须清掉读完标记',
    );
    final ReaderPositionRow? position = await db.getReaderPosition(row.uid);
    expect(position, isNotNull, reason: '重置写回开头位置而不是删行（同步安全）');
    expect(position!.sectionIndex, 0, reason: '重置后阅读位置必须回到第 0 节');
  });

  testWidgets('37 表 schema：批量删除打开确认框并真正删除选中漫画', (WidgetTester tester) async {
    const String bookKey = 'manga:schema:delete';
    await seedManga(bookKey, 'Delete Manga');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(bookCard(bookKey));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_delete')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.manga_series_remove_from_bookshelf),
      findsOneWidget,
      reason: '批量删除必须真的弹出票 01 的统一确认框',
    );
    expect(
      find.text(t.delete_local_files_audio_desc),
      findsNothing,
      reason: '统一弹窗不再使用有声书专用「原始音频」文案',
    );

    await tester.tap(find.text(t.dialog_delete));
    await tester.pump();
    // 删除带真实文件 IO 与进度弹窗：用 runAsync 放真时间、pump 推帧，
    // 交替直到 DB 行真的消失。
    for (int i = 0; i < 200 && await db.getEpubBook(bookKey) != null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      await db.getEpubBook(bookKey),
      isNull,
      reason: '确认后选中的漫画必须从 epub_books 删除',
    );
  });

  testWidgets('37 表 schema：单卡菜单重置阅读状态共用同一落地路径', (WidgetTester tester) async {
    const String bookKey = 'manga:schema:single-reset';
    await seedManga(bookKey, 'Single Reset Manga');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    await db.setEpubBookCompleted(
      bookKey,
      DateTime.fromMillisecondsSinceEpoch(2000),
    );

    await pumpPage(tester);
    await tester.longPress(bookCard(bookKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.library_progress_reset_action));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.library_progress_reset_confirm));
    await tester.pumpAndSettle();

    expect(
      (await db.getEpubBook(bookKey))?.completedAt,
      isNull,
      reason: '单卡重置与批量重置共用 resetBookReadingState，37 表下同样必须生效',
    );
    expect(
      await db.getReaderPosition(row.uid),
      isNull,
      reason: '从没留过位置的书不凭空造位置行',
    );
  });

  test('schema 能力 helper 是历史表存在性的唯一判据', () async {
    expect(
      await db.hasSrtBooksTable,
      isFalse,
      reason: '37 表 schema 没有 srt_books',
    );
    expect(
      await db.hasAudiobooksTable,
      isFalse,
      reason: '37 表 schema 没有 audiobooks',
    );

    await db.customStatement('''
CREATE TABLE srt_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  author TEXT,
  audio_root TEXT,
  audio_paths_json TEXT,
  srt_path TEXT NOT NULL,
  cover_path TEXT,
  imported_at INTEGER NOT NULL,
  local_added_at INTEGER,
  book_key TEXT NOT NULL DEFAULT '',
  language TEXT
)
''');
    expect(await db.hasSrtBooksTable, isTrue, reason: '表存在时能力位必须为真');
    expect(await db.hasAudiobooksTable, isFalse, reason: '能力位按表分别判定，不互相连坐');
  });

  test('srt_books 缺表时读接口按空集合处理，不抛缺表异常', () async {
    expect(await db.hasTable('srt_books'), isFalse);
    final SrtBookRepository repo = SrtBookRepository(db);
    expect(await repo.listAll(), isEmpty);
    expect(await repo.findByUid('missing'), isNull);
    expect(await repo.findByBookKey('missing'), isNull);
  });

  test('srt_books 表存在时读接口行为不变', () async {
    await db.customStatement('''
CREATE TABLE srt_books (
  id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
  uid TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  author TEXT,
  audio_root TEXT,
  audio_paths_json TEXT,
  srt_path TEXT NOT NULL,
  cover_path TEXT,
  imported_at INTEGER NOT NULL,
  local_added_at INTEGER,
  book_key TEXT NOT NULL DEFAULT '',
  language TEXT
)
''');
    final File srtFile = File('${pathProviderDir.path}/schema-guard.srt')
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nhi\n');
    await db.customInsert(
      'INSERT INTO srt_books (uid, title, srt_path, imported_at, book_key) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: <Variable<Object>>[
        const Variable<String>('row-1'),
        const Variable<String>('Row One'),
        Variable<String>(srtFile.path),
        const Variable<int>(0),
        const Variable<String>('book-1'),
      ],
    );

    final SrtBookRepository repo = SrtBookRepository(db);
    final List<SrtBook> all = await repo.listAll();
    expect(all, hasLength(1), reason: '表存在时必须照常列出字幕书');
    expect(all.single.uid, 'row-1');
    expect((await repo.findByUid('row-1'))?.title, 'Row One');
    expect((await repo.findByBookKey('book-1'))?.uid, 'row-1');
  });

  test('单卡与批量删除共用的 hasLocalFiles 在 37 表 schema 下返回 false', () async {
    const String bookKey = 'manga:schema:local-files';
    await seedManga(bookKey, 'No Local Files');
    expect(
      await ReaderFushiSource.instance.hasLocalFiles(db: db, bookKey: bookKey),
      isFalse,
      reason: '缺 audiobooks/srt_books 表时「没有可删原件」，不能抛缺表异常',
    );
  });
}
