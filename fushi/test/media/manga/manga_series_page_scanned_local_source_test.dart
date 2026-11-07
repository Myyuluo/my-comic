import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 04：未入库本地作品页（第三种 [MangaSeriesTarget] 变体）。
///
/// 展示封面 / 标题 / 章节；「加入书架」才调用单部作品登记入口原地登记；
/// 已入库的作品走正常书架作品页；tombstone 作品照常可见，显式加入会清墓碑；
/// 打开页面本身不登记。
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

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
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
    String title,
  ) async {
    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, title),
    );
    final File page = File(p.join(mangaDir.path, 'Ch 1', '001.jpg'))
      ..createSync(recursive: true);
    page.writeAsBytesSync(<int>[1, 2, 3]);
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
      reason: '原地读取：登记行指向 localcomic 里的作品目录',
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

  testWidgets('未入库作品页点章节不静默登记（自动加入留给 ticket 05）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), manga));
      await _pumpUntil(tester, find.text('Ch 1'));
      await tester.tap(find.text('Ch 1'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });

    expect(
      await db.getAllEpubBooks(),
      isEmpty,
      reason: 'ticket 04 只提供显式「加入书架」；点章节自动加入属于 ticket 05',
    );
  });
}
