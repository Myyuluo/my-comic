import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_tag_tabs.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart' show TagPickerPanel;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 04：在线 Manga 作品页「加入书架」前的标签选择。
///
/// 页面级 seam：真实 Drift DB + 可控 adapter（只负责来源标签/刷新）+ 真实偏好库。
/// 断言只落在用户可见行为（弹窗是否出现、文案、完成/取消）与数据库结果上。
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
  Future<List<int>> fetchCover(OnlineMangaLibraryEntry entry, String url) =>
      throw StateError('the fixture entry has no cover URL');
}

/// 加入书架写入失败：页面必须留在未入库态，且不写任何 Tag 分配。
class _FailingAddLibraryService extends OnlineMangaLibraryService {
  _FailingAddLibraryService({
    required super.database,
    required super.rootDirectory,
    required super.adapter,
    super.downloadsRootDirectory,
  });

  @override
  Future<EpubBookRow> add(OnlineMangaLibraryEntry entry) async {
    throw StateError('add failed');
  }
}

/// 模拟「打开作品页时还没有任何 Manga 行」：显式加入书架必须回落到创建
/// Library 行的路径（票 03 的无行分支）。
class _NoRowService extends OnlineMangaLibraryService {
  _NoRowService({
    required super.database,
    required super.rootDirectory,
    required super.adapter,
    super.downloadsRootDirectory,
  });

  @override
  Future<EpubBookRow?> find(OnlineMangaLibraryEntry entry) async => null;

  @override
  Future<EpubBookRow> ensureNonLibrary(OnlineMangaLibraryEntry entry) async {
    throw StateError('no row seeded for this fixture');
  }
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
  }) async {}
}

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
);

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
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

/// 等页面首屏与所有后台尾活（刷新、下载状态、来源名解析）落定。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late _TestAppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    root = await Directory.systemTemp.createTemp('manga_series_add_tag_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    TestWidgetsFlutterBinding.ensureInitialized();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
    );
    appModel = _TestAppModel(db, library, root);
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    OnlineMangaLibraryService? service,
  }) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        appModel,
        SourceMangaSeriesTarget(
          adapter: adapter,
          seed: _entry(),
          service: service ?? library,
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
    );
  }

  testWidgets('已有 Tag：打开页有非书架行，完成选择后翻转同一行并写入所选 Tag', (
    WidgetTester tester,
  ) async {
    late int tagA;
    late int tagB;
    await tester.runAsync(() async {
      tagA = await db.createTag('推理', 0xFF5C6BC0);
      tagB = await db.createTag('百合', 0xFFEC407A);
    });
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse, reason: '打开作品页只创建非书架行');
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      // 等到弹层滑入、标签列表读库完成后再点 chip。
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagA')),
      );
      await _settle(tester);
    });

    expect(find.text('标签'), findsOneWidget);
    expect(find.text('1 个条目'), findsOneWidget);
    // 复用现有选择器：搜索、全部标签、新建标签、完成。
    expect(
      find.byKey(const ValueKey<String>('tag_picker_search')),
      findsOneWidget,
    );
    expect(find.text('全部标签'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('tag_picker_new')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('tag_picker_done')),
      findsOneWidget,
    );
    expect(
      (await db.getEpubBook(bookKey))!.isInLibrary,
      isFalse,
      reason: '选择阶段不翻转 membership',
    );

    await tester.runAsync(() async {
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagA')));
      await _settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagB')));
      await _settle(tester);
    });
    expect(
      (await db.getEpubBook(bookKey))!.isInLibrary,
      isFalse,
      reason: '选择阶段仍然不写库',
    );
    expect(await db.getTagsForBook(bookKey), isEmpty, reason: '选择阶段不写 Tag 分配');

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue, reason: '点完成才翻转同一行的 membership');
    expect(row.bookKey, opened.bookKey);
    expect(row.uid, opened.uid, reason: '加入书架不改变阅读身份');
    expect(row.extractDir, opened.extractDir, reason: '加入书架不改变下载目录');
    expect(
      find.byKey(const ValueKey<String>('manga_series_subscribe')),
      findsOneWidget,
      reason: '加入书架后订阅 / 自动追更入口出现',
    );
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

  testWidgets('没有任何 Tag：打开页已有非书架行，点加入书架直接翻转，不弹标签选择', (
    WidgetTester tester,
  ) async {
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse, reason: '打开作品页只创建非书架行');
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await _settle(tester);
      expect(find.byType(TagPickerPanel), findsNothing, reason: '零 Tag 不弹选择器');
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue, reason: '显式加入书架翻转同一行的 membership');
    expect(row.bookKey, opened.bookKey);
    expect(row.uid, opened.uid, reason: '加入书架不改变阅读身份');
    expect(row.extractDir, opened.extractDir, reason: '加入书架不改变下载目录');
    expect(await db.getTagsForBook(bookKey), isEmpty);
  });

  testWidgets('零选「完成」：翻转现有非书架行但不打 Tag，作品留在「书架」页签', (WidgetTester tester) async {
    await tester.runAsync(() => db.createTag('推理', 0xFF5C6BC0));
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse, reason: '打开作品页只创建非书架行');
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('tag_picker_done')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue, reason: '零选完成也翻转同一行');
    expect(row.uid, opened.uid);
    expect(row.extractDir, opened.extractDir);
    final List<BookTagRow> tags = await db.getTagsForBook(bookKey);
    expect(tags, isEmpty, reason: '零选 = 按未打标签加入');
    expect(
      mangaBookBelongsToTab(tags, const MangaShelfTabSelection()),
      isTrue,
      reason: '未打标签的作品出现在「书架」页签',
    );
  });

  testWidgets('打开页创建非书架行；点弹窗外部取消：membership 保持 false、不写 Tag', (
    WidgetTester tester,
  ) async {
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagId')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await _settle(tester);
      await tester.tapAt(const Offset(200, 80));
      await _settle(tester);
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: '点外部关闭弹窗');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isFalse, reason: '取消加入不翻转 membership');
    expect(row.uid, opened.uid);
    expect(await db.getTagsForBook(bookKey), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
    );
  });

  testWidgets('打开页创建非书架行；按 Esc 取消：membership 保持 false、不写 Tag', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() => db.createTag('推理', 0xFF5C6BC0));
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('tag_picker_done')),
      );
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
    });

    expect(find.byType(TagPickerPanel), findsNothing, reason: 'Esc 关闭弹窗');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isFalse, reason: 'Esc 取消不翻转 membership');
    expect(row.uid, opened.uid);
    expect(await db.getTagsForBook(bookKey), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
    );
  });

  testWidgets('加入失败：非书架行保持 membership=false，也不留 Tag 分配', (
    WidgetTester tester,
  ) async {
    late int tagId;
    await tester.runAsync(() async {
      tagId = await db.createTag('推理', 0xFF5C6BC0);
    });
    final OnlineMangaLibraryService failing = _FailingAddLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
    );
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;

    await tester.runAsync(() async {
      await pumpPage(tester, service: failing);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await pumpUntilFound(
        tester,
        find.byKey(ValueKey<String>('tag_picker_chip_$tagId')),
      );
      await _settle(tester);
      await tester.tap(find.byKey(ValueKey<String>('tag_picker_chip_$tagId')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey<String>('tag_picker_done')));
      await _settle(tester);
    });

    expect(tester.takeException(), isNull, reason: '失败由页面提示，不冒泡');
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isFalse, reason: '加入失败不翻转 membership');
    expect(row.uid, opened.uid);
    expect(await db.getTagsForBook(bookKey), isEmpty, reason: '加入失败时不留 Tag 分配');
    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsOneWidget,
      reason: '仍在未入库态，可重试',
    );
  });

  testWidgets('显式加入书架保留阅读进度、已读、下载映射与身份，并出现订阅入口', (WidgetTester tester) async {
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());
    late EpubBookRow opened;
    const int readAt = 1700000000000;

    await tester.runAsync(() async {
      await pumpPage(tester);
      opened = (await db.getEpubBook(bookKey))!;
      expect(opened.isInLibrary, isFalse, reason: '打开作品页只创建非书架行');
      // 非书架作品在加入书架前已经可以阅读、标记已读与下载。
      await db.saveMangaChapterState(
        bookUid: opened.uid,
        chapterKey: '/chapter/1',
        lastPage: 7,
        pageCount: 20,
        readAt: readAt,
      );
      await db.upsertMangaChapterDir(
        bookKey: opened.bookKey,
        chapterKey: '/chapter/1',
        folderName: 'Chapter 1',
        updatedAt: readAt,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await _settle(tester);
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue);
    expect(row.bookKey, opened.bookKey);
    expect(row.uid, opened.uid, reason: '阅读状态仍按同一 uid 归属');
    expect(row.extractDir, opened.extractDir, reason: '下载目录不变');
    final MangaChapterStateRow? state = await db.getMangaChapterState(
      bookUid: row.uid,
      chapterKey: '/chapter/1',
    );
    expect(state?.lastPage, 7, reason: '阅读进度保留');
    expect(state?.readAt, readAt, reason: '已读标记保留');
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      row.bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1', reason: '下载映射保留');
    expect(
      find.byKey(const ValueKey<String>('manga_series_subscribe')),
      findsOneWidget,
      reason: '加入书架后订阅入口出现',
    );

    // 订阅入口可用：开订阅后「新章自动下载」菜单项随之出现。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      await _settle(tester);
    });
    final OnlineMangaLibraryEntry subscribed = OnlineMangaLibraryEntry.tryParse(
      (await db.getEpubBook(bookKey))!.sourceMetadata,
    )!;
    expect(subscribed.subscribed, isTrue);
    expect(subscribed.autoDownload, isTrue);
    // 自适应操作区可能把「新章自动下载」平铺，也可能收进「⋯」。
    if (find
        .byKey(const ValueKey<String>('manga_series_auto_download'))
        .evaluate()
        .isEmpty) {
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey<String>('online_work_more')),
          warnIfMissed: false,
        );
        await _settle(tester);
      });
    }
    expect(
      find.byKey(const ValueKey<String>('manga_series_auto_download')),
      findsOneWidget,
      reason: '加入书架并订阅后出现自动追更入口',
    );
  });

  testWidgets('不存在非书架行时，加入书架仍创建新的 Library 行', (WidgetTester tester) async {
    final OnlineMangaLibraryService noRow = _NoRowService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
    );
    final String bookKey = OnlineMangaLibraryService.bookKeyOf(_entry());

    await tester.runAsync(() async {
      await pumpPage(tester, service: noRow);
      expect(await db.getEpubBook(bookKey), isNull, reason: '打开页没有可翻转的行');
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      );
      await _settle(tester);
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    expect(row.isInLibrary, isTrue, reason: '无行时创建 Library 行');
    expect(row.bookKey, bookKey);
    expect(row.format, 'manga');
    expect(await db.getTagsForBook(bookKey), isEmpty);
    expect(
      find.byKey(const ValueKey<String>('manga_series_subscribe')),
      findsOneWidget,
    );
  });
}
