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
import 'package:fushi/src/media/tags/tag_picker_sheet.dart' show TagPickerPanel;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 05：本地图源页批量「加入书架」前的标签选择。
///
/// 页面级 seam：真实扫描结果 + 真实 Drift DB + 真实偏好库。批量只弹一次选择器，
/// 副标题是本批要加入的作品数量；所选 Tag 应用到本批所有新加入的作品，已在
/// Library 的作品不重新加入、不应用 Tag；关闭弹窗取消整批加入。
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

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;
  late GlobalKey<NavigatorState> navKey;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_batch_tag_');
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
      await pumpUntilFound(tester, expected);
      await tester.pump();
    });
  }

  Finder cardFor(Directory dir) =>
      find.byKey(ValueKey<String>('local_source_item_${dir.path}'));

  Finder selectToggle() =>
      find.byKey(const ValueKey<String>('local_source_select_toggle'));

  Future<void> tapSelectToggle(WidgetTester tester) async {
    await tester.tap(selectToggle());
    await tester.pumpAndSettle();
  }

  bool selectToggleShowsClose(WidgetTester tester) {
    final FushiIconButton button = tester.widget<FushiIconButton>(
      selectToggle(),
    );
    return button.icon == FushiIcons.close;
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

  Finder batchActionText(String text) => find.descendant(
    of: find.byType(BatchActionBar),
    matching: find.text(text),
  );

  /// 点批量「加入书架」并等选择器出现。
  Future<void> openBatchAddPicker(
    WidgetTester tester, {
    required int tagId,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_batch_add')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagId')),
      );
      await tester.pump();
    });
  }

  Future<void> tapPickerChipAndDone(WidgetTester tester, int tagId) async {
    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
      await tester.pump();
    });
  }

  /// 等批量动作的异步落库 / 刷新在 runAsync 真时间里完成，再推 UI 帧。
  Future<void> settleBatch(WidgetTester tester, String expectedToast) async {
    await tester.runAsync(() async {
      await pumpUntilFound(tester, find.text(expectedToast));
      await tester.pump();
    });
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('已入架作品不受本次 Tag 影响；所选 Tag 应用到本批所有新加入作品', (
    WidgetTester tester,
  ) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final Directory gammaDir = writeManga('Gamma');
    final String alphaKey = await registerManga(tester, alphaDir);
    late int tagA;
    late int tagB;
    await tester.runAsync(() async {
      tagA = await db.createTag('推理', 0xFF5C6BC0);
      tagB = await db.createTag('百合', 0xFFEC407A);
      // Alpha 已在 Library 且已有自己的 Tag：本次批量加入不得改动它。
      await db.addTagToBook(alphaKey, tagB);
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    expect(batchBar(tester).selectedCount, 3);

    await openBatchAddPicker(tester, tagId: tagA);

    // 只弹一次；副标题是本批要加入的作品数量（Alpha 已入架，不在本批）。
    expect(find.byType(TagPickerPanel), findsOneWidget);
    expect(find.text('2 个条目'), findsOneWidget);

    await tapPickerChipAndDone(tester, tagA);
    await settleBatch(
      tester,
      t.local_source_batch_add_done(success: 2, failed: 0),
    );

    final Set<String> keys = (await db.getAllEpubBooks())
        .map((EpubBookRow row) => row.bookKey)
        .toSet();
    expect(keys, <String>{
      alphaKey,
      localSourceBookKeyFor(betaDir.path),
      localSourceBookKeyFor(gammaDir.path),
    });
    expect(
      (await db.getTagsForBook(
        alphaKey,
      )).map((BookTagRow tag) => tag.id).toSet(),
      <int>{tagB},
      reason: '已在 Library 的作品不应用本次 Tag',
    );
    for (final Directory dir in <Directory>[betaDir, gammaDir]) {
      expect(
        (await db.getTagsForBook(
          localSourceBookKeyFor(dir.path),
        )).map((BookTagRow tag) => tag.id).toSet(),
        <int>{tagA},
        reason: '同一组 Tag 应用到本批所有新加入作品',
      );
    }
    expect(selectToggleShowsClose(tester), isFalse, reason: '批量成功后退出选择模式');

    await tester.pump(const Duration(seconds: 3)); // 让 toast 计时器跑完
  });

  testWidgets('没有任何 Tag：批量加入直接登记，不弹标签选择', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_batch_add')),
      );
      await pumpUntilFound(
        tester,
        find.text(t.local_source_batch_add_done(success: 2, failed: 0)),
      );
      await tester.pump();
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: '零 Tag 不弹选择器');
    final Set<String> keys = (await db.getAllEpubBooks())
        .map((EpubBookRow row) => row.bookKey)
        .toSet();
    expect(keys, <String>{
      localSourceBookKeyFor(alphaDir.path),
      localSourceBookKeyFor(betaDir.path),
    });
    for (final String key in keys) {
      expect(await db.getTagsForBook(key), isEmpty);
    }

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('关闭选择器取消整批加入：不创建条目、不写 Tag 分配', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    await openBatchAddPicker(tester, tagId: tagId);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await tester.pump();
      // 宽屏是居中弹层：点弹层外部即取消。
      await tester.tapAt(const Offset(20, 20));
      await tester.pump();
    });
    await tester.pumpAndSettle();

    expect(find.byType(TagPickerPanel), findsNothing, reason: '点外部关闭选择器');
    expect(await db.getAllEpubBooks(), isEmpty, reason: '取消整批加入，不登记');
    expect(
      await db.getTagsForBook(localSourceBookKeyFor(alphaDir.path)),
      isEmpty,
    );
    expect(
      await db.getTagsForBook(localSourceBookKeyFor(betaDir.path)),
      isEmpty,
    );
    expect(
      find.byType(BatchActionBar),
      findsOneWidget,
      reason: '取消后仍停留在选择模式，选中的作品没有被清掉',
    );
    expect(batchBar(tester).selectedCount, 2);
  });

  testWidgets('零选「完成」：正常登记但不打 Tag', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await tester.tap(batchActionText(t.batch_select_all));
    await tester.pumpAndSettle();
    await openBatchAddPicker(tester, tagId: tagId);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
      await pumpUntilFound(
        tester,
        find.text(t.local_source_batch_add_done(success: 2, failed: 0)),
      );
      await tester.pump();
    });

    for (final Directory dir in <Directory>[alphaDir, betaDir]) {
      final String key = localSourceBookKeyFor(dir.path);
      expect(await db.getEpubBook(key), isNotNull, reason: '零选也正常入架');
      expect(await db.getTagsForBook(key), isEmpty, reason: '零选 = 未打标签');
    }

    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('重新加入已移出书架的本地作品：同样弹选择器、清墓碑并写 Tag', (WidgetTester tester) async {
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');
    final String betaKey = localSourceBookKeyFor(betaDir.path);
    await tombstone(tester, betaDir);
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });

    await pumpPage(tester, cardFor(alphaDir));
    await tapSelectToggle(tester);
    await mouseLongPress(tester, cardFor(betaDir));
    expect(batchBar(tester).selectedCount, 1);

    await openBatchAddPicker(tester, tagId: tagId);
    expect(find.text('1 个条目'), findsOneWidget, reason: '本批只有墓碑作品 Beta');

    await tapPickerChipAndDone(tester, tagId);
    await settleBatch(
      tester,
      t.local_source_batch_add_done(success: 1, failed: 0),
    );

    expect(await db.getEpubBook(betaKey), isNotNull, reason: '重新加入墓碑作品');
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(betaKey)),
      reason: '显式加入清墓碑',
    );
    expect(
      (await db.getTagsForBook(
        betaKey,
      )).map((BookTagRow tag) => tag.id).toSet(),
      <int>{tagId},
      reason: '重新加入时同样可打 Tag',
    );

    await tester.pump(const Duration(seconds: 3));
  });
}
