import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/manga/history/manga_history.dart';
import 'package:my_comic/src/media/manga/local_source/local_source_browse_page.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/utils/components/batch_action_bar.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic_engine/media/manga/reader_position.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 06 / 03：本地图源页的选择模式与批量加入 / 移出书架。
///
/// 进入选择走右上角「选择」（清单图标）或鼠标长按卡片；批量栏复用漫画页的
/// [BatchActionBar]（已选 N / 全选 / 反选 + 加入书架 / 移出书架）。加入书架只
/// 登记选中且未入架的作品（含 tombstone，显式加入会清墓碑）；移出书架先弹
/// 票 01 的统一确认弹窗，默认只删书架条目并写 tombstone、保留 `local` 原作，
/// 勾选后才删除原作文件 / 阅读统计。全选 / 反选只作用于当前页签 + 搜索后可见
/// 的列表；切换页签立即退出选择。批量操作后退出选择、刷新书架状态，并用 toast
/// 报告成功 / 失败数量。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final MyComicDatabase _db;
  final AppPaths _paths;

  @override
  MyComicDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

Widget _harness(AppModel appModel, GlobalKey<NavigatorState> navigatorKey) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const LocalSourceBrowsePage(),
        ),
      ),
    );

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  late Directory tmp;
  late AppPaths paths;
  late MyComicDatabase db;
  late GlobalKey<NavigatorState> navKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_selection_');
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    navKey = GlobalKey<NavigatorState>();
    MyComicToast.navigatorKey = navKey;
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    // 后台封面补齐可能还持有片刻文件句柄（Windows 下删除会报占用）。
    for (int attempt = 0; attempt < 20 && tmp.existsSync(); attempt++) {
      try {
        tmp.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Directory writeManga(String title, {String chapter = 'Ch 1'}) {
    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, title),
    );
    final File page = File(p.join(mangaDir.path, chapter, '001.jpg'))
      ..createSync(recursive: true);
    page.writeAsBytesSync(<int>[1, 2, 3]);
    return mangaDir;
  }

  Future<String> registerManga(WidgetTester tester, Directory dir) async {
    late String bookKey;
    await tester.runAsync(() async {
      final LocalSourceManga manga = (await scanLocalSourceMangaDirectory(
        dir,
        relativePath: p.basename(dir.path),
      ))!;
      await LocalSourceLibrary(
        db: db,
        root: paths.localComicRoot,
      ).registerScannedManga(manga);
      bookKey = localSourceBookKeyFor(dir.path);
    });
    return bookKey;
  }

  Future<void> tombstone(WidgetTester tester, Directory dir) async {
    await tester.runAsync(() async {
      await db.insertBookTombstone(localSourceBookKeyFor(dir.path));
    });
  }

  Future<void> pumpPage(WidgetTester tester, Finder expected) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths), navKey));
      await _pumpUntil(tester, expected);
      await tester.pump();
    });
  }

  Finder cardFor(Directory dir) =>
      find.byKey(ValueKey<String>('local_source_item_${dir.path}'));

  Finder selectToggle() =>
      find.byKey(const ValueKey<String>('local_source_select_toggle'));

  bool selectToggleShowsClose(WidgetTester tester) {
    final MyComicIconButton button = tester.widget<MyComicIconButton>(
      selectToggle(),
    );
    return button.icon == MyComicIcons.close;
  }

  Future<void> tapSelectToggle(WidgetTester tester) async {
    await tester.tap(selectToggle());
    await tester.pumpAndSettle();
  }

  Future<void> mouseLongPress(WidgetTester tester, Finder finder) async {
    final TestGesture gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await gesture.down(tester.getCenter(finder));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
  }

  BatchActionBar batchBar(WidgetTester tester) =>
      tester.widget<BatchActionBar>(find.byType(BatchActionBar));

  bool batchButtonEnabled(WidgetTester tester, String key) =>
      tester.widget<MyComicIconButton>(find.byKey(ValueKey<String>(key))).enabled;

  Finder batchActionText(String text) => find.descendant(
    of: find.byType(BatchActionBar),
    matching: find.text(text),
  );

  /// 等批量动作的异步落库 / 刷新在 runAsync 真时间里完成，再推 UI 帧。
  Future<void> runBatchAction(WidgetTester tester, String buttonKey) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey<String>(buttonKey)));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 点批量栏「移出书架」并等统一弹窗出现（此时还没有任何删除动作）。
  Future<void> openRemoveDialog(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_batch_remove')),
      );
      await _pumpUntil(tester, find.text(t.dialog_delete));
      await tester.pump();
    });
  }

  /// 在统一弹窗里按需勾选两个选项并确认删除，等批量落库与收尾 toast。
  Future<void> confirmRemoveDialog(
    WidgetTester tester, {
    bool deleteLocalFiles = false,
  }) async {
    if (deleteLocalFiles) {
      await tester.tap(find.text(t.delete_local_files));
      await tester.pump();
    }
    await tester.runAsync(() async {
      await tester.tap(find.text(t.dialog_delete));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// 给作品写一条阅读统计（删除统计的断言对象）。
  Future<void> addStudySegment(String bookKey, String title) async {
    await db.upsertStudySegment(
      StudySegmentsCompanion.insert(
        uid: MyComicDatabase.newStudySegmentUid(),
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

  testWidgets('右上角「选择」进入选择模式、按钮变 X；点 X 退出', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    await pumpPage(tester, cardFor(alphaDir));

    // 未进入选择：清单图标，没有批量栏。
    expect(selectToggle(), findsOneWidget);
    expect(selectToggleShowsClose(tester), isFalse);
    expect(find.byType(BatchActionBar), findsNothing);

    await tapSelectToggle(tester);

    expect(selectToggleShowsClose(tester), isTrue, reason: '选择模式中「选择」变成 X');
    expect(find.byType(BatchActionBar), findsOneWidget);
    expect(find.text(t.batch_selected_count(n: 0)), findsOneWidget);

    await tapSelectToggle(tester);

    expect(selectToggleShowsClose(tester), isFalse);
    expect(
      find.byType(BatchActionBar),
      findsNothing,
      reason: '退出选择后批量栏收起并从树里移除',
    );
  });

  testWidgets('选择模式中按系统返回 / ESC 先退出选择，而不是离开页面', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    expect(find.byType(BatchActionBar), findsOneWidget);

    final bool handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue, reason: '返回事件被选择模式拦截');
    expect(selectToggleShowsClose(tester), isFalse);
    expect(find.byType(BatchActionBar), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('local_source_search_field')),
      findsOneWidget,
      reason: '页面本身还在，返回只退出选择模式',
    );
  });

  testWidgets('鼠标长按卡片进入选择并选中该作品；选择模式单击 / 长按切换；普通单击打开作品页', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    await pumpPage(tester, cardFor(alphaDir));

    await mouseLongPress(tester, cardFor(alphaDir));

    expect(selectToggleShowsClose(tester), isTrue, reason: '长按进入选择模式');
    expect(batchBar(tester).selectedCount, 1);
    final ShelfSelectionCheck alphaCheck = tester.widget<ShelfSelectionCheck>(
      find.descendant(
        of: cardFor(alphaDir),
        matching: find.byType(ShelfSelectionCheck),
      ),
    );
    expect(alphaCheck.selected, isTrue, reason: '长按的那部作品立即被选中');
    final ShelfSelectionCheck betaCheck = tester.widget<ShelfSelectionCheck>(
      find.descendant(
        of: cardFor(betaDir),
        matching: find.byType(ShelfSelectionCheck),
      ),
    );
    expect(betaCheck.selected, isFalse);

    // 选择模式内单击 = 切换选中，不开作品页。
    await tester.tap(cardFor(betaDir));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 2);
    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsNothing,
      reason: '选择模式内单击只切换选中，不打开作品页',
    );

    // 选择模式内长按 = 切换选中（取消 Beta）。
    await mouseLongPress(tester, cardFor(betaDir));
    expect(batchBar(tester).selectedCount, 1);
    expect(
      tester
          .widget<ShelfSelectionCheck>(
            find.descendant(
              of: cardFor(betaDir),
              matching: find.byType(ShelfSelectionCheck),
            ),
          )
          .selected,
      isFalse,
    );

    // 退出选择后普通单击打开作品页。
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.runAsync(() async {
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await tester.pump();
    });
    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsOneWidget,
    );
  });

  testWidgets('批量加入书架只登记选中且未入架的作品（tombstone 清墓碑），成功后退出并刷新', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final Directory gammaDir = writeManga('Gamma');
    final String alphaKey = await registerManga(tester, alphaDir);
    await tombstone(tester, gammaDir);

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 3);
    expect(batchButtonEnabled(tester, 'local_source_batch_add'), isTrue);
    expect(
      batchButtonEnabled(tester, 'local_source_batch_remove'),
      isTrue,
      reason: 'Alpha 已入架，移出动作也应有适用项',
    );

    await runBatchAction(tester, 'local_source_batch_add');

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(
      rows.map((EpubBookRow row) => row.bookKey).toSet(),
      containsAll(<String>[
        alphaKey,
        localSourceBookKeyFor(betaDir.path),
        localSourceBookKeyFor(gammaDir.path),
      ]),
      reason: '加入书架只登记选中且未入架的 Beta / Gamma，Alpha 不重复登记',
    );
    expect(rows, hasLength(3));
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(localSourceBookKeyFor(gammaDir.path))),
      reason: '显式加入书架必须清掉 tombstone',
    );
    expect(
      File(p.join(betaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '加入书架原地登记，不复制 / 移动 local 文件',
    );
    expect(
      Directory(p.join(paths.contentRoot.path, 'my_comic_books')).existsSync(),
      isFalse,
      reason: '不把 local 作品复制进受管书库',
    );

    // 批量成功后退出选择并刷新书架状态。
    expect(selectToggleShowsClose(tester), isFalse);
    expect(
      find.text(t.local_source_batch_add_done(success: 2, failed: 0)),
      findsOneWidget,
      reason: 'toast 报告成功 / 失败数量',
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_in_library')),
      );
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget, reason: '刷新后已入架页签看到新登记的作品');

    await tester.pump(const Duration(seconds: 3)); // 让 toast 计时器跑完
  });

  testWidgets('批量移出书架先显示统一弹窗：数量为适用作品数，默认不勾选；取消无副作用', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String alphaKey = await registerManga(tester, alphaDir);

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 2);

    await openRemoveDialog(tester);

    expect(
      find.text(t.manga_batch_remove_confirm(count: 1)),
      findsOneWidget,
      reason: '数量只算本次会处理的已入架作品；未入架的 Beta 不算',
    );
    expect(find.text(t.manga_series_remove_from_bookshelf), findsOneWidget);
    expect(find.text(t.delete_local_files), findsOneWidget);
    expect(find.text(t.delete_local_files_download_desc), findsOneWidget);
    expect(find.text(t.delete_statistics), findsNothing,
        reason: 'ticket 05：统计删除选项已移除');
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
    expect(
      find.text(t.delete_choices_remember),
      findsNothing,
      reason: '「记住这些选择」已移除',
    );
    expect(
      find.text(t.delete_scope_no_channel),
      findsNothing,
      reason: '同步能力提示已移除',
    );

    // 未勾选任何选项直接取消：不产生任何数据变化。
    await tester.runAsync(() async {
      await tester.tap(find.text(t.dialog_cancel));
      for (int i = 0; i < 10; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });

    expect(await db.getEpubBook(alphaKey), isNotNull, reason: '取消不移出书架');
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(alphaKey)),
      reason: '取消不写墓碑',
    );
    expect(File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(), isTrue);
    expect(File(p.join(betaDir.path, 'Ch 1', '001.jpg')).existsSync(), isTrue);
    expect(selectToggleShowsClose(tester), isTrue, reason: '取消后仍留在选择模式，可以重新操作');
    expect(find.byType(BatchActionBar), findsOneWidget);
  });

  testWidgets('批量移出书架只清 membership、保留 local 文件与行，不写墓碑', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String alphaKey = await registerManga(tester, alphaDir);

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 2);

    await openRemoveDialog(tester);
    // 两个选项保持默认（不勾）：确认后只移出书架，保留 local 文件与行。
    await confirmRemoveDialog(tester);

    final EpubBookRow? alpha = await db.getEpubBook(alphaKey);
    expect(alpha, isNotNull, reason: '移出不删除 Manga 行');
    expect(alpha!.isInLibrary, isFalse, reason: 'membership 清除');
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(alphaKey)),
      reason: '非破坏移出不写墓碑',
    );
    expect(
      File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '未勾选「同时删除本地文件」时保留 local 原作',
    );
    expect(File(p.join(betaDir.path, 'Ch 1', '001.jpg')).existsSync(), isTrue);
    expect(selectToggleShowsClose(tester), isFalse, reason: '批量成功后退出选择');
    expect(
      find.text(t.local_source_batch_remove_done(success: 1, failed: 0)),
      findsOneWidget,
    );

    // 移出后算未入架，仍在网格里。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          const ValueKey<String>('local_source_filter_not_in_library'),
        ),
      );
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    // 显式重新加入：复用同一条非书架记录，只把 membership 翻回 true。
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();
    await runBatchAction(tester, 'local_source_batch_add');

    final EpubBookRow? readded = await db.getEpubBook(alphaKey);
    expect(readded, isNotNull);
    expect(readded!.isInLibrary, isTrue, reason: '显式加入翻回 membership');
    expect(readded.uid, alpha.uid, reason: '重新加入复用同一条记录与 uid');
    expect(
      File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('批量移出勾选「同时删除本地文件」：删原作与进度/已读/标签，History 保留', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String alphaKey = await registerManga(tester, alphaDir);
    final String betaKey = await registerManga(tester, betaDir);
    late EpubBookRow alphaRow;
    late EpubBookRow betaRow;
    await tester.runAsync(() async {
      alphaRow = (await db.getEpubBook(alphaKey))!;
      betaRow = (await db.getEpubBook(betaKey))!;
      for (final EpubBookRow row in <EpubBookRow>[alphaRow, betaRow]) {
        await db.saveMangaChapterState(
          bookUid: row.uid,
          chapterKey: 'Ch 1',
          lastPage: 2,
          readAt: 1,
        );
        await ReaderPositionRepository(
          db,
        ).save(bookUid: row.uid, sectionIndex: 1, normCharOffset: 5);
        final int tagId = await db.getOrCreateTagByName('Tag ${row.title}');
        await db.addTagToBook(row.bookKey, tagId);
        await recordMangaHistoryOpened(db: db, row: row, onlineEntry: null);
      }
      await addStudySegment(alphaKey, 'Alpha');
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    await openRemoveDialog(tester);
    await confirmRemoveDialog(tester, deleteLocalFiles: true);

    expect(await db.getEpubBook(alphaKey), isNull);
    expect(await db.getEpubBook(betaKey), isNull);
    expect(alphaDir.existsSync(), isFalse, reason: '勾选后删除 local 原作文件夹');
    expect(betaDir.existsSync(), isFalse);
    expect(await db.getMangaChapterStates(alphaRow.uid), isEmpty);
    expect(
      await ReaderPositionRepository(db).findByBookUid(alphaRow.uid),
      isNull,
    );
    expect(await db.getTagsForBook(alphaKey), isEmpty);
    expect(await loadMangaHistory(db), hasLength(2), reason: '移出书架不删除 History');
    expect(
      await db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: alphaKey,
      ),
      hasLength(1),
      reason: '未勾选「同时删除统计数据」时统计保留',
    );
    expect(
      find.text(t.local_source_batch_remove_done(success: 2, failed: 0)),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('批量移出：统计删除入口已移除，原作保留', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String alphaKey = await registerManga(tester, alphaDir);
    final String betaKey = await registerManga(tester, betaDir);
    await tester.runAsync(() async {
      await addStudySegment(alphaKey, 'Alpha');
      await addStudySegment(betaKey, 'Beta');
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    await openRemoveDialog(tester);
    await confirmRemoveDialog(tester);

    expect(
      (await db.getEpubBook(alphaKey))?.isInLibrary,
      isFalse,
      reason: '移出只清 membership，不删行',
    );
    expect(
      (await db.getEpubBook(betaKey))?.isInLibrary,
      isFalse,
    );
    expect(
      File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '未勾选「同时删除本地文件」时原作保留',
    );
    expect(File(p.join(betaDir.path, 'Ch 1', '001.jpg')).existsSync(), isTrue);
    for (final String bookKey in <String>[alphaKey, betaKey]) {
      expect(
        await db.getStudySegmentsForMedia(
          mediaKind: kActivityMediaBook,
          mediaKey: bookKey,
        ),
        hasLength(1),
        reason: 'ticket 05：移出书架不再提供统计删除，统计保留',
      );
      final List<StudySegmentTombstoneRow> tombstones = await db
          .getStudySegmentTombstones();
      expect(
        tombstones.where((StudySegmentTombstoneRow t) => t.mediaKey == bookKey),
        isEmpty,
        reason: '统计未删除，不写墓碑',
      );
    }
    expect(
      find.text(t.local_source_batch_remove_done(success: 2, failed: 0)),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('批量移出部分文件删除失败：失败作品留在 Library，其余继续并报告失败数', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String alphaKey = await registerManga(tester, alphaDir);
    final String betaKey = await registerManga(tester, betaDir);
    RandomAccessFile? openFile;
    addTearDown(() {
      openFile?.closeSync();
      openFile = null;
    });
    await tester.runAsync(() async {
      // Windows 上被占用的文件无法随目录递归删除：稳定地制造 Alpha 的文件删除
      // 失败，Beta 仍应正常移出。
      openFile = File(
        p.join(alphaDir.path, 'Ch 1', '001.jpg'),
      ).openSync(mode: FileMode.write);
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    await openRemoveDialog(tester);
    await confirmRemoveDialog(tester, deleteLocalFiles: true);

    expect(
      (await db.getEpubBook(alphaKey))?.isInLibrary,
      isTrue,
      reason: '文件删除失败时该作品必须留在 Library',
    );
    expect(
      await db.getEpubBook(betaKey),
      isNull,
      reason: '本地作品删文件时连行一起删除',
    );
    expect(alphaDir.existsSync(), isTrue);
    expect(betaDir.existsSync(), isFalse);
    expect(await db.getBookTombstoneKeys(), contains(betaKey));
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(alphaKey)),
      reason: '失败作品不写墓碑',
    );
    expect(
      find.text(t.local_source_batch_remove_done(success: 1, failed: 1)),
      findsOneWidget,
      reason: '部分失败报告成功 / 失败数量',
    );
    expect(selectToggleShowsClose(tester), isFalse, reason: '批量结束后退出选择');
    openFile?.closeSync();
    openFile = null;

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('两个批量动作始终显示；没有适用的选中项时置灰', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    await registerManga(tester, alphaDir);
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);

    // 零选中：两个动作都在，但都置灰。
    expect(
      find.byKey(const ValueKey<String>('local_source_batch_add')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('local_source_batch_remove')),
      findsOneWidget,
    );
    expect(batchButtonEnabled(tester, 'local_source_batch_add'), isFalse);
    expect(batchButtonEnabled(tester, 'local_source_batch_remove'), isFalse);

    // 只选已入架的 Alpha：移出可用，加入置灰。
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();
    expect(batchButtonEnabled(tester, 'local_source_batch_add'), isFalse);
    expect(batchButtonEnabled(tester, 'local_source_batch_remove'), isTrue);

    // 混合选择：两个动作都可用。
    await tester.tap(cardFor(betaDir));
    await tester.pumpAndSettle();
    expect(batchButtonEnabled(tester, 'local_source_batch_add'), isTrue);
    expect(batchButtonEnabled(tester, 'local_source_batch_remove'), isTrue);

    // 只选未入架的 Beta：加入可用，移出置灰。
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();
    expect(batchButtonEnabled(tester, 'local_source_batch_add'), isTrue);
    expect(batchButtonEnabled(tester, 'local_source_batch_remove'), isFalse);
  });

  testWidgets('全选 / 反选只作用于当前页签 + 搜索后可见的列表', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    writeManga('Beta');
    writeManga('Gamma');
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);

    await tester.runAsync(() async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('local_source_search_field')),
        'alp',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing, reason: '搜索把 Beta / Gamma 挡住');

    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(
      batchBar(tester).selectedCount,
      1,
      reason: '全选只选可见的 Alpha，不选被搜索隐藏的作品',
    );

    await tester.tap(batchActionText(t.batch_invert_selection));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 0, reason: '反选同样只在可见集合内取补集');

    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 1);

    // 清空搜索：三部都可见，已选的仍只有 Alpha（隐藏项没有被悄悄选中）。
    await tester.runAsync(() async {
      await tester.enterText(
        find.byKey(const ValueKey<String>('local_source_search_field')),
        '',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.text('Beta'), findsOneWidget);
    expect(batchBar(tester).selectedCount, 1);

    await tester.tap(batchActionText(t.batch_invert_selection));
    await tester.pumpAndSettle();
    expect(
      batchBar(tester).selectedCount,
      2,
      reason: '在全部三部的可见集合内反选，只剩 Beta / Gamma',
    );
  });

  testWidgets('切换过滤页签立即退出选择并清空选择', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    writeManga('Beta');
    await registerManga(tester, alphaDir);
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 1);

    await tester.tap(
      find.byKey(const ValueKey<String>('local_source_filter_in_library')),
    );
    await tester.pumpAndSettle();

    expect(selectToggleShowsClose(tester), isFalse, reason: '切页签立即退出选择模式');
    expect(find.byType(BatchActionBar), findsNothing);

    await tapSelectToggle(tester);
    expect(batchBar(tester).selectedCount, 0, reason: '切换页签清空旧选择，再次进入时从零开始');
  });

  testWidgets('批量移出部分失败：报告失败数量、退出选择且页面不崩', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final String alphaKey = await registerManga(tester, alphaDir);
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();

    // 选中后条目被别处删掉：选择仍在，但移出时已找不到书架行。
    await tester.runAsync(() async {
      await db.deleteEpubBook(alphaKey);
    });

    await openRemoveDialog(tester);
    await confirmRemoveDialog(tester);

    expect(
      find.text(t.local_source_batch_remove_done(success: 0, failed: 1)),
      findsOneWidget,
      reason: '失败也如实报告成功 / 失败数量',
    );
    expect(selectToggleShowsClose(tester), isFalse, reason: '失败后同样退出选择');
    expect(
      find.byKey(const ValueKey<String>('local_source_grid')),
      findsOneWidget,
      reason: '部分失败不崩溃，页面照常显示扫描结果',
    );
    expect(File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(), isTrue);

    await tester.pump(const Duration(seconds: 3));
  });

  test('zh-CN 批量移出文案与票面一致', () {
    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(
      t.manga_batch_remove_confirm(count: 3),
      '确定把选中的 3 部作品移出书架？阅读进度、已读标记、已下载章节与 History 会保留。',
    );
  });
}
