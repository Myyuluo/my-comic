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
/// 进入即扫描 `local`（原地读取，不复制），封面网格按标题自然排序；
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
  child: TranslationProvider(child: MaterialApp(home: LocalSourceBrowsePage())),
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
    // 后台封面补齐可能在页面销毁后还持有片刻文件句柄（Windows 下删除会报
    // 「另一个程序正在使用」）；给后台任务一点时间收尾，不让临时目录清理
    // 掩盖测试本身的断言结果。
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

  testWidgets('进入页面扫描 local，按标题自然排序（大小写不敏感、数字按数值）', (
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

  testWidgets('独立页头：标题胶囊右侧是「全部 / 未入架 / 已入架」页签，搜索框在标题行下方', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeManga('Alpha');
    writeManga('Beta');

    const ValueKey<String> allTab = ValueKey<String>('local_source_filter_all');
    const ValueKey<String> notInLibraryTab = ValueKey<String>(
      'local_source_filter_not_in_library',
    );
    const ValueKey<String> inLibraryTab = ValueKey<String>(
      'local_source_filter_in_library',
    );
    final Finder searchField = find.byKey(
      const ValueKey<String>('local_source_search_field'),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    // 三个状态页签都在页头，默认「全部」：两部扫描到的作品都显示。
    expect(find.byKey(allTab), findsOneWidget);
    expect(find.byKey(notInLibraryTab), findsOneWidget);
    expect(find.byKey(inLibraryTab), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    // 页签在标题胶囊右侧（同一行），搜索框在标题行下方。
    final Finder title = find.text(t.local_source_title);
    expect(title, findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(allTab)).dx,
      greaterThan(tester.getTopRight(title).dx),
      reason: '页签排在「本地图源」标题胶囊右侧',
    );
    expect(
      tester.getTopLeft(searchField).dy,
      greaterThan(tester.getTopRight(title).dy),
      reason: '搜索框在标题行下方',
    );
  });

  testWidgets('「已入架」只显示书架登记过的作品，「未入架」只显示未登记的', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory alphaDir = writeManga('Alpha');
    writeManga('Beta');

    await tester.runAsync(() async {
      final LocalSourceManga alpha = (await scanLocalSourceMangaDirectory(
        alphaDir,
        relativePath: 'Alpha',
      ))!;
      await LocalSourceLibrary(
        db: db,
        root: paths.localComicRoot,
      ).registerScannedManga(alpha);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    // 默认「全部」：两部都显示。
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_in_library')),
      );
      await tester.pump();
    });
    expect(find.text('Alpha'), findsOneWidget, reason: '已登记的作品出现在「已入架」');
    expect(find.text('Beta'), findsNothing, reason: '未登记的作品不出现在「已入架」');

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          const ValueKey<String>('local_source_filter_not_in_library'),
        ),
      );
      await tester.pump();
    });
    expect(find.text('Alpha'), findsNothing, reason: '已登记的作品不出现在「未入架」');
    expect(find.text('Beta'), findsOneWidget, reason: '未登记的作品出现在「未入架」');

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_all')),
      );
      await tester.pump();
    });
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);
  });

  testWidgets('已移出书架（tombstone）的作品算「未入架」，仍留在网格里', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory alphaDir = writeManga('Alpha');
    final Directory gammaDir = writeManga('Gamma');

    await tester.runAsync(() async {
      final LocalSourceManga alpha = (await scanLocalSourceMangaDirectory(
        alphaDir,
        relativePath: 'Alpha',
      ))!;
      await LocalSourceLibrary(
        db: db,
        root: paths.localComicRoot,
      ).registerScannedManga(alpha);
      // 移出书架后的状态：EpubBooks 行已删、墓碑已立，local 文件仍在。
      await db.insertBookTombstone(localSourceBookKeyFor(gammaDir.path));
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Gamma'));
      await tester.pump();
    });

    // 「全部」里仍显示（墓碑只防扫描自动复活，不是删除文件）。
    expect(find.text('Gamma'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          const ValueKey<String>('local_source_filter_not_in_library'),
        ),
      );
      await tester.pump();
    });
    expect(find.text('Gamma'), findsOneWidget, reason: 'tombstone 作品算「未入架」');

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_in_library')),
      );
      await tester.pump();
    });
    expect(find.text('Gamma'), findsNothing, reason: 'tombstone 作品不算「已入架」');
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('页签筛选与搜索叠加：先按书架状态筛，再按标题搜', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory alphaDir = writeManga('Alpha');
    writeManga('Alpine');

    await tester.runAsync(() async {
      final LocalSourceManga alpha = (await scanLocalSourceMangaDirectory(
        alphaDir,
        relativePath: 'Alpha',
      ))!;
      await LocalSourceLibrary(
        db: db,
        root: paths.localComicRoot,
      ).registerScannedManga(alpha);
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpine'));
      await tester.enterText(
        find.byKey(const ValueKey<String>('local_source_search_field')),
        'alp',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
    });

    // 「全部」+ 搜索：两部标题都含 alp。
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Alpine'), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_in_library')),
      );
      await tester.pump();
    });
    expect(find.text('Alpha'), findsOneWidget, reason: '「已入架」+ 搜索：只留已登记且命中的');
    expect(find.text('Alpine'), findsNothing, reason: '未登记的作品即使命中搜索也被页签筛掉');

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          const ValueKey<String>('local_source_filter_not_in_library'),
        ),
      );
      await tester.pump();
    });
    expect(find.text('Alpha'), findsNothing);
    expect(
      find.text('Alpine'),
      findsOneWidget,
      reason: '「未入架」+ 同一搜索词：只留未登记且命中的',
    );
  });

  testWidgets('过滤后没有结果时复用现有无结果态，而不是「尚未发现任何漫画」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    writeManga('Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      await tester.pump();
    });

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('local_source_filter_in_library')),
      );
      await tester.pump();
    });

    expect(find.text(t.no_search_results), findsOneWidget);
    expect(
      find.text(t.local_source_empty),
      findsNothing,
      reason: '扫描到了作品，只是被页签筛掉——不是「local 里还没有漫画」',
    );
    expect(
      tester
          .widget<FushiPlaceholderMessage>(find.byType(FushiPlaceholderMessage))
          .icon,
      FushiIcons.searchOff,
      reason: '复用现有没有搜索结果态',
    );
    expect(find.byType(FushiFilledButton), findsNothing, reason: '空态不加按钮');
  });

  testWidgets('只扫描更名后的 local；旧 localcomic 不扫描、不删除', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 更名前的旧根：里面仍有用户文件。升级后它既不该被扫描，也不该被删掉。
    final File legacyPage =
        File(
            p.join(
              paths.contentRoot.path,
              'localcomic',
              'Old Manga',
              'Ch 1',
              '001.jpg',
            ),
          )
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[1, 2, 3]);
    writeManga('New Manga');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('New Manga'));
      await tester.pump();
    });

    expect(find.text('New Manga'), findsOneWidget);
    expect(find.text('Old Manga'), findsNothing, reason: '旧 localcomic 不再被扫描');
    expect(paths.localComicRoot.path, p.join(paths.contentRoot.path, 'local'));
    expect(legacyPage.existsSync(), isTrue, reason: '旧 localcomic 不得删除或搬移');
    expect(legacyPage.readAsBytesSync(), <int>[1, 2, 3]);
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

  testWidgets('local 为空时显示「尚未发现任何漫画」空态，不加按钮', (WidgetTester tester) async {
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

  testWidgets('local 读取失败时显示错误提示而不是空白页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // 模拟 Content root 掉线：local 已不存在。
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

  testWidgets('点封面进入未入库作品页：展示标题与章节，可显式加入书架', (WidgetTester tester) async {
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
