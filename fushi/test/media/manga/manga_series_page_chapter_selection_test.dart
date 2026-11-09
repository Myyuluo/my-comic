import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 05（manga-ux-batch）的页面级证据：作品页章节多选与批量已读 / 未读。
///
/// 真实 37 表内存库 + 真实偏好库 + 真实作品页；在线 Source 用可控 fake。
/// 只断言用户可见行为（批量栏、行选中态、按钮可用态）与数据库真实状态。

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
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

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
  }) async {
    opened.add(item);
  }
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

/// 推进弹簧 / 进场动画，直到批量栏收起动画也结束。只用假时钟 pump，
/// 因为手势（长按 / 点击）必须在 `runAsync` 之外、由 fake clock 驱动。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

MediaDetailItemRow _rowWidget(WidgetTester tester, String title) =>
    tester.widget<MediaDetailItemRow>(_chapterRow(title));

const ValueKey<String> _markReadKey = ValueKey<String>(
  'manga_series_batch_mark_read',
);
const ValueKey<String> _markUnreadKey = ValueKey<String>(
  'manga_series_batch_mark_unread',
);

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_selection_');
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

  testWidgets('长按章节进入多选，单击切换选中，取消最后一项退出', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    // 普通模式没有批量栏，行也没有多选标记。
    expect(find.byKey(_markReadKey), findsNothing);
    expect(_rowWidget(tester, 'Chapter 3').selected, isNull);

    // 长按进入多选并选中长按的那一行。
    await tester.longPress(_chapterRow('Chapter 3'));
    await _settle(tester);
    expect(find.byKey(_markReadKey), findsOneWidget);
    expect(find.byKey(_markUnreadKey), findsOneWidget);
    expect(_rowWidget(tester, 'Chapter 3').selected, isTrue);
    expect(_rowWidget(tester, 'Chapter 2').selected, isFalse);
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

    // 多选态内单击切换另一章。
    await tester.tap(_chapterRow('Chapter 2'));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isTrue);
    expect(_rowWidget(tester, 'Chapter 2').selected, isTrue);
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 再点已选中的章节取消它。
    await tester.tap(_chapterRow('Chapter 3'));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isFalse);
    expect(_rowWidget(tester, 'Chapter 2').selected, isTrue);

    // 取消最后一项 = 清空选择，退出多选，批量栏与行标记一起消失。
    await tester.tap(_chapterRow('Chapter 2'));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isNull);
    expect(_rowWidget(tester, 'Chapter 2').selected, isNull);
    expect(find.byKey(_markReadKey), findsNothing);
  });

  testWidgets('全选 / 反选只作用于筛选后可见章节，筛选变化保留可见选中项', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      // Chapter 2 已读：开启「只看未读」后它会从列表消失。
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/2',
        lastPage: 0,
        readAt: 1,
      );
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    await tester.longPress(_chapterRow('Chapter 3'));
    await _settle(tester);

    // 开「只看未读」：已读的 Chapter 2 被筛掉，选中的 Chapter 3 仍然可见且
    // 保持选中。
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_chapter_unread_only')),
    );
    await _settle(tester);
    expect(find.text('Chapter 2'), findsNothing);
    expect(_rowWidget(tester, 'Chapter 3').selected, isTrue);
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

    // 全选：只选中当前可见的 Chapter 3 / Chapter 1，不把被筛掉的 Chapter 2
    // 偷偷算进来。下载筛选 chip 的「全部 / All」也会命中同一文案，故限定在
    // 批量栏内找按钮。
    await tester.tap(
      find.descendant(
        of: find.byType(BatchActionBar),
        matching: find.text(t.batch_select_all),
      ),
    );
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isTrue);
    expect(_rowWidget(tester, 'Chapter 1').selected, isTrue);
    expect(find.text(t.batch_selected_count(n: 2)), findsOneWidget);

    // 反选：可见集内取补集。
    await tester.tap(_chapterRow('Chapter 1'));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 1').selected, isFalse);
    await tester.tap(find.text(t.batch_invert_selection));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 1').selected, isTrue);
    expect(_rowWidget(tester, 'Chapter 3').selected, isFalse);
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);

    // 关掉「只看未读」：Chapter 2 回到列表，但它从未被全选选中；Chapter 1
    // 的选择跨筛选保留。
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_chapter_unread_only')),
    );
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 2').selected, isFalse);
    expect(_rowWidget(tester, 'Chapter 1').selected, isTrue);
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
  });

  testWidgets('点空白处退出多选并清空选择', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    await tester.longPress(_chapterRow('Chapter 3'));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isTrue);

    // 章节区标题是非交互文字：点它 = 点空白处。
    await tester.tap(find.text(t.mihon_chapters_title));
    await _settle(tester);
    expect(_rowWidget(tester, 'Chapter 3').selected, isNull);
    expect(find.byKey(_markReadKey), findsNothing);
  });

  testWidgets('批量已读 / 未读只写章级 readAt，按适用子集执行并置灰', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/2',
        lastPage: 5,
        pageCount: 20,
        readAt: 1,
      );
      // 读了一半的未读章：批量已读不该抹掉章内进度。
      await db.saveMangaChapterState(
        bookUid: row.uid,
        chapterKey: '/chapter/1',
        lastPage: 2,
        pageCount: 10,
      );
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 3'));
    });

    Future<void> waitFor(Future<bool> Function() ready) async {
      await tester.runAsync(() async {
        for (int i = 0; i < 100; i++) {
          if (await ready()) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('等待数据库状态超时');
      });
      await _settle(tester);
    }

    bool enabled(ValueKey<String> key) =>
        tester.widget<FushiIconButton>(find.byKey(key)).enabled;

    Future<MangaChapterStateRow?> stateOf(String chapterKey) =>
        db.getMangaChapterState(bookUid: row.uid, chapterKey: chapterKey);

    // 选两个未读章：已读动作可用，未读动作置灰。
    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    await tester.tap(_chapterRow('Chapter 3'));
    await _settle(tester);
    expect(enabled(_markReadKey), isTrue);
    expect(enabled(_markUnreadKey), isFalse, reason: '全部未读时未读动作置灰');

    // 混合选择（Chapter 1 未读 + Chapter 2 已读）：两个动作都可用，已读只
    // 作用于适用的 Chapter 1。
    await tester.tap(_chapterRow('Chapter 3'));
    await _settle(tester);
    await tester.tap(_chapterRow('Chapter 2'));
    await _settle(tester);
    expect(enabled(_markReadKey), isTrue);
    expect(enabled(_markUnreadKey), isTrue);

    await tester.tap(find.byKey(_markReadKey));
    await waitFor(() async => (await stateOf('/chapter/1'))?.readAt != null);
    expect((await stateOf('/chapter/1'))!.readAt, isNotNull);
    expect(
      (await stateOf('/chapter/2'))!.readAt,
      1,
      reason: '已读项不在已读动作的适用子集里，不该被重写',
    );
    expect(
      (await stateOf('/chapter/3'))?.readAt,
      isNull,
      reason: '未选中的章节不受批量动作影响',
    );
    expect((await stateOf('/chapter/1'))!.lastPage, 2, reason: '章内进度保留');
    expect((await stateOf('/chapter/1'))!.pageCount, 10);
    expect(
      (await db.getEpubBook(row.bookKey))!.completedAt,
      isNull,
      reason: '批量已读不改书级完成标记',
    );

    // 现在选中的两章都已是已读：已读置灰，未读可用；批量未读只清 readAt。
    expect(enabled(_markReadKey), isFalse, reason: '全部已读时已读动作置灰');
    expect(enabled(_markUnreadKey), isTrue);
    await tester.tap(find.byKey(_markUnreadKey));
    await waitFor(() async => (await stateOf('/chapter/1'))?.readAt == null);
    expect((await stateOf('/chapter/1'))!.readAt, isNull);
    expect((await stateOf('/chapter/2'))!.readAt, isNull);
    expect((await stateOf('/chapter/1'))!.lastPage, 2, reason: '取消已读保留进度');
    expect((await stateOf('/chapter/2'))!.lastPage, 5);
    expect(
      (await db.getEpubBook(row.bookKey))!.completedAt,
      isNull,
      reason: '批量未读也不改书级完成标记',
    );
  });
}
