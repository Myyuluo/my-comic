import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/pages/implementations/manga_history_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiFloatingChromeBar;
import 'package:fushi/src/utils/components/fushi_icon_button.dart'
    show FushiIconButton;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

import '../helpers/pump_until.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 08 的页面级证据（真实 37 表内存库 + 真实历史页 / 作品页）：
///
/// - 历史页唯一数据源是 `media_open_history`，按 `openedAt` 倒序、每部一条；
/// - 命中 Library 时优先显示 Library 的最新标题 / 封面；
/// - 点击在库卡片进入作品页；已移出书架的在线作品凭快照回到来源作品页；
/// - 来源不可用时给错误提示并保留条目；空态可见；
/// - Local source 用伪源 + 相对路径身份。
class _HistoryTestAppModel extends AppModel {
  _HistoryTestAppModel({
    required FushiDatabase database,
    OnlineMangaLibraryService? online,
  }) : _database = database,
       _online = online,
       super(testPlatformServices());

  final FushiDatabase _database;
  final OnlineMangaLibraryService? _online;

  @override
  FushiDatabase get database => _database;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _online ?? super.onlineMangaLibraryService(runtime);
}

class _FakeHistoryAdapter implements OnlineMangaRuntimeAdapter {
  _FakeHistoryAdapter({this.supported = true});

  final bool supported;
  int refreshCalls = 0;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => supported;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    refreshCalls++;
    return OnlineMangaRefreshResult(
      series: entry.series,
      chapters: entry.chapters,
    );
  }

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async => throw StateError('source unavailable');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async =>
      throw StateError('source unavailable');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47];
}

Widget _harness(AppModel appModel, GlobalKey<NavigatorState> navKey) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: MangaHistoryPage()),
        ),
      ),
    );

MangaHistoryOnlineRef _onlineRef({
  String seriesKey = '/series/fixture',
  String extensionPackage = 'org.example.fixture',
  String sourceId = '1',
}) => MangaHistoryOnlineRef(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: extensionPackage,
  sourceId: sourceId,
  seriesKey: seriesKey,
  raw: <String, Object?>{'url': seriesKey},
);

OnlineMangaLibraryEntry _onlineEntry({
  String seriesKey = '/series/fixture',
  String title = 'Fixture series',
}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: seriesKey,
    title: title,
    raw: <String, Object?>{'url': seriesKey},
  ),
  chapters: const <OnlineMangaChapter>[],
);

Future<void> _insertHistory(
  FushiDatabase db, {
  required String mediaSource,
  required String mediaId,
  required int openedAt,
  required String title,
  MangaHistoryOnlineRef? online,
  String? imageUrl,
  String? bookKey,
  String? localRelativePath,
}) async {
  final MangaHistorySnapshot snapshot = MangaHistorySnapshot(
    title: title,
    imageUrl: imageUrl,
    bookKey: bookKey,
    localRelativePath: localRelativePath,
    online: online,
  );
  await db.upsertMediaOpenHistory(
    MediaOpenHistoryCompanion(
      mediaType: const Value<String>('reader_media_type'),
      mediaSource: Value<String>(mediaSource),
      mediaId: Value<String>(mediaId),
      openedAt: Value<int>(openedAt),
      position: const Value<int>(0),
      duration: const Value<int>(0),
      snapshotJson: Value<String>(jsonEncode(snapshot.toJson())),
    ),
  );
}

Future<EpubBookRow> _insertBook(
  FushiDatabase db,
  Directory dir, {
  required String bookKey,
  required String title,
  String? sourceMetadata,
  String? coverPath,
  String chaptersJson = '[]',
  DateTime? completedAt,
}) async {
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: title,
      epubPath: '',
      extractDir: dir.path,
      chapterCount: 0,
      chaptersJson: chaptersJson,
      importedAt: 1,
      format: const Value<String>('manga'),
      coverPath: Value<String?>(coverPath),
      sourceMetadata: Value<String?>(sourceMetadata),
      completedAt: Value<DateTime?>(completedAt),
    ),
  );
  return (await db.getEpubBook(bookKey))!;
}

/// 有界推帧（真实异步 + 固定帧数）：真实 DB 的 Future 与入场动画都能走完；
/// 页面若停在加载态会快速断言失败，而不是在 `pumpAndSettle` 里等满 10 分钟。
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 30));
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late Directory tmp;
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = Directory.systemTemp.createTempSync('manga_history_page_');
    navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('没有历史时显示空态', (WidgetTester tester) async {
    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('manga_history_empty')),
      findsOneWidget,
    );
    expect(find.text(t.manga_history_empty), findsOneWidget);
    expect(find.byType(ShelfCoverFrame), findsNothing);
  });

  testWidgets('按 openedAt 倒序展示快照，不显示日期分组', (WidgetTester tester) async {
    final MangaHistoryOnlineRef online = _onlineRef();
    final String source = mangaHistoryOnlineSourceKey(_onlineEntry());
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: '/older',
      openedAt: 100,
      title: 'Older work',
      online: online,
    );
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: '/newer',
      openedAt: 200,
      title: 'Newer work',
      online: _onlineRef(seriesKey: '/newer'),
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    expect(find.text('Older work'), findsOneWidget);
    expect(find.text('Newer work'), findsOneWidget);
    expect(find.text(t.manga_history_empty), findsNothing);
    // 网格第一项是最近打开的那部（同一行内 dx 更小）。
    expect(
      tester.getTopLeft(find.text('Newer work')).dx,
      lessThan(tester.getTopLeft(find.text('Older work')).dx),
    );
  });

  testWidgets('命中 Library 时优先显示 Library 的最新标题与封面，且只有一条', (
    WidgetTester tester,
  ) async {
    final OnlineMangaLibraryEntry entry = _onlineEntry(title: 'Old title');
    final File cover = File(p.join(tmp.path, 'cover.jpg'))
      ..writeAsBytesSync(<int>[0xff, 0xd8, 0xff, 0xd9]);
    await _insertBook(
      db,
      tmp,
      bookKey: 'mihon-fixture',
      title: 'Library title',
      sourceMetadata: entry.encode(),
      coverPath: p.basename(cover.path),
    );
    final String source = mangaHistoryOnlineSourceKey(entry);
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: entry.series.key,
      openedAt: 100,
      title: 'Snapshot title',
      online: _onlineRef(),
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    expect(find.text('Library title'), findsOneWidget);
    expect(find.text('Snapshot title'), findsNothing);
    expect(find.byType(ShelfCoverFrame), findsOneWidget);
    final Image coverImage = tester.widget<Image>(
      find.descendant(
        of: find.byType(ShelfCoverFrame),
        matching: find.byType(Image),
      ),
    );
    expect(coverImage.image, isA<FileImage>());
    expect(
      (coverImage.image as FileImage).file.path,
      cover.path,
      reason: '渲染优先用 Library 的本地落盘封面',
    );
  });

  testWidgets('Local source 用伪源 + 相对路径身份，命中 Library 时显示书名', (
    WidgetTester tester,
  ) async {
    const String relativePath = 'Fixture series';
    const LocalSourceMetadata metadata = LocalSourceMetadata(
      relativePath: relativePath,
    );
    await _insertBook(
      db,
      tmp,
      bookKey: 'local-fixture',
      title: 'Local title',
      sourceMetadata: metadata.encode(),
    );
    await _insertHistory(
      db,
      mediaSource: kMangaHistoryLocalSource,
      mediaId: relativePath,
      openedAt: 100,
      title: 'Snapshot local title',
      localRelativePath: relativePath,
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    expect(find.text('Local title'), findsOneWidget);
    expect(find.text('Snapshot local title'), findsNothing);
  });

  testWidgets('点击命中 Library 的卡片进入作品页', (WidgetTester tester) async {
    const String bookKey = 'shelf_manga';
    await _insertBook(db, tmp, bookKey: bookKey, title: 'Shelf Manga');
    await _insertHistory(
      db,
      mediaSource: 'reader_manga',
      mediaId: ReaderFushiSource.mediaIdentifierFor(bookKey),
      openedAt: 100,
      title: 'Shelf Manga',
      bookKey: bookKey,
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);
    await tester.tap(find.text('Shelf Manga'));
    // 真实 DB / 页面加载走真实异步：在 runAsync 里推帧，否则 Future.delayed
    // 会在 fake async 区里等不到推进。
    await tester.runAsync(
      () => pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsOneWidget,
    );
  });

  testWidgets('已移出书架的在线作品：点击回到来源作品页', (WidgetTester tester) async {
    final _FakeHistoryAdapter adapter = _FakeHistoryAdapter();
    final OnlineMangaLibraryService service = OnlineMangaLibraryService(
      database: db,
      rootDirectory: tmp,
      adapter: adapter,
    );
    final MangaHistoryOnlineRef online = _onlineRef();
    await _insertHistory(
      db,
      mediaSource:
          '$kMangaHistoryOnlineSourcePrefix'
          '${jsonEncode(<String>['mihon', 'org.example.fixture', '1'])}',
      mediaId: online.seriesKey,
      openedAt: 100,
      title: 'Removed from shelf',
      online: online,
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db, online: service), navKey),
    );
    await _settle(tester);
    await tester.tap(find.text('Removed from shelf'));
    await tester.runAsync(
      () => pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsOneWidget,
    );
    expect(adapter.refreshCalls, greaterThanOrEqualTo(1));
  });

  testWidgets('来源不可用：点击给错误提示，卡片保留', (WidgetTester tester) async {
    final _FakeHistoryAdapter adapter = _FakeHistoryAdapter(supported: false);
    final OnlineMangaLibraryService service = OnlineMangaLibraryService(
      database: db,
      rootDirectory: tmp,
      adapter: adapter,
    );
    final MangaHistoryOnlineRef online = _onlineRef();
    await _insertHistory(
      db,
      mediaSource:
          '$kMangaHistoryOnlineSourcePrefix'
          '${jsonEncode(<String>['mihon', 'org.example.fixture', '1'])}',
      mediaId: online.seriesKey,
      openedAt: 100,
      title: 'Unavailable source',
      online: online,
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db, online: service), navKey),
    );
    await _settle(tester);
    await tester.tap(find.text('Unavailable source'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(t.manga_series_platform_unsupported), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsNothing,
    );
    expect(find.text('Unavailable source'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('搜索按钮展开页内搜索，实时按书名过滤，收起后恢复完整列表', (WidgetTester tester) async {
    final String source = mangaHistoryOnlineSourceKey(_onlineEntry());
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: '/alpha',
      openedAt: 100,
      title: 'Alpha manga',
      online: _onlineRef(seriesKey: '/alpha'),
    );
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: '/beta',
      openedAt: 200,
      title: 'Beta manga',
      online: _onlineRef(seriesKey: '/beta'),
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    // 右上角动作：搜索 + 全部删除。
    expect(
      find.byKey(const ValueKey<String>('fushi-header-search-button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_history_delete_all')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(FushiFloatingChromeBar),
        matching: find.byType(FushiIconButton),
      ),
      findsNWidgets(2),
      reason: '历史页右上角只有搜索与删除两个按钮',
    );
    expect(find.text('Alpha manga'), findsOneWidget);
    expect(find.text('Beta manga'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('fushi-header-search-button')),
    );
    await _settle(tester);
    final Finder field = find.byKey(
      const ValueKey<String>('manga_history_search_field'),
    );
    expect(field, findsOneWidget);

    tester.testTextInput.enterText('Alpha');
    await _settle(tester);
    expect(find.text('Alpha manga'), findsOneWidget);
    expect(find.text('Beta manga'), findsNothing);

    // 清空搜索词：留在搜索态，恢复完整列表。
    await tester.tap(find.byTooltip(t.clear));
    await _settle(tester);
    expect(find.text('Alpha manga'), findsOneWidget);
    expect(find.text('Beta manga'), findsOneWidget);

    tester.testTextInput.enterText('Beta');
    await _settle(tester);
    expect(find.text('Alpha manga'), findsNothing);
    expect(find.text('Beta manga'), findsOneWidget);

    // 「←」退出搜索：清空搜索词并恢复完整列表。
    await tester.tap(
      find.byTooltip(
        MaterialLocalizations.of(tester.element(field)).backButtonTooltip,
      ),
    );
    await _settle(tester);
    expect(find.text('Alpha manga'), findsOneWidget);
    expect(find.text('Beta manga'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_history_search_field')),
      findsNothing,
    );
  });

  testWidgets('历史页搜索第一次输入不会丢焦点', (WidgetTester tester) async {
    final String source = mangaHistoryOnlineSourceKey(_onlineEntry());
    await _insertHistory(
      db,
      mediaSource: source,
      mediaId: '/alpha',
      openedAt: 100,
      title: 'Alpha manga',
      online: _onlineRef(seriesKey: '/alpha'),
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);
    await tester.tap(
      find.byKey(const ValueKey<String>('fushi-header-search-button')),
    );
    await _settle(tester);

    final Finder field = find.byKey(
      const ValueKey<String>('manga_history_search_field'),
    );
    expect(field, findsOneWidget);
    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '展开搜索后输入框应已聚焦',
    );

    // 模拟 IME 输入第一个字符，不走 tester.enterText 的重新聚焦路径。
    tester.testTextInput.enterText('A');
    await _settle(tester);

    expect(
      tester.widget<TextField>(field).focusNode?.hasFocus,
      isTrue,
      reason: '首次输入后焦点必须保持在搜索框',
    );
    expect(tester.widget<TextField>(field).controller?.text, 'A');
  });

  testWidgets('封面删除按钮立即删除单本历史并提示，阅读数据保留', (WidgetTester tester) async {
    final DateTime completedAt = DateTime(2026, 1, 2);
    final EpubBookRow book = await _insertBook(
      db,
      tmp,
      bookKey: 'shelf_manga',
      title: 'Shelf Manga',
      completedAt: completedAt,
    );
    await db.upsertShelfOrder(MediaKind.epub, book.uid, 0);
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: book.uid,
        sectionIndex: 3,
        normCharOffset: 5,
        updatedAt: 123,
      ),
    );
    await db.saveMangaChapterState(
      bookUid: book.uid,
      chapterKey: 'ch1',
      lastPage: 7,
      readAt: 456,
    );
    final MangaHistoryIdentity identity = mangaHistoryIdentityForBook(book)!;
    await _insertHistory(
      db,
      mediaSource: identity.mediaSource,
      mediaId: identity.mediaId,
      openedAt: 100,
      title: 'Shelf Manga',
      bookKey: book.bookKey,
    );
    await _insertHistory(
      db,
      mediaSource: kMangaHistoryLocalSource,
      mediaId: 'Other',
      openedAt: 90,
      title: 'Other manga',
      localRelativePath: 'Other',
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);
    expect(find.text('Shelf Manga'), findsOneWidget);
    expect(find.text('Other manga'), findsOneWidget);

    await tester.tap(
      find.byKey(ValueKey<String>('manga_history_delete_${identity.key}')),
    );
    await _settle(tester);

    expect(find.text('Shelf Manga'), findsNothing);
    expect(find.text('Other manga'), findsOneWidget);
    expect(find.text(t.manga_history_deleted_entry), findsOneWidget);

    final List<MediaOpenHistoryRow> rows = await db.getAllMediaOpenHistory();
    expect(rows, hasLength(1), reason: '只删除被点的那一条历史');
    expect(
      rows.single.mediaSource == identity.mediaSource &&
          rows.single.mediaId == identity.mediaId,
      isFalse,
    );

    // 删除历史不影响阅读进度、章节 readAt、书级完成标记或书架状态。
    final EpubBookRow? keptBook = await db.getEpubBook(book.bookKey);
    expect(keptBook, isNotNull);
    expect(keptBook!.completedAt, completedAt);
    expect(await db.getReaderPosition(book.uid), isNotNull);
    final MangaChapterStateRow? chapter = await db.getMangaChapterState(
      bookUid: book.uid,
      chapterKey: 'ch1',
    );
    expect(chapter, isNotNull);
    expect(chapter!.readAt, 456);
    expect(await db.getShelfEntry(MediaKind.epub, book.uid), isNotNull);

    // 让 toast 的 2s 计时器走完，避免测试结束时留下 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('全部删除二次确认后清空漫画历史，阅读数据保留', (WidgetTester tester) async {
    final EpubBookRow book = await _insertBook(
      db,
      tmp,
      bookKey: 'shelf_manga',
      title: 'Shelf Manga',
      completedAt: DateTime(2026, 1, 2),
    );
    await db.upsertShelfOrder(MediaKind.epub, book.uid, 0);
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: book.uid,
        sectionIndex: 3,
        normCharOffset: 5,
        updatedAt: 123,
      ),
    );
    await db.saveMangaChapterState(
      bookUid: book.uid,
      chapterKey: 'ch1',
      lastPage: 7,
      readAt: 456,
    );
    final MangaHistoryIdentity identity = mangaHistoryIdentityForBook(book)!;
    await _insertHistory(
      db,
      mediaSource: identity.mediaSource,
      mediaId: identity.mediaId,
      openedAt: 100,
      title: 'Shelf Manga',
      bookKey: book.bookKey,
    );
    await _insertHistory(
      db,
      mediaSource: kMangaHistoryLocalSource,
      mediaId: 'Other',
      openedAt: 90,
      title: 'Other manga',
      localRelativePath: 'Other',
    );
    // 非漫画来源的历史与本次删除无关，必须保留。
    await _insertHistory(
      db,
      mediaSource: 'reader_video',
      mediaId: 'video-1',
      openedAt: 80,
      title: 'Video history',
    );

    await tester.pumpWidget(
      _harness(_HistoryTestAppModel(database: db), navKey),
    );
    await _settle(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_history_delete_all')),
    );
    await _settle(tester);
    expect(find.text(t.manga_history_delete_all_confirm_title), findsOneWidget);

    // 取消不删任何东西。
    await tester.tap(find.text(t.dialog_cancel));
    await _settle(tester);
    expect(await db.getAllMediaOpenHistory(), hasLength(3));

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_history_delete_all')),
    );
    await _settle(tester);
    await tester.tap(find.text(t.manga_history_delete_all_confirm_action));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey<String>('manga_history_empty')),
      findsOneWidget,
    );
    expect(find.text(t.manga_history_deleted_all), findsOneWidget);
    final List<MediaOpenHistoryRow> rows = await db.getAllMediaOpenHistory();
    expect(rows, hasLength(1), reason: '只清空漫画历史');
    expect(rows.single.mediaSource, 'reader_video');

    // 阅读数据保留。
    final EpubBookRow? keptBook = await db.getEpubBook(book.bookKey);
    expect(keptBook, isNotNull);
    expect(keptBook!.completedAt, DateTime(2026, 1, 2));
    expect(await db.getReaderPosition(book.uid), isNotNull);
    final MangaChapterStateRow? chapter = await db.getMangaChapterState(
      bookUid: book.uid,
      chapterKey: 'ch1',
    );
    expect(chapter?.readAt, 456);
    expect(await db.getShelfEntry(MediaKind.epub, book.uid), isNotNull);

    // 让 toast 的 2s 计时器走完，避免测试结束时留下 pending timer。
    await tester.pump(const Duration(seconds: 3));
  });
}
