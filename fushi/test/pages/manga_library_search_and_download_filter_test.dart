// Ticket 06：漫画页搜索扩围 + 「漫画下载」筛选 + 页签数量联动。
//
// 页面级 seam（与 manga_library_tag_tabs_test / manga_shelf_unread_badge_test
// 同源）：真实 37 表内存库 + 真实漫画书架 `ReaderFushiHistoryPage(mangaOnly:
// true)`，书架列表 provider 覆写成受控 MediaItem 列表。断言只落在用户可见结果
// 上：网格里出现哪些卡、页签上的数量、排序与筛选菜单里点选的结果。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 一条在线漫画书架条目的固定夹具（章节目录住在 sourceMetadata 描述符里）。
OnlineMangaLibraryEntry onlineEntry({
  required String bookKey,
  required String title,
  String? author,
  String? artist,
  String? genre,
  String? description,
  List<String> chapters = const <String>['/c/1'],
}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/$bookKey',
    title: title,
    author: author,
    artist: artist,
    genre: genre,
    description: description,
    raw: <String, Object?>{'url': '/series/$bookKey'},
  ),
  chapters: <OnlineMangaChapter>[
    for (final String key in chapters)
      OnlineMangaChapter(
        key: key,
        name: key,
        raw: <String, Object?>{'url': key},
      ),
  ],
  currentChapterIndex: chapters.isEmpty ? null : 0,
);

MediaItem mangaItem(
  String bookKey,
  String title, {
  String? author,
  int position = 0,
  int duration = 100,
}) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
  title: title,
  author: author,
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
  position: position,
  duration: duration,
  canDelete: false,
  canEdit: true,
);

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_search_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory contentRoot;
  late Directory storeDir;
  late List<MediaItem> mangaItems;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    contentRoot = Directory.systemTemp.createTempSync('fushi_manga_search');
    // Download library / 本地图源的当前 Content root：与 DownloadLibraryIndex
    // 同一条测试缝（<root>/fushi_books 的同级 <root>/downloads）。
    EpubStorage.debugBaseDirectoryOverride = contentRoot.path;
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_search_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    mangaItems = <MediaItem>[];
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    for (final Directory dir in <Directory>[contentRoot, storeDir]) {
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  Future<EpubBookRow> seedOnlineManga({
    required String bookKey,
    required String title,
    String? author,
    String? artist,
    String? genre,
    String? description,
    List<String> chapters = const <String>['/c/1'],
  }) async {
    final OnlineMangaLibraryEntry entry = onlineEntry(
      bookKey: bookKey,
      title: title,
      author: author,
      artist: artist,
      genre: genre,
      description: description,
      chapters: chapters,
    );
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        author: Value<String?>(entry.series.byline),
        epubPath: 'pages.json',
        extractDir: p.join(
          contentRoot.path,
          'downloads',
          'Example Source',
          bookKey,
        ),
        chapterCount: chapters.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(entry.encode()),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  Future<EpubBookRow> seedLocalSourceManga({
    required String bookKey,
    required String title,
    String? author,
    required String extractDir,
    List<String> chapterKeys = const <String>['vol/1'],
  }) async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        author: Value<String?>(author),
        epubPath: '',
        extractDir: extractDir,
        chapterCount: chapterKeys.length,
        chaptersJson: encodeLocalSourceChapters(
          <LocalSourceChapterRecord>[
            for (final String key in chapterKeys)
              LocalSourceChapterRecord(
                key: key,
                name: key,
                relativePath: key,
              ),
          ],
        ),
        sourceMetadata: Value<String?>(
          const LocalSourceMetadata(relativePath: 'manga/local').encode(),
        ),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  MangaPagesManifest manifestFor(String chapterKey) => MangaPagesManifest(
    sourceRuntime: 'mihon',
    sourceId: '1',
    sourceName: 'Example Source',
    extensionPackage: 'org.example.fixture',
    mangaKey: '/series/fixture',
    mangaTitle: 'Fixture series',
    chapterKey: chapterKey,
    chapterName: chapterKey,
    payload: const MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: '001.jpg',
          size: MokuroSize(100, 150),
          blocks: <MokuroBlock>[],
        ),
      ],
    ),
    downloadedAt: DateTime.utc(2026, 11, 7),
  );

  /// 章容器名：真实下载写的是净化后的目录名（无路径分隔符），不是章 key。
  String folderFor(String chapterKey) =>
      chapterKey.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');

  /// 在线漫画的「至少一章完整落盘」夹具：章目录 + 页图 + `pages.json` + 映射。
  Future<void> writeCompleteChapter(
    String bookKey, {
    required String chapterKey,
    String? folderName,
  }) async {
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final String container = folderName ?? folderFor(chapterKey);
    final Directory chapterDir = downloadChapterDirectory(
      row.extractDir,
      container,
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(chapterDir, manifestFor(chapterKey));
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: container,
      updatedAt: 1,
    );
  }

  /// 半成品：有映射、有页图，但 `pages.json` 还没落——不算已下载。
  Future<void> writeHalfCompleteChapter(
    String bookKey, {
    required String chapterKey,
    String? folderName,
  }) async {
    final EpubBookRow row = (await db.getEpubBook(bookKey))!;
    final String container = folderName ?? folderFor(chapterKey);
    final Directory chapterDir = downloadChapterDirectory(
      row.extractDir,
      container,
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: container,
      updatedAt: 1,
    );
  }

  /// Missing：映射还在，磁盘上的章容器已被外部删掉——不算已下载。
  Future<void> writeMissingChapterMapping(
    String bookKey, {
    required String chapterKey,
    String? folderName,
  }) async {
    await db.upsertMangaChapterDir(
      bookKey: bookKey,
      chapterKey: chapterKey,
      folderName: folderName ?? folderFor(chapterKey),
      updatedAt: 1,
    );
  }

  Widget buildApp(List<MediaItem> items) => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(items),
      ),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            mangaOnly: true,
            remoteBookClientLoader: () async => null,
          ),
        ),
      ),
    ),
  );

  /// 让真实异步（DB 读、书架映射）落地；fake 时钟推不动它们。
  Future<void> pumpRealAsync(WidgetTester tester, {int steps = 40}) async {
    await tester.runAsync(() async {
      for (int i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> pumpShelf(
    WidgetTester tester,
    List<MediaItem> items, {
    Size size = const Size(1400, 1400),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp(items));
    await pumpRealAsync(tester);
  }

  Finder mangaCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  Finder shelfSegment() =>
      find.byKey(const ValueKey<String>('manga_tag_tab_shelf'));

  Finder tagSegment(int tagId) =>
      find.byKey(ValueKey<String>('manga_tag_tab_$tagId'));

  String countText(WidgetTester tester, String scope) => tester
      .widget<Text>(
        find.byKey(ValueKey<String>('manga_tag_tab_count_$scope')),
      )
      .data!;

  Future<void> search(WidgetTester tester, String query) async {
    final Finder field = find.byKey(
      const ValueKey<String>('shelf_search_field'),
    );
    if (field.evaluate().isEmpty) {
      await tester.tap(
        find.byKey(const ValueKey<String>('fushi-header-search-button')),
      );
      await tester.pumpAndSettle();
    }
    await tester.enterText(field, query);
    await tester.pumpAndSettle();
  }

  /// 收起页头搜索（Esc 先清空、再收起）；排序按钮只在收起态可见。
  Future<void> closeSearch(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  }

  Future<void> pickDownloadFilter(WidgetTester tester, String name) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('library_sort_menu_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('shelf_filter_download_$name')),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pickReadStatus(WidgetTester tester, String name) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('library_sort_menu_button')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('shelf_filter_read_status_$name')),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('搜索匹配源分类与简介，不匹配用户标签', (WidgetTester tester) async {
    late int tagId;
    await tester.runAsync(() async {
      await seedOnlineManga(
        bookKey: 'm1',
        title: '剑与魔法',
        author: '作者甲',
        genre: '奇幻,冒险',
        description: '少年踏上旅途',
      );
      await seedOnlineManga(
        bookKey: 'm2',
        title: '都市日常',
        author: '作者乙',
        genre: '日常',
        description: '平淡生活',
      );
      tagId = await db.createTag('隐藏标签词', 0xFF112233);
      await db.addTagToBook('m2', tagId);
    });
    mangaItems.addAll(<MediaItem>[
      mangaItem('m1', '剑与魔法', author: '作者甲'),
      mangaItem('m2', '都市日常', author: '作者乙'),
    ]);
    await pumpShelf(tester, mangaItems);

    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagId'), '1');

    // 源分类命中。
    await search(tester, '奇幻');
    expect(mangaCard('m1'), findsOneWidget, reason: '搜索应匹配源分类');
    expect(mangaCard('m2'), findsNothing);
    expect(countText(tester, 'shelf'), '1');

    // 简介命中。
    await search(tester, '少年踏上');
    expect(mangaCard('m1'), findsOneWidget, reason: '搜索应匹配简介');
    expect(countText(tester, 'shelf'), '1');

    // 用户标签不参与搜索：带标签的 m2 在「书架」本来就不显示；停在书架
    // 搜标签词应零命中，页签数量也始终显示 0。
    await search(tester, '隐藏标签词');
    expect(mangaCard('m1'), findsNothing);
    expect(mangaCard('m2'), findsNothing);
    expect(countText(tester, 'shelf'), '0', reason: '搜索结果为零也显示数量');
  });

  testWidgets('搜索匹配作者行：作者优先、画师兜底；本地图源只匹配标题和作者', (
    WidgetTester tester,
  ) async {
    final Directory localDir = Directory(
      p.join(contentRoot.path, 'local', 'LocalTitle'),
    );
    await tester.runAsync(() async {
      await localDir.create(recursive: true);
      await seedOnlineManga(
        bookKey: 'm1',
        title: '画师漫画',
        artist: '画师乙',
        genre: '奇幻',
        description: '画师的作品',
      );
      await seedOnlineManga(
        bookKey: 'm2',
        title: '作者漫画',
        author: '作者丙',
        artist: '画师丁',
        genre: '日常',
      );
      await seedLocalSourceManga(
        bookKey: 'm3',
        title: '本地作品',
        author: '本地作者',
        extractDir: localDir.path,
      );
    });
    mangaItems.addAll(<MediaItem>[
      mangaItem('m1', '画师漫画'),
      mangaItem('m2', '作者漫画', author: '作者丙'),
      mangaItem('m3', '本地作品', author: '本地作者'),
    ]);
    await pumpShelf(tester, mangaItems);

    // 作者行：有作者时作者优先（画师不进入作者行）。
    await search(tester, '作者丙');
    expect(mangaCard('m2'), findsOneWidget, reason: '搜索匹配作者');
    expect(mangaCard('m1'), findsNothing);
    await search(tester, '画师丁');
    expect(mangaCard('m2'), findsNothing, reason: '作者存在时画师不进作者行');

    // 画师兜底：没有作者时作者行 = 画师。
    await search(tester, '画师乙');
    expect(mangaCard('m1'), findsOneWidget, reason: '没有作者时搜索匹配画师');

    // 本地图源没有源分类 / 简介，只匹配标题和作者。
    await search(tester, '本地作者');
    expect(mangaCard('m3'), findsOneWidget, reason: '本地图源搜索匹配作者');
    await search(tester, '本地作品');
    expect(mangaCard('m3'), findsOneWidget, reason: '本地图源搜索匹配标题');
    await search(tester, '奇幻');
    expect(mangaCard('m3'), findsNothing, reason: '本地图源没有源分类可匹配');
    expect(mangaCard('m1'), findsOneWidget, reason: '在线漫画仍按源分类命中');
  });

  testWidgets('「漫画下载」单选组：全部/已下载/未下载，Missing 与半成品不算已下载', (
    WidgetTester tester,
  ) async {
    final Directory localPresent = Directory(
      p.join(contentRoot.path, 'local', 'Present'),
    );
    final Directory localMissing = Directory(
      p.join(contentRoot.path, 'local', 'Missing'),
    );
    await tester.runAsync(() async {
      await localPresent.create(recursive: true);
      await seedOnlineManga(
        bookKey: 'm1',
        title: '完整下载',
        chapters: <String>['/c/1'],
      );
      await writeCompleteChapter('m1', chapterKey: '/c/1');
      await seedOnlineManga(
        bookKey: 'm2',
        title: '文件缺失',
        chapters: <String>['/c/2'],
      );
      await writeMissingChapterMapping('m2', chapterKey: '/c/2');
      await seedOnlineManga(
        bookKey: 'm3',
        title: '半成品',
        chapters: <String>['/c/3'],
      );
      await writeHalfCompleteChapter('m3', chapterKey: '/c/3');
      await seedLocalSourceManga(
        bookKey: 'm4',
        title: '本地存在',
        extractDir: localPresent.path,
      );
      await seedLocalSourceManga(
        bookKey: 'm5',
        title: '本地缺失',
        extractDir: localMissing.path,
      );
    });
    mangaItems.addAll(<MediaItem>[
      mangaItem('m1', '完整下载'),
      mangaItem('m2', '文件缺失'),
      mangaItem('m3', '半成品'),
      mangaItem('m4', '本地存在', position: 50),
      mangaItem('m5', '本地缺失'),
    ]);
    await pumpShelf(tester, mangaItems);

    expect(countText(tester, 'shelf'), '5', reason: '默认「全部」不筛下载状态');

    await tester.tap(
      find.byKey(const ValueKey<String>('library_sort_menu_button')),
    );
    await tester.pumpAndSettle();
    for (final String name in <String>[
      'all',
      'downloaded',
      'not_downloaded',
    ]) {
      expect(
        find.byKey(ValueKey<String>('shelf_filter_download_$name')),
        findsOneWidget,
        reason: '「漫画下载」组包含 $name',
      );
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('shelf_filter_download_downloaded')),
    );
    await tester.pumpAndSettle();

    expect(mangaCard('m1'), findsOneWidget, reason: '完整落盘的在线漫画算已下载');
    expect(mangaCard('m4'), findsOneWidget, reason: '本地图源目录存在算已下载');
    expect(mangaCard('m2'), findsNothing, reason: 'Missing 不计为已下载');
    expect(mangaCard('m3'), findsNothing, reason: '半成品（无 pages.json）不算已下载');
    expect(mangaCard('m5'), findsNothing, reason: '本地图源目录不存在不算已下载');
    expect(countText(tester, 'shelf'), '2');

    await pickDownloadFilter(tester, 'not_downloaded');
    expect(mangaCard('m2'), findsOneWidget);
    expect(mangaCard('m3'), findsOneWidget);
    expect(mangaCard('m5'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing);
    expect(mangaCard('m4'), findsNothing);
    expect(countText(tester, 'shelf'), '3');

    await pickDownloadFilter(tester, 'all');
    expect(countText(tester, 'shelf'), '5', reason: '选回「全部」应恢复全部条目');

    // 漫画下载与阅读状态是 AND：已下载 + 在读只剩本地 m4。
    await pickDownloadFilter(tester, 'downloaded');
    await pickReadStatus(tester, 'reading');
    expect(mangaCard('m4'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing, reason: '已下载但未读的 m1 被阅读状态筛掉');
    expect(countText(tester, 'shelf'), '1');

    await pickReadStatus(tester, 'all');
    expect(countText(tester, 'shelf'), '2', reason: '下载筛选保持生效');
  });

  testWidgets('下载筛选与当前页签 AND；搜索词切页签保留且数量同步重算', (
    WidgetTester tester,
  ) async {
    final Directory localDir = Directory(
      p.join(contentRoot.path, 'local', 'ShelfOnly'),
    );
    late int tagId;
    await tester.runAsync(() async {
      await localDir.create(recursive: true);
      await seedOnlineManga(
        bookKey: 'm1',
        title: '下载的连载',
        chapters: <String>['/c/1'],
      );
      await writeCompleteChapter('m1', chapterKey: '/c/1');
      await seedOnlineManga(
        bookKey: 'm2',
        title: '未下载的连载',
        chapters: <String>['/c/2'],
      );
      await writeMissingChapterMapping('m2', chapterKey: '/c/2');
      await seedLocalSourceManga(
        bookKey: 'm3',
        title: '本地作品',
        extractDir: localDir.path,
      );
      tagId = await db.createTag('连载', 0xFF112233);
      await db.addTagToBook('m1', tagId);
      await db.addTagToBook('m2', tagId);
    });
    mangaItems.addAll(<MediaItem>[
      mangaItem('m1', '下载的连载'),
      mangaItem('m2', '未下载的连载'),
      mangaItem('m3', '本地作品'),
    ]);
    await pumpShelf(tester, mangaItems);

    expect(countText(tester, 'shelf'), '1', reason: '无标签的本地作品在书架');
    expect(countText(tester, '$tagId'), '2');

    await pickDownloadFilter(tester, 'downloaded');
    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagId'), '1', reason: '下载筛选计入页签数量');
    expect(mangaCard('m3'), findsOneWidget);

    await tester.tap(tagSegment(tagId));
    await tester.pumpAndSettle();
    expect(mangaCard('m1'), findsOneWidget);
    expect(mangaCard('m2'), findsNothing, reason: '下载筛选只在当前页签集合内生效');

    // 搜索「下载」：两个标签漫画标题都含该词，但下载筛选再筛掉未下载的 m2。
    await search(tester, '下载');
    expect(countText(tester, '$tagId'), '1');
    expect(countText(tester, 'shelf'), '0', reason: '书架下没有命中（搜索不跨页签）');
    expect(mangaCard('m1'), findsOneWidget);
    expect(mangaCard('m2'), findsNothing);

    // 换成「未下载」：同一搜索词下只剩 m2。排序菜单在搜索展开时不可见，
    // 先收起搜索（收起会清空搜索词），换完筛选再重新输入。
    await closeSearch(tester);
    await pickDownloadFilter(tester, 'not_downloaded');
    await search(tester, '下载');
    expect(countText(tester, '$tagId'), '1');
    expect(mangaCard('m2'), findsOneWidget);
    expect(mangaCard('m1'), findsNothing);

    // 切回「书架」：搜索词保留，数量按当前筛选重算（m3 已下载 → 0）。
    await tester.tap(shelfSegment());
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('shelf_search_field')),
      findsOneWidget,
      reason: '切换页签保留搜索词',
    );
    expect(countText(tester, 'shelf'), '0');
    expect(countText(tester, '$tagId'), '1', reason: '其他页签数量按当前筛选重算');
    expect(mangaCard('m3'), findsNothing, reason: 'm3 已下载，被「未下载」筛掉');
  });
}
