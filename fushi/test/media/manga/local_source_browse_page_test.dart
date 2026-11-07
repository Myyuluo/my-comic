import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/local_source/local_source_browse_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 04：本地图源页面。
///
/// 进入即扫描 `localcomic`（原地读取，不复制），封面网格按标题自然排序；
/// 搜索框在已扫描结果里过滤；空态是书本图标 +「尚未发现任何漫画」，扫描失败
/// 显示错误提示；不显示「热门 / 最新」分段与筛选按钮。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

Widget _harness(AppModel appModel) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: LocalSourceBrowsePage()),
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_browse_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Directory writeManga(String title, {String chapter = 'Ch 1'}) {
    final Directory mangaDir = Directory(p.join(paths.localComicRoot.path, title));
    final File page = File(p.join(mangaDir.path, chapter, '001.jpg'))
      ..createSync(recursive: true);
    page.writeAsBytesSync(<int>[1, 2, 3]);
    return mangaDir;
  }

  testWidgets('进入页面扫描 localcomic，按标题自然排序（大小写不敏感、数字按数值）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeManga('Manga 10');
    writeManga('manga 2');
    writeManga('Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('manga 2'), findsOneWidget);
    expect(find.text('Manga 10'), findsOneWidget);
    // 自然排序：Alpha → manga 2 → Manga 10（网格最小 2 列：前两部同一行，
    // 第三部落到下一行）。
    expect(
      tester.getTopLeft(find.text('Alpha')).dx,
      lessThan(tester.getTopLeft(find.text('manga 2')).dx),
    );
    expect(
      tester.getTopLeft(find.text('manga 2')).dy,
      lessThan(tester.getTopLeft(find.text('Manga 10')).dy),
    );

    // 外壳复用源浏览页：浮动标题胶囊、搜索框；没有热门 / 最新分段与筛选按钮。
    expect(find.text(t.local_source_title), findsWidgets);
    expect(
      find.byKey(const ValueKey<String>('local_source_search_field')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('local_source_listing')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('local_source_filters')),
      findsNothing,
    );
    expect(
      Directory(p.join(paths.contentRoot.path, 'fushi_books')).existsSync(),
      isFalse,
      reason: '扫描原地读取，不把本地漫画复制进受管书库',
    );
  });

  testWidgets('搜索框按标题过滤已扫描结果', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeManga('Alpha');
    writeManga('Beta');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('local_source_search_field')),
        'alp',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('搜索没有命中时显示无结果提示', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeManga('Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('local_source_search_field')),
        'zzz',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _pumpUntil(tester, find.text(t.no_search_results));
    });

    expect(find.text(t.no_search_results), findsOneWidget);
  });

  testWidgets('localcomic 为空时显示「尚未发现任何漫画」空态，不加按钮', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text(t.local_source_empty));
    });

    expect(find.text(t.local_source_empty), findsOneWidget);
    expect(
      tester
          .widget<FushiPlaceholderMessage>(find.byType(FushiPlaceholderMessage))
          .icon,
      FushiIcons.books,
      reason: '空态复用现有占位组件：书本图标 +「尚未发现任何漫画」',
    );
    expect(
      find.byType(FushiFilledButton),
      findsNothing,
      reason: '空态不加按钮（用户逐部点开作品页再加入书架）',
    );
  });

  testWidgets('localcomic 读取失败时显示错误提示而不是空白页', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 模拟 Content root 掉线：localcomic 已不存在。
    paths.localComicRoot.deleteSync(recursive: true);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text(t.local_source_scan_failed));
    });

    expect(find.text(t.local_source_scan_failed), findsOneWidget);
    expect(find.text(t.local_source_empty), findsNothing);
  });

  testWidgets('已入库的作品照常出现在网格；已移出书架（tombstone）的作品也在', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory alphaDir = writeManga('Alpha');
    final Directory betaDir = writeManga('Beta');

    await tester.runAsync(() async {
      final LocalSourceManga alpha = (await scanLocalSourceMangaDirectory(
        alphaDir,
        relativePath: 'Alpha',
      ))!;
      await LocalSourceLibrary(
        db: db,
        root: paths.localComicRoot,
      ).registerScannedManga(alpha);
      await db.insertBookTombstone(localSourceBookKeyFor(betaDir.path));
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    expect(find.text('Alpha'), findsOneWidget, reason: '已在书架的作品照常显示');
    expect(
      find.text('Beta'),
      findsOneWidget,
      reason: '墓碑只防扫描自动复活；作品仍在磁盘上就必须照常出现在本地图源',
    );
    // 网格不查库、不显示「已在书架」角标：两部作品外观一致。
    expect(find.byType(CoverBadge), findsNothing);
  });

  testWidgets('点封面进入未入库作品页：展示标题与章节，可显式加入书架', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory mangaDir = writeManga('Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.tap(
        find.byKey(ValueKey<String>('local_source_item_${mangaDir.path}')),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await tester.pump();
    });

    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey<String>('manga_series_title')),
          )
          .data,
      'Alpha',
    );
    expect(find.text('Ch 1'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
    );
    // 扫描/展示不登记：这部作品仍然不在书架里。
    expect(await db.getAllEpubBooks(), isEmpty);
  });
}
