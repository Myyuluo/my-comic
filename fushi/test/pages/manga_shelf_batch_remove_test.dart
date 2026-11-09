// 票 02：漫画书架选择模式的批量删除与单卡菜单删除接入票 01 的统一移出弹窗。
//
// 页面级测试：真实 37 表内存库 + 真实偏好库 + 真实书架页；在线下载目录与 Local
// source 根都在临时目录里。只断言用户可见行为（弹窗文案 / 勾选默认值 / toast）
// 与数据库、磁盘的真实结果。
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
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../helpers/test_platform_services.dart';

class _TestAppModel extends AppModel {
  _TestAppModel(this._paths) : super(testPlatformServices());

  final AppPaths _paths;

  @override
  AppPaths get appPaths => _paths;

  @override
  AppPaths? get appPathsOrNull => _paths;
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory pathProviderDir;
  late AppPaths paths;
  late FushiDatabase db;
  late AppModel appModel;
  late List<MediaItem> books;
  late GlobalKey<NavigatorState> navKey;

  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_shelf_batch_remove_pp',
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
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    root = await Directory.systemTemp.createTemp('manga_shelf_batch_remove_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': root.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    appModel = _TestAppModel(paths)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: root);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    books = <MediaItem>[];
    navKey = GlobalKey<NavigatorState>();
    // 让 FushiToast 走桌面 overlay（默认无 navigator key 时是 no-op），
    // 部分失败的「成功 / 失败数量」提示才能在页面上被断言。
    FushiToast.navigatorKey = navKey;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  MediaItem mangaItem(String bookKey, String title) => MediaItem(
        mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
        mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
        position: 0,
        duration: 1,
        canDelete: true,
        canEdit: true,
      );

  /// 在线漫画条目：extractDir 就是 Download library 里的作品目录。
  ///
  /// `sourceMetadata` 带在线作品描述符——`ReaderFushiSource.deleteBook` 靠它把
  /// 这本书认作「在线漫画」（否则会按受管本地卷连文件与 History 一起删）。
  Future<EpubBookRow> seedOnlineManga(
    String bookKey,
    String title, {
    Directory? extractDir,
  }) async {
    final Directory dir = extractDir ??
        Directory(p.join(root.path, 'downloads', title.replaceAll(' ', '_')));
    dir.createSync(recursive: true);
    File(p.join(dir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    final String sourceMetadata = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/$bookKey',
        title: title,
        raw: <String, Object?>{'url': '/series/$bookKey'},
      ),
      chapters: const <OnlineMangaChapter>[],
    ).encode();
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '',
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(sourceMetadata),
      ),
    );
    books.add(mangaItem(bookKey, title));
    return (await db.getEpubBook(bookKey))!;
  }

  /// Local source 条目：原作文件夹住在 `<Content root>/local/<name>`。
  Future<EpubBookRow> seedLocalSourceManga(String name) async {
    final Directory dir = Directory(p.join(paths.localComicRoot.path, name))
      ..createSync(recursive: true);
    final Directory chapterDir = Directory(p.join(dir.path, 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    final String bookKey = localSourceBookKeyFor(dir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: name,
        epubPath: '',
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: encodeLocalSourceChapters(
          <LocalSourceChapterRecord>[
            const LocalSourceChapterRecord(
              key: 'ch1',
              name: 'Ch 1',
              relativePath: 'Ch 1',
            ),
          ],
        ),
        importedAt: 1,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(relativePath: name).encode(),
        ),
      ),
    );
    books.add(mangaItem(bookKey, name));
    return (await db.getEpubBook(bookKey))!;
  }

  /// 受管本地漫画卷：`format='manga'`，但既没有在线作品描述符，也没有 Local
  /// source 元数据（例如导入的漫画卷）。它的 `extractDir` 是应用目录里的副本。
  Future<EpubBookRow> seedManagedManga(String bookKey, String title) async {
    final Directory dir = Directory(
      p.join(root.path, 'managed', title.replaceAll(' ', '_')),
    )..createSync(recursive: true);
    File(p.join(dir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '',
        extractDir: dir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
      ),
    );
    books.add(mangaItem(bookKey, title));
    return (await db.getEpubBook(bookKey))!;
  }

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(
              List<MediaItem>.of(books),
            ),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
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
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Finder bookCard(String bookKey) => find.byKey(
        ValueKey<String>(
          'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
        ),
      );

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(FushiIcons.checklist));
    await tester.pumpAndSettle();
  }

  Future<void> selectBooks(WidgetTester tester, List<String> bookKeys) async {
    await enterSelectionMode(tester);
    for (final String bookKey in bookKeys) {
      await tester.tap(bookCard(bookKey));
      await tester.pumpAndSettle();
    }
  }

  Future<void> openBatchDeleteDialog(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('reader_shelf_batch_delete')),
    );
    await tester.pumpAndSettle();
  }

  /// 反复放真时间 + 推帧，直到 [predicate] 成立（删除带真实文件 IO 与进度弹窗，
  /// FakeAsync 的 pump 送不到）。
  Future<void> pumpUntil(
    WidgetTester tester,
    Future<bool> Function() predicate, {
    int maxTries = 300,
  }) async {
    for (int i = 0; i < maxTries; i++) {
      if (await tester.runAsync(predicate) ?? false) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 轮询直到 [finder] 出现（确认框前的 DB 预取是真实异步）。
  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    int maxTries = 300,
  }) async {
    for (int i = 0; i < maxTries; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 让 toast 的自动消失计时器跑完，避免测试结束时留下 pending timer。
  Future<void> flushToast(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
  }

  Future<void> seedStudySegment(String bookKey, String title) async {
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: FushiDatabase.newStudySegmentUid(),
        deviceId: 'dev-test',
        mediaKind: kActivityMediaBook,
        mediaKey: bookKey,
        title: title,
        startAt: 1000,
        endAt: 61000,
        dateKey: '2026-11-07',
        hour: 10,
        updatedAt: 61000,
      ),
    );
  }

  testWidgets('批量删除使用统一弹窗：标题、选中数量、两个默认不勾选、无披露/记忆/同步', (
    WidgetTester tester,
  ) async {
    const String bookA = 'manga:batch:dialog:a';
    const String bookB = 'manga:batch:dialog:b';
    await seedOnlineManga(bookA, 'Batch Dialog A');
    await seedOnlineManga(bookB, 'Batch Dialog B');

    await pumpPage(tester);
    await selectBooks(tester, <String>[bookA, bookB]);
    await openBatchDeleteDialog(tester);

    expect(
      find.text(t.manga_series_remove_from_bookshelf),
      findsOneWidget,
      reason: '批量删除必须使用票 01 的统一弹窗标题',
    );
    expect(
      find.text(t.manga_series_remove_confirm_batch(n: 2)),
      findsOneWidget,
      reason: '批量说明必须包含选中的作品数量',
    );
    final DeleteLocalFilesRow localFilesRow =
        tester.widget<DeleteLocalFilesRow>(
      find.byKey(
        const ValueKey<String>(
          'manga_remove_dialog_delete_local_files',
        ),
      ),
    );
    final DeleteStatisticsRow statisticsRow =
        tester.widget<DeleteStatisticsRow>(
      find.byKey(
        const ValueKey<String>(
          'manga_remove_dialog_delete_statistics',
        ),
      ),
    );
    expect(localFilesRow.value, isFalse, reason: '「同时删除本地文件」默认不勾选');
    expect(statisticsRow.value, isFalse, reason: '「同时删除统计数据」默认不勾选');

    expect(
      find.text(t.delete_disclosure_will_delete_label),
      findsNothing,
      reason: '粉色披露块已移除',
    );
    expect(
      find.text(t.delete_disclosure_will_keep_label),
      findsNothing,
      reason: '蓝色披露块已移除',
    );
    expect(find.text(t.delete_choices_remember), findsNothing, reason: '「记住这些选择」已移除');
    expect(
      find.text(t.delete_scope_sync_everywhere),
      findsNothing,
      reason: '同步范围选项不再出现',
    );
    expect(find.text(t.delete_scope_no_channel), findsNothing, reason: '同步能力提示不再出现');

    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(await db.getEpubBook(bookA), isNotNull, reason: '取消不删除任何作品');
    expect(await db.getEpubBook(bookB), isNotNull);
  });

  testWidgets('批量移出默认只移出书架：进度/已读/标签删除，History、文件与统计保留，排队任务停止', (
    WidgetTester tester,
  ) async {
    const String bookKey = 'manga:batch:defaults';
    final EpubBookRow row = await seedOnlineManga(bookKey, 'Defaults Manga');
    final Directory chapterDir = Directory(p.join(row.extractDir, 'Chapter 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
      folderName: 'Chapter 1',
      updatedAt: 1,
    );
    await db.saveMangaChapterState(
      bookUid: row.uid,
      chapterKey: '/chapter/1',
      lastPage: 3,
      readAt: 1,
    );
    await ReaderPositionRepository(db).save(
      bookUid: row.uid,
      sectionIndex: 1,
      normCharOffset: 20,
    );
    final int tagId = await db.getOrCreateTagByName('Tag A');
    await db.addTagToBook(bookKey, tagId);
    await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);
    await seedStudySegment(bookKey, row.title);
    const String jobId = 'job-defaults';
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: jobId,
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: '/chapter/1',
        runtime: 'mihon',
        title: row.title,
        chapterTitle: 'Chapter 1',
        status: const Value<String>(MangaDownloadJobStatus.queued),
        createdAt: 1,
        updatedAt: 1,
      ),
    );

    await pumpPage(tester);
    // 带 Tag 的漫画只出现在对应标签页签，不在「书架」页签：先切到该标签。
    final Finder tagTab = find.byKey(
      ValueKey<String>('manga_tag_tab_$tagId'),
    );
    await pumpUntilFound(tester, tagTab);
    await tester.tap(tagTab);
    await tester.pumpAndSettle();
    expect(bookCard(bookKey), findsOneWidget, reason: '标签页签下能看到这部漫画');
    await selectBooks(tester, <String>[bookKey]);
    await openBatchDeleteDialog(tester);
    await tester.tap(find.text(t.dialog_delete));
    await pumpUntil(tester, () async => await db.getEpubBook(bookKey) == null);

    expect(await db.getEpubBook(bookKey), isNull, reason: 'Library 条目已删');
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
      await db.getTagsForBook(bookKey),
      isEmpty,
      reason: 'Tag 分配随移出删除',
    );
    expect(
      await loadMangaHistory(db),
      hasLength(1),
      reason: 'History 不随移出删除',
    );
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: bookKey,
      ),
      hasLength(1),
      reason: '未勾选「同时删除统计数据」时统计保留',
    );
    expect(
      chapterDir.existsSync(),
      isTrue,
      reason: '未勾选「同时删除本地文件」时已下载章节保留',
    );
    expect(
      await db.getMangaDownloadJob(jobId),
      isNull,
      reason: '在线 Manga 的排队任务必须在移出前停止并取消',
    );
    await flushToast(tester);
  });

  testWidgets('单卡长按菜单删除使用统一弹窗并移出书架', (WidgetTester tester) async {
    const String bookKey = 'manga:batch:single';
    final EpubBookRow row = await seedOnlineManga(bookKey, 'Single Card Manga');
    final Directory chapterDir = Directory(p.join(row.extractDir, 'Chapter 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);
    await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);

    await pumpPage(tester);
    await tester.longPress(bookCard(bookKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_delete));
    await pumpUntilFound(
      tester,
      find.text(t.manga_series_remove_from_bookshelf),
    );

    expect(
      find.text(t.manga_series_remove_from_bookshelf),
      findsOneWidget,
      reason: '单卡删除必须使用统一弹窗标题',
    );
    expect(
      find.text(t.manga_series_remove_confirm),
      findsOneWidget,
      reason: '单卡删除使用单本说明',
    );
    expect(
      tester
          .widget<DeleteLocalFilesRow>(
            find.byKey(
              const ValueKey<String>(
                'manga_remove_dialog_delete_local_files',
              ),
            ),
          )
          .value,
      isFalse,
      reason: '「同时删除本地文件」默认不勾选',
    );

    // 菜单项的 DELETE 与弹窗按钮同文案；弹窗在最上层，取最后一个。
    await tester.tap(find.text(t.dialog_delete).last);
    await pumpUntil(tester, () async => await db.getEpubBook(bookKey) == null);

    expect(await db.getEpubBook(bookKey), isNull);
    expect(chapterDir.existsSync(), isTrue, reason: '默认不删已下载章节');
    expect(await loadMangaHistory(db), hasLength(1), reason: 'History 保留');
    await flushToast(tester);
  });

  testWidgets('混合选择：同时删除本地文件与统计数据按作品类型分别处理', (
    WidgetTester tester,
  ) async {
    const String onlineKey = 'manga:batch:mixed:online';
    final EpubBookRow onlineRow =
        await seedOnlineManga(onlineKey, 'Mixed Online');
    final Directory localDir = Directory(
      p.join(paths.localComicRoot.path, 'Mixed Local'),
    )..createSync(recursive: true);
    final EpubBookRow localRow = await seedLocalSourceManga('Mixed Local');
    await recordMangaHistoryOpened(
      db: db,
      row: onlineRow,
      onlineEntry: null,
    );
    await recordMangaHistoryOpened(db: db, row: localRow, onlineEntry: null);
    await seedStudySegment(onlineKey, onlineRow.title);
    await seedStudySegment(localRow.bookKey, localRow.title);

    await pumpPage(tester);
    await selectBooks(tester, <String>[onlineKey, localRow.bookKey]);
    await openBatchDeleteDialog(tester);
    await tester.tap(find.text(t.delete_local_files));
    await tester.pump();
    await tester.tap(find.text(t.delete_statistics));
    await tester.pump();
    await tester.tap(find.text(t.dialog_delete));
    await pumpUntil(
      tester,
      () async => await db.getEpubBook(onlineKey) == null,
    );
    await pumpUntil(
      tester,
      () async => await db.getEpubBook(localRow.bookKey) == null,
    );

    expect(await db.getEpubBook(onlineKey), isNull);
    expect(await db.getEpubBook(localRow.bookKey), isNull);
    expect(
      Directory(onlineRow.extractDir).existsSync(),
      isFalse,
      reason: '在线 Manga 的已下载章节文件被删除',
    );
    expect(localDir.existsSync(), isFalse, reason: 'Local source 原作文件夹被删除');
    for (final String mediaKey in <String>[onlineKey, localRow.bookKey]) {
      expect(
        await db.getStudySegmentsForMedia(
          mediaKind: kActivityMediaBook,
          mediaKey: mediaKey,
        ),
        isEmpty,
        reason: '统计数据删除应用于所有选中作品',
      );
    }
    expect(
      await loadMangaHistory(db),
      hasLength(2),
      reason: '批量移出保留全部 History',
    );
    await flushToast(tester);
  });

  testWidgets('部分文件删除失败：失败作品留在 Library，成功作品移出并报告失败数量', (
    WidgetTester tester,
  ) async {
    const String onlineKey = 'manga:batch:partial:online';
    final EpubBookRow onlineRow =
        await seedOnlineManga(onlineKey, 'Partial Online');
    // 一条 Local source 行但原作目录在 local root 之外：确定性触发「文件删除失败」。
    final Directory outsideDir = Directory(
      p.join(root.path, 'outside-local', 'Partial Local'),
    )..createSync(recursive: true);
    File(p.join(outsideDir.path, '001.jpg')).writeAsBytesSync(<int>[1]);
    final String localKey = localSourceBookKeyFor(outsideDir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: localKey,
        title: 'Partial Local',
        epubPath: '',
        extractDir: outsideDir.path,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(relativePath: 'Partial Local').encode(),
        ),
      ),
    );
    books.add(mangaItem(localKey, 'Partial Local'));

    await pumpPage(tester);
    await selectBooks(tester, <String>[onlineKey, localKey]);
    await openBatchDeleteDialog(tester);
    await tester.tap(find.text(t.delete_local_files));
    await tester.pump();
    await tester.tap(find.text(t.dialog_delete));
    final String summary =
        t.local_source_batch_remove_done(success: 1, failed: 1);
    await pumpUntilFound(tester, find.text(summary));

    expect(await db.getEpubBook(onlineKey), isNull, reason: '成功作品已移出');
    expect(
      await db.getEpubBook(localKey),
      isNotNull,
      reason: '文件删除失败的作品必须留在 Library',
    );
    expect(
      Directory(onlineRow.extractDir).existsSync(),
      isFalse,
      reason: '成功作品的文件已删除',
    );
    expect(
      outsideDir.existsSync(),
      isTrue,
      reason: '失败作品的 Local source 原作未被删除',
    );
    expect(
      find.text(summary),
      findsOneWidget,
      reason: '部分成功时结果必须同时报告成功与失败数量',
    );
    await flushToast(tester);
  });

  testWidgets(
    '受管漫画卷默认移出：不删应用文件、不删 History',
    (WidgetTester tester) async {
      const String bookKey = 'manga:managed:defaults';
      final EpubBookRow row = await seedManagedManga(bookKey, 'Managed Defaults');
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);

      await pumpPage(tester);
      await selectBooks(tester, <String>[bookKey]);
      await openBatchDeleteDialog(tester);
      // 两个选项都保持默认（不勾选）。
      await tester.tap(find.text(t.dialog_delete));
      await pumpUntil(
        tester,
        () async => await db.getEpubBook(bookKey) == null,
      );

      expect(await db.getEpubBook(bookKey), isNull, reason: 'Library 条目已删');
      expect(
        Directory(row.extractDir).existsSync(),
        isTrue,
        reason: '未勾选「同时删除本地文件」时受管漫画卷的应用文件必须保留',
      );
      expect(
        await loadMangaHistory(db),
        hasLength(1),
        reason: '移出书架不删除 History（受管漫画卷也一样）',
      );
      await flushToast(tester);
    },
  );

  testWidgets(
    '受管漫画卷勾选「同时删除本地文件」：删除应用文件但保留 History',
    (WidgetTester tester) async {
      const String bookKey = 'manga:managed:delete-files';
      final EpubBookRow row =
          await seedManagedManga(bookKey, 'Managed Delete Files');
      await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);

      await pumpPage(tester);
      await selectBooks(tester, <String>[bookKey]);
      await openBatchDeleteDialog(tester);
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
      await tester.tap(find.text(t.dialog_delete));
      await pumpUntil(
        tester,
        () async => await db.getEpubBook(bookKey) == null,
      );

      expect(await db.getEpubBook(bookKey), isNull);
      expect(
        Directory(row.extractDir).existsSync(),
        isFalse,
        reason: '勾选后受管漫画卷的应用文件删除',
      );
      expect(
        await loadMangaHistory(db),
        hasLength(1),
        reason: '即使删了文件，History 也保留',
      );
      await flushToast(tester);
    },
  );

  testWidgets('被筛选隐藏的选中项继续提示且不参与删除', (WidgetTester tester) async {
    const String visibleKey = 'manga:batch:hidden:visible';
    const String hiddenKey = 'manga:batch:hidden:hidden';
    await seedOnlineManga(visibleKey, 'Visible Anchor');
    await seedOnlineManga(hiddenKey, 'Hidden Other');

    await pumpPage(tester);
    await selectBooks(tester, <String>[visibleKey, hiddenKey]);

    // 选择完成后再用搜索把其中一本藏起来：选中集保留不可见项，确认框必须提示。
    final Finder field = find.byKey(
      const ValueKey<String>('shelf_search_field'),
    );
    if (field.evaluate().isEmpty) {
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi-header-search-button')),
      );
      await tester.pumpAndSettle();
    }
    await tester.enterText(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      'Visible Anchor',
    );
    await tester.pumpAndSettle();
    expect(bookCard(hiddenKey), findsNothing, reason: '前置：隐藏项已被搜索挡掉');

    await openBatchDeleteDialog(tester);
    expect(
      find.textContaining(t.manga_series_remove_confirm_batch(n: 1)),
      findsOneWidget,
      reason: '确认框的数量只数本次会处理的可见项',
    );
    expect(
      find.textContaining(t.batch_hidden_by_filter_note(n: 1)),
      findsOneWidget,
      reason: '被筛选隐藏的选中项必须继续提示',
    );

    await tester.tap(find.text(t.dialog_delete));
    await pumpUntil(
      tester,
      () async => await db.getEpubBook(visibleKey) == null,
    );

    expect(await db.getEpubBook(visibleKey), isNull, reason: '可见项被删除');
    expect(
      await db.getEpubBook(hiddenKey),
      isNotNull,
      reason: '被筛选隐藏的选中项不参与本次删除',
    );
    await flushToast(tester);
  });
}
