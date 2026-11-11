import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_engine/media/manga/bookmark_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_reader.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 04：未入库本地作品页（第三种 [MangaSeriesTarget] 变体）。
///
/// 展示封面 / 标题 / 章节；「加入书架」才调用单部作品登记入口原地登记；
/// 已入库的作品走正常书架作品页；tombstone 作品照常可见，显式加入会清墓碑；
/// 打开页面本身不登记。
///
/// Ticket 05：点章节 = 用户显式选择该作品——先静默登记，再按正常书架条目打开
/// 对应章节；文件夹章节与 CBZ 章节都走这条路径，文件缺失时落到阅读器现有失败态。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final AppPaths _paths;

  /// 开阅读器时交出的媒体条目。
  final List<MediaItem?> openedItems = <MediaItem?>[];

  /// 开阅读器时 `launchPageBuilder` 构造出的阅读器页（章下标 / bookKey 在里面）。
  final List<MangaFushiPage> openedPages = <MangaFushiPage>[];

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;

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
    openedItems.add(item);
    final Widget Function()? builder = launchPageBuilder;
    if (builder != null) {
      openedPages.add(
        (builder() as FushiAppUiScaleNeutralizer).child as MangaFushiPage,
      );
    }
  }
}

Widget _harness(AppModel appModel, LocalSourceManga manga) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: MangaSeriesPage(target: LocalSourceMangaSeriesTarget(manga)),
    ),
  ),
);

/// 单独挂载作品页交出的阅读器页：验证缺失章节落到阅读器现有失败态。
Widget _readerHarness(AppModel appModel, MangaFushiPage page) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      builder: (BuildContext context, Widget? child) =>
          child ?? const SizedBox.shrink(),
      home: page,
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

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('manga_series_scanned_local_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 真实文件 IO + 扫描必须在 [WidgetTester.runAsync] 里跑：widget test 的
  /// FakeAsync 相位不会推进真实文件 futures。
  Future<LocalSourceManga> scannedManga(
    WidgetTester tester,
    String title, {
    List<String> chapterDirs = const <String>['Ch 1'],
  }) async {
    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, title),
    );
    for (final String chapter in chapterDirs) {
      final File page = File(p.join(mangaDir.path, chapter, '001.jpg'))
        ..createSync(recursive: true);
      page.writeAsBytesSync(<int>[1, 2, 3]);
    }
    final LocalSourceManga? manga = await tester.runAsync<LocalSourceManga?>(
      () => scanLocalSourceMangaDirectory(mangaDir, relativePath: title),
    );
    return manga!;
  }

  Future<LocalSourceManga> scannedCbzManga(
    WidgetTester tester,
    String title,
  ) async {
    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, title),
    );
    final List<int> pageBytes = img.encodePng(
      img.Image(width: 40, height: 60),
    );
    final Archive archive = Archive()
      ..addFile(ArchiveFile('001.png', pageBytes.length, pageBytes));
    File(p.join(mangaDir.path, 'Ch 1.cbz'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);
    final LocalSourceManga? manga = await tester.runAsync<LocalSourceManga?>(
      () => scanLocalSourceMangaDirectory(mangaDir, relativePath: title),
    );
    return manga!;
  }

  testWidgets('未入库作品页展示标题与章节，打开页面不登记', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), manga));
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
    // 未入库的扫描作品没有可续读的书架条目：不得渲染（禁用的）主按钮。
    expect(
      find.byKey(const ValueKey<String>('manga_series_continue')),
      findsNothing,
      reason: '未入库本地作品不得显示「继续阅读」',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_open_local')),
      findsNothing,
    );
    expect(
      await db.getAllEpubBooks(),
      isEmpty,
      reason: '只展示、不登记：进页本身不得写 Library 行',
    );
  });

  testWidgets('显式「加入书架」按单部作品登记入口原地登记', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), manga));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull, reason: '显式加入后作品必须进书架');
    expect(
      row!.extractDir,
      manga.directoryPath,
      reason: '原地读取：登记行指向 local 里的作品目录',
    );
    expect(
      File(p.join(manga.directoryPath, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '登记不得复制或移动源文件',
    );
  });

  testWidgets('已移出书架（tombstone）的作品可见；显式加入清除墓碑并重新登记', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    await db.insertBookTombstone(bookKey);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), manga));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await tester.pump();
    });
    // 墓碑不影响展示：作品页照常可见，显式加入入口在。
    expect(
      find.byKey(const ValueKey<String>('manga_series_title')),
      findsOneWidget,
    );
    expect(await db.getBookTombstoneKeys(), isNotEmpty);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    expect(await db.getEpubBook(bookKey), isNotNull);
    expect(
      await db.getBookTombstoneKeys(),
      isEmpty,
      reason: '显式「加入书架」必须清除 tombstone，之后扫描不会再跳过它',
    );
  });

  testWidgets('已在书架的作品从本地图源打开时走正常作品页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    await LocalSourceLibrary(
      db: db,
      root: paths.localComicRoot,
    ).registerScannedManga(manga);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), manga));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
      reason: '已在书架 → 正常作品页（可移出书架），而不是未入库页',
    );
  });

  testWidgets('未入库作品页点章节：静默登记后再打开用户点的那一章', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(
      tester,
      'Alpha',
      chapterDirs: <String>['Ch 1', 'Ch 2'],
    );
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(appModel, manga));
      await _pumpUntil(tester, find.text('Ch 2'));
      expect(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
        findsOneWidget,
        reason: '点章之前仍是未入库作品页',
      );

      // 用户点第二章：不需要先按「加入书架」。
      await tester.tap(find.text('Ch 2'));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(
      row,
      isNotNull,
      reason: '点章节 = 用户显式选择该作品，必须先静默登记（进度/历史有书架归属）',
    );
    expect(row!.extractDir, manga.directoryPath, reason: '原地登记，不复制文件');

    expect(appModel.openedPages, hasLength(1), reason: '自动登记后立即打开阅读器');
    final MangaFushiPage reader = appModel.openedPages.single;
    expect(reader.bookKey, bookKey);
    expect(
      reader.initialChapterIndex,
      1,
      reason: '打开的是用户点的那一章（扫描顺序 Ch 1 → Ch 2）',
    );
    expect(
      appModel.openedItems.single,
      isNotNull,
      reason: '自动登记后条目已在库，openMedia 应拿到 MediaItem',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
      reason: '自动登记后按正常书架条目展示',
    );
    expect(
      File(p.join(manga.directoryPath, 'Ch 2', '001.jpg')).existsSync(),
      isTrue,
      reason: '自动登记不得复制或移动源文件',
    );
  });

  testWidgets('未入库作品的 CBZ 章节：点开自动登记，读取走压缩包', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedCbzManga(tester, 'Beta');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(appModel, manga));
      await _pumpUntil(tester, find.text('Ch 1'));
      await tester.tap(find.text('Ch 1'));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    final EpubBookRow? row = await db.getEpubBook(bookKey);
    expect(row, isNotNull, reason: 'CBZ 章节点开同样自动登记');
    expect(
      decodeLocalSourceChapters(row!.chaptersJson).single.relativePath,
      'Ch 1.cbz',
      reason: '登记保留 CBZ 章节载体',
    );
    expect(appModel.openedPages.single.initialChapterIndex, 0);

    // 已登记的 CBZ 条目按 Local source 阅读路径解析：包内页可读、原包不动。
    final LocalSourceResolvedChapter? resolved = await tester
        .runAsync<LocalSourceResolvedChapter?>(
          () => LocalSourceReader.resolveChapter(
            db: db,
            bookKey: bookKey,
            chapterIndex: 0,
            localSourceRoot: paths.localComicRoot,
            downloadsRoot: paths.downloadsRoot,
          ),
        );
    expect(resolved, isNotNull, reason: 'CBZ 章节能被阅读器解析');
    expect(resolved!.isArchive, isTrue);
    expect(resolved.pages, isNotEmpty, reason: 'CBZ 章节可翻页');
    expect(
      File(p.join(manga.directoryPath, 'Ch 1.cbz')).existsSync(),
      isTrue,
      reason: '读取 CBZ 不得删改原包',
    );
  });

  testWidgets('点开已缺失的章节：自动登记不崩溃，阅读器显示现有失败态', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Gamma');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    // 扫描之后章节目录被移走：章节记录还在，文件已经读不到。
    Directory(p.join(manga.directoryPath, 'Ch 1')).deleteSync(recursive: true);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(appModel, manga));
      await _pumpUntil(tester, find.text('Ch 1'));
      await tester.tap(find.text('Ch 1'));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
      await tester.pump();
    });

    expect(tester.takeException(), isNull, reason: '缺失章节不得让作品页崩溃');
    expect(
      await db.getEpubBook(bookKey),
      isNotNull,
      reason: '点章节是显式选择：登记照常发生，阅读失败不撤销登记',
    );
    expect(
      await tester.runAsync<LocalSourceResolvedChapter?>(
        () => LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
          localSourceRoot: paths.localComicRoot,
          downloadsRoot: paths.downloadsRoot,
        ),
      ),
      isNull,
      reason: '读取失败 → 阅读器走现有失败态',
    );

    // 阅读器拿到同一条 bookKey：显示现有「找不到书籍文件」失败态，而不是崩溃。
    await tester.runAsync(() async {
      await tester.pumpWidget(
        _readerHarness(appModel, appModel.openedPages.single),
      );
      await _pumpUntil(tester, find.text(t.book_file_not_found));
      await tester.pump();
    });
    expect(find.text(t.book_file_not_found), findsOneWidget);
  });
}
