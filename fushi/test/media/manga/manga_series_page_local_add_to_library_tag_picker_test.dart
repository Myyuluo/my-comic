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
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart' show TagPickerPanel;
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 05：本地 Manga 作品页「加入书架」前的标签选择。
///
/// 页面级 seam：真实扫描结果 + 真实 Drift DB + 真实偏好库。断言只落在用户可见
/// 行为（弹窗是否出现、文案、完成/取消）与数据库结果上。
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

const ValueKey<String> _addKey = ValueKey<String>(
  'manga_series_add_to_bookshelf',
);
const ValueKey<String> _removeKey = ValueKey<String>(
  'manga_series_remove_from_bookshelf',
);
const ValueKey<String> _doneKey = ValueKey<String>('tag_picker_done');

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('manga_series_local_tag_');
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

  /// 真实文件 IO + 扫描必须在 [WidgetTester.runAsync] 里跑。
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

  Future<void> pumpPage(
    WidgetTester tester,
    _TestAppModel appModel,
    LocalSourceManga manga,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_harness(appModel, manga));
    await pumpUntilFound(tester, find.byKey(_addKey));
  }

  /// 等弹层滑入、标签列表读库完成。
  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('已有 Tag：先弹标签选择，完成才登记并写入所选 Tag', (WidgetTester tester) async {
    late int tagA;
    late int tagB;
    await tester.runAsync(() async {
      tagA = await db.createTag('推理', 0xFF5C6BC0);
      tagB = await db.createTag('百合', 0xFFEC407A);
    });
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await tester.tap(find.byKey(_addKey));
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagA')),
      );
      await settle(tester);
    });

    expect(find.text('标签'), findsOneWidget);
    expect(find.text('1 个条目'), findsOneWidget);
    expect(find.byType(TagPickerPanel), findsOneWidget);
    expect(await db.getEpubBook(bookKey), isNull, reason: '选择阶段不登记');
    expect(await db.getTagsForBook(bookKey), isEmpty, reason: '选择阶段不写 Tag 分配');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagA')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagB')));
      await settle(tester);
    });
    expect(await db.getEpubBook(bookKey), isNull, reason: '选择阶段仍然不写库');
    expect(await db.getTagsForBook(bookKey), isEmpty);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(_doneKey));
      await pumpUntilFound(tester, find.byKey(_removeKey));
    });

    expect(await db.getEpubBook(bookKey), isNotNull, reason: '点完成才登记');
    final List<BookTagRow> tags = await db.getTagsForBook(bookKey);
    expect(tags.map((BookTagRow tag) => tag.id).toSet(), <int>{tagA, tagB});
    expect(
      mangaBookBelongsToTab(tags, const MangaShelfTabSelection()),
      isFalse,
      reason: '带 Tag 的作品不出现在「书架」页签',
    );
    expect(mangaBookBelongsToTab(tags, MangaTagTabSelection(tagA)), isTrue);
    expect(mangaBookBelongsToTab(tags, MangaTagTabSelection(tagB)), isTrue);
  });

  testWidgets('没有任何 Tag：点加入书架直接登记，不弹标签选择', (WidgetTester tester) async {
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await tester.tap(find.byKey(_addKey));
      await pumpUntilFound(tester, find.byKey(_removeKey));
      await settle(tester);
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: '零 Tag 不弹选择器');
    expect(await db.getEpubBook(bookKey), isNotNull);
    expect(await db.getTagsForBook(bookKey), isEmpty);
  });

  testWidgets('零选「完成」：正常登记但不打 Tag，作品留在「书架」页签', (WidgetTester tester) async {
    await tester.runAsync(() => db.createTag('推理', 0xFF5C6BC0));
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await tester.tap(find.byKey(_addKey));
      await pumpUntilFound(tester, find.byKey(_doneKey));
      await settle(tester);
      await tester.tap(find.byKey(_doneKey));
      await pumpUntilFound(tester, find.byKey(_removeKey));
    });

    expect(await db.getEpubBook(bookKey), isNotNull, reason: '零选也正常登记');
    final List<BookTagRow> tags = await db.getTagsForBook(bookKey);
    expect(tags, isEmpty, reason: '零选 = 未打标签');
    expect(
      mangaBookBelongsToTab(tags, const MangaShelfTabSelection()),
      isTrue,
      reason: '未打标签的作品出现在「书架」页签',
    );
  });

  testWidgets('点弹窗外部取消：不登记、不写 Tag 分配', (WidgetTester tester) async {
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await tester.tap(find.byKey(_addKey));
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagId')),
      );
      await settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await settle(tester);
      await tester.tapAt(const Offset(200, 80));
      await settle(tester);
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: '点外部关闭弹窗');
    expect(await db.getEpubBook(bookKey), isNull, reason: '取消本次加入');
    expect(await db.getTagsForBook(bookKey), isEmpty);
    expect(find.byKey(_addKey), findsOneWidget, reason: '仍在未入库态，可重试');
  });

  testWidgets('重新加入已移出书架的本地作品：同样弹选择器并可打 Tag', (WidgetTester tester) async {
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });
    final LocalSourceManga manga = await scannedManga(tester, 'Alpha');
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    await tester.runAsync(() => db.insertBookTombstone(bookKey));
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await tester.tap(find.byKey(_addKey));
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagId')),
      );
      await settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await settle(tester);
      await tester.tap(find.byKey(_doneKey));
      await pumpUntilFound(tester, find.byKey(_removeKey));
    });

    expect(await db.getEpubBook(bookKey), isNotNull, reason: '重新加入墓碑作品');
    expect(
      await db.getBookTombstoneKeys(),
      isNot(contains(bookKey)),
      reason: '显式加入清墓碑',
    );
    expect(
      (await db.getTagsForBook(
        bookKey,
      )).map((BookTagRow tag) => tag.id).toSet(),
      <int>{tagId},
      reason: '重新加入时同样可打 Tag',
    );
  });

  testWidgets('点章节的静默加入：不弹选择器，也不打 Tag', (WidgetTester tester) async {
    await tester.runAsync(() => db.createTag('推理', 0xFF5C6BC0));
    final LocalSourceManga manga = await scannedManga(
      tester,
      'Alpha',
      chapterDirs: <String>['Ch 1', 'Ch 2'],
    );
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final _TestAppModel appModel = _TestAppModel(db, paths, tmp);

    await tester.runAsync(() async {
      await pumpPage(tester, appModel, manga);
      await pumpUntilFound(tester, find.text('Ch 2'));
      await tester.tap(find.text('Ch 2'));
      await pumpUntilFound(tester, find.byKey(_removeKey));
      await settle(tester);
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: '静默加入不弹选择器');
    expect(await db.getEpubBook(bookKey), isNotNull, reason: '点章节仍静默登记');
    final List<BookTagRow> tags = await db.getTagsForBook(bookKey);
    expect(tags, isEmpty, reason: '静默加入保持未打标签');
    expect(
      mangaBookBelongsToTab(tags, const MangaShelfTabSelection()),
      isTrue,
      reason: '静默加入的作品出现在「书架」页签',
    );
    expect(appModel.openedPages, hasLength(1), reason: '登记后立即打开阅读器');
    expect(appModel.openedPages.single.bookKey, bookKey);
    expect(appModel.openedPages.single.initialChapterIndex, 1);
  });
}
