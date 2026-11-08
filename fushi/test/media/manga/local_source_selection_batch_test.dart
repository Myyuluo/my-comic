import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/local_source/local_source_browse_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 06：本地图源页的选择模式与批量加入 / 移出书架。
///
/// 进入选择走右上角「选择」（清单图标）或鼠标长按卡片；批量栏复用漫画页的
/// [BatchActionBar]（已选 N / 全选 / 反选 + 加入书架 / 移出书架）。加入书架只
/// 登记选中且未入架的作品（含 tombstone，显式加入会清墓碑）；移出书架只删除
/// 书架条目并写 tombstone，**绝不删除 `local` 文件**。全选 / 反选只作用于当前
/// 页签 + 搜索后可见的列表；切换页签立即退出选择。批量操作后退出选择、刷新
/// 书架状态，并用 toast 报告成功 / 失败数量。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

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
  late FushiDatabase db;
  late GlobalKey<NavigatorState> navKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_selection_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
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
      final LocalSourceManga manga =
          (await scanLocalSourceMangaDirectory(
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

  Finder cardFor(Directory dir) => find.byKey(
    ValueKey<String>('local_source_item_${dir.path}'),
  );

  Finder selectToggle() =>
      find.byKey(const ValueKey<String>('local_source_select_toggle'));

  bool selectToggleShowsClose(WidgetTester tester) {
    final FushiIconButton button = tester.widget<FushiIconButton>(
      selectToggle(),
    );
    return button.icon == FushiIcons.close;
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

  bool batchButtonEnabled(WidgetTester tester, String key) => tester
      .widget<FushiIconButton>(find.byKey(ValueKey<String>(key)))
      .enabled;

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

  testWidgets('右上角「选择」进入选择模式、按钮变 X；点 X 退出', (
    WidgetTester tester,
  ) async {
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

  testWidgets('选择模式中按系统返回 / ESC 先退出选择，而不是离开页面', (
    WidgetTester tester,
  ) async {
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
      Directory(p.join(paths.contentRoot.path, 'fushi_books')).existsSync(),
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

  testWidgets('批量移出书架只删条目并写墓碑、保留 local 文件；tombstone 作品可重新加入', (
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

    await runBatchAction(tester, 'local_source_batch_remove');

    expect(
      await db.getAllEpubBooks(),
      isEmpty,
      reason: '只移出已入架的 Alpha；Beta 本来未入架，不受影响',
    );
    expect(await db.getBookTombstoneKeys(), contains(alphaKey));
    expect(
      File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '移出书架只删条目，绝不删除 local 文件',
    );
    expect(
      File(p.join(betaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(selectToggleShowsClose(tester), isFalse, reason: '批量成功后退出选择');
    expect(
      find.text(t.local_source_batch_remove_done(success: 1, failed: 0)),
      findsOneWidget,
    );

    // tombstone 作品算未入架，仍在网格里。
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

    // 显式重新加入墓碑作品：重新登记并清墓碑。
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();
    await runBatchAction(tester, 'local_source_batch_add');

    expect(await db.getEpubBook(alphaKey), isNotNull);
    expect(await db.getBookTombstoneKeys(), isNot(contains(alphaKey)));

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('两个批量动作始终显示；没有适用的选中项时置灰', (
    WidgetTester tester,
  ) async {
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

  testWidgets('全选 / 反选只作用于当前页签 + 搜索后可见的列表', (
    WidgetTester tester,
  ) async {
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
    expect(
      batchBar(tester).selectedCount,
      0,
      reason: '反选同样只在可见集合内取补集',
    );

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

    expect(
      selectToggleShowsClose(tester),
      isFalse,
      reason: '切页签立即退出选择模式',
    );
    expect(find.byType(BatchActionBar), findsNothing);

    await tapSelectToggle(tester);
    expect(
      batchBar(tester).selectedCount,
      0,
      reason: '切换页签清空旧选择，再次进入时从零开始',
    );
  });

  testWidgets('批量移出部分失败：报告失败数量、退出选择且页面不崩', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final String alphaKey = await registerManga(tester, alphaDir);
    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(cardFor(alphaDir));
    await tester.pumpAndSettle();

    // 选中后条目被别处删掉：选择仍在，但 removeFromLibrary 返回 false。
    await tester.runAsync(() async {
      await db.deleteEpubBook(alphaKey);
    });

    await runBatchAction(tester, 'local_source_batch_remove');

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
    expect(
      File(p.join(alphaDir.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );

    await tester.pump(const Duration(seconds: 3));
  });
}
