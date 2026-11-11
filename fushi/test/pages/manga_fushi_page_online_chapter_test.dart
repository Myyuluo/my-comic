import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/reader/manga_session_page_image.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/book_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

/// 在线书架条目在阅读器里的三条路（设计稿 2026-09-12 §5「阅读器」+ 2026-09-26
/// 补记）：当前章**已下载** → 章目录当本地卷装载、不打源；**未下载** → 在线直读
/// （不落章目录、不入队、不给 OCR 入口）；**直读失败** → 退回「本章未下载」态，
/// 入队按钮在、返回键在。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  int resolveCalls = 0;
  final List<int> fetchedPages = <int>[];

  /// 为真时像真源一样给页表和页图；为假时模拟源不可用。
  bool serve = false;

  static final Uint8List png = Uint8List.fromList(
    img.encodePng(img.Image(width: 60, height: 90)),
  );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// null = 来源未安装（阅读本地已下载章不该依赖它）。
  String? sourceLabelText = 'Fake';

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      sourceLabelText;

  @override
  Future<OnlineMangaRefreshResult> refresh(
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async {
    resolveCalls++;
    if (!serve) throw StateError('source unavailable');
    return <OnlineMangaPageRef>[
      for (int index = 0; index < 3; index++)
        HttpMangaPageRef(
          index: index,
          url: 'https://example.invalid${chapter.key}/$index.png',
          referer: 'https://example.invalid',
        ),
    ];
  }

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    if (!serve) throw StateError('source unavailable');
    fetchedPages.add(page.index);
    return png;
  }

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _MangaTestAppModel extends AppModel {
  _MangaTestAppModel(this._db, this._library, this._temp)
      : super(testPlatformServices());

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final Directory _temp;

  /// 在线直读的页缓存根（`manga_stream_cache/`）落在这里。
  @override
  Directory get temporaryDirectory => _temp;

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) =>
      _library;

  @override
  bool get lowMemoryMode => false;
  @override
  double get popupMaxWidth => 360;

  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  String get mangaSpreadPreference => 'auto';
  @override
  String get mangaReadingDirection => 'rtl';
  @override
  int get mangaZoomPercent => 100;
  @override
  int get mangaZoomSensitivity => kMangaZoomSensitivityDefault;
  @override
  String get mangaPageAnimation => MangaPageAnimation.slide.key;

  @override
  String get mangaPageAnimationSpeed => PageTurnAnimationSpeed.normal.key;

  @override
  bool get mangaPageTurnFollowDrag => kMangaPageTurnFollowDragDefault;
  @override
  bool get mangaTapZonePaging => true;

  // 固定顶栏：测试默认要看得见栏里的按钮（悬浮态默认收起）。
  @override
  bool get mangaChromeFloating => false;
  @override
  bool get mangaVolumeKeyPaging => false;

  // 进入即整卷 OCR（_maybeStartVolumeOcr）开书就读这三项：测试里 prefsRepo 是
  // null，不覆写就在开书后抛 _TypeError。与 manga_fushi_page_test 同口径显式走
  // manual，免得 widget 测试去碰原生 OCR 后端。
  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');

  @override
  String get mangaOcrEnginePreference => 'local_onnx';

  @override
  String get mangaOcrLensLanguage => 'ja';
}

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          builder: (BuildContext context, Widget? child) =>
              child ?? const SizedBox.shrink(),
          home: MangaFushiPage(item: _item(bookKey), bookKey: bookKey),
        ),
      ),
    );

MediaItem _item(String bookKey) => MediaItem(
      mediaIdentifier: 'fushi://book/$bookKey',
      mediaSourceIdentifier: 'reader_manga',
      title: 'Test Manga',
      mediaTypeIdentifier: 'reader',
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
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

/// 导入时来源未安装的条目：占位扩展包 + 数字 sourceId。
OnlineMangaLibraryEntry _placeholderEntry() => const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: kUnavailableMihonExtensionPackage,
      sourceId: '524579092615598717',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
    );

/// 在 Download library 写一章：`downloads/{source}/{manga}/{chapter}/` 平铺页图
/// + `pages.json` + 数据库映射。
Future<Directory> _writeDownloadedChapter(
  FushiDatabase db, {
  required String bookKey,
  required String bookDir,
  required String chapterKey,
  String folderName = 'Chapter 1',
  String chapterName = 'Chapter 1',
}) async {
  final Directory chapterDir = downloadChapterDirectory(bookDir, folderName);
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await File(p.join(chapterDir.path, '002.jpg')).writeAsBytes(<int>[2]);
  await writePagesManifestAtomically(
    chapterDir,
    MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Fixture series',
      chapterKey: chapterKey,
      chapterName: chapterName,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
          MokuroImage(
            url: '002.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    ),
  );
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapterKey,
    folderName: folderName,
    updatedAt: 1,
  );
  return chapterDir;
}

/// 在 Download library 写一个 CBZ 章节：`downloads/{source}/{manga}/{chapter}.cbz`
/// + 数据库映射（containerKind = archive）。`pages.json` 的页序故意与文件名自然序
/// 相反，阅读器必须按包根页表翻页。
Future<File> _writeDownloadedArchiveChapter(
  FushiDatabase db, {
  required String bookKey,
  required String bookDir,
  required String chapterKey,
  String containerName = 'Chapter 1.cbz',
  String chapterName = 'Chapter 1',
  bool withManifest = true,
}) async {
  final Uint8List first = Uint8List.fromList(
    img.encodePng(img.Image(width: 100, height: 150)),
  );
  final Uint8List second = Uint8List.fromList(
    img.encodePng(img.Image(width: 120, height: 180)),
  );
  final Archive archive = Archive()
    ..addFile(ArchiveFile('001.png', first.length, first))
    ..addFile(ArchiveFile('002.png', second.length, second));
  if (withManifest) {
    final List<int> manifest = utf8.encode(
      jsonEncode(<String, Object?>{
        'source': <String, Object?>{
          'runtime': 'mihon',
          'id': '1',
          'name': 'Fake',
          'extensionPackage': 'org.example.fixture',
        },
        'manga': <String, Object?>{
          'key': '/series/fixture',
          'title': 'Fixture series',
        },
        'chapter': <String, Object?>{'key': chapterKey, 'name': chapterName},
        'pages': <Object?>[
          <String, Object?>{'url': '002.png', 'width': 120, 'height': 180},
          <String, Object?>{'url': '001.png', 'width': 100, 'height': 150},
        ],
        'downloadedAt': DateTime.utc(2026, 11, 7).toIso8601String(),
      }),
    );
    archive.addFile(ArchiveFile('pages.json', manifest.length, manifest));
  }
  final File file = downloadChapterArchiveFile(bookDir, containerName);
  // 入库不再建目录；这里模拟磁盘上已有下载的 CBZ。
  await file.parent.create(recursive: true);
  await file.writeAsBytes(ZipEncoder().encode(archive)!);
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapterKey,
    folderName: containerName,
    containerKind: MangaChapterContainerKind.archive,
    updatedAt: 1,
  );
  return file;
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_reader_online_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('在线条目 + 当前章已下载 → 章目录当本地卷装载，正常渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      // 新读者从最旧一话（列表末尾 = Chapter 1）开始。
      await _writeDownloadedChapter(
        db,
        bookKey: bookKey,
        bookDir: row.extractDir,
        chapterKey: '/chapter/1',
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 0, reason: '已下载的章不打源');
    // 章节选择器入口只有书架在线条目才有。
    final Finder chapters =
        find.byKey(const ValueKey<String>('manga_reader_chapters'));
    expect(chapters, findsOneWidget);
    // 章节按钮在底部悬浮工具栏的导航组里（拇指区，优先级仅次于快捷设置）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('manga_reader_toolbar')),
        matching: chapters,
      ),
      findsOneWidget,
    );
    // 点开是左侧侧栏，不是底部弹层。
    await tester.runAsync(() async {
      await tester.tap(chapters);
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_reader_chapter_drawer')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
    });
    // 侧栏进场是 M3E 弹簧（[FushiMotion.long]，落位前有轻微过冲）：推满整段
    // 转场再量位置，否则读到的是过冲中的瞬时 left。
    await tester.pump(FushiMotion.long + const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey<String>('manga_reader_chapter_drawer')),
        findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey<String>('fushi_reader_side_sheet')))
          .left,
      0,
      reason: '章节目录从左侧打开',
    );
    expect(find.byType(BottomSheet), findsNothing);
    // 打开即记「选了这一章」。
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!
          .currentChapter
          ?.key,
      '/chapter/1',
    );
  });

  testWidgets('在线条目 + 当前章是 CBZ 下载章 → 从压缩包按需装载，正常渲染', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db, library, root);

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookDir = row.extractDir;
      await _writeDownloadedArchiveChapter(
        db,
        bookKey: bookKey,
        bookDir: bookDir,
        chapterKey: '/chapter/1',
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_content_ready')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 0, reason: '已下载的 CBZ 章不打源');
    // 页缓存落在 app 临时目录的会话私有目录里；压缩包本身留在 Download library，
    // 不被复制、也不展开成章节目录。
    expect(
      Directory(p.join(root.path, 'local_source_archive_cache')).existsSync(),
      isTrue,
    );
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '不得把整包解压进受管目录',
    );

    // 关闭阅读器：页会话清理临时解压目录（缓存可丢，原包不动）。
    final File archive = downloadChapterArchiveFile(bookDir, 'Chapter 1.cbz');
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
    final Directory cacheRoot = Directory(
      p.join(root.path, 'local_source_archive_cache'),
    );
    expect(
      cacheRoot.existsSync()
          ? cacheRoot.listSync()
          : const <FileSystemEntity>[],
      isEmpty,
      reason: '会话关闭后临时解压目录应被清理',
    );
    expect(archive.existsSync(), isTrue, reason: '原包只读，关闭阅读器不得删改');
  });

  testWidgets('CBZ 下载章的页面一览用会话缩略图（不预解整包）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await _writeDownloadedArchiveChapter(
        db,
        bookKey: bookKey,
        bookDir: row.extractDir,
        chapterKey: '/chapter/1',
      );
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_reader_page_grid_button')),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_page_grid')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_page_grid')),
      findsOneWidget,
    );
    final Finder images = find.descendant(
      of: find.byKey(const ValueKey<String>('manga_page_grid')),
      matching: find.byType(Image),
    );
    expect(images, findsWidgets);
    for (final Image image in tester.widgetList<Image>(images)) {
      expect(image.image, isA<ResizeImage>());
      expect(
        (image.image as ResizeImage).imageProvider,
        isA<MangaSessionPageImage>(),
        reason: 'CBZ 页的缩略图由页会话按需解压，不读不存在的盘上文件',
      );
    }

    // 关阅读器让压缩包句柄释放，tearDown 才能删测试根目录。
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
  });

  testWidgets('手工放置的 CBZ（无 pages.json）按图片自然序阅读', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      // 只有页图、没有包根 pages.json：完整性判据不算「已下载」，但阅读器仍应
      // 按 Local source 的口径回退图片条目自然序把包读出来。
      await _writeDownloadedArchiveChapter(
        db,
        bookKey: bookKey,
        bookDir: row.extractDir,
        chapterKey: '/chapter/1',
        withManifest: false,
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_content_ready')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 0, reason: '能读包就不去打源');

    // 关阅读器让压缩包句柄释放，tearDown 才能删测试根目录。
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    });
  });

  testWidgets('损坏的 CBZ 章 → 既有失败态，不崩溃', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel = _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      final File broken = downloadChapterArchiveFile(
        row.extractDir,
        'Chapter 1.cbz',
      );
      await broken.parent.create(recursive: true);
      await broken.writeAsString('not a zip');
      await db.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
        folderName: 'Chapter 1.cbz',
        containerKind: MangaChapterContainerKind.archive,
        updatedAt: 1,
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('manga_content_ready')),
      findsNothing,
    );
    expect(tester.takeException(), isNull, reason: '坏包不得把异常掀翻阅读器');
  });

  testWidgets('在线条目 + 当前章未下载且直读失败 → 「本章未下载」态：入队按钮在、返回键在',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      );
    });
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('manga_reader_back_button')),
        findsOneWidget,
        reason: '出口不随内容存亡');
    expect(
      find.byKey(const ValueKey<String>('manga_reader_enqueue_download')),
      findsOneWidget,
    );
    expect(adapter.resolveCalls, 1, reason: '先试了在线直读，源不可用才退到这一态');

    // 点「下载」→ 任务表里出现 queued 行（worker 未启动，行停在 queued）。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_reader_enqueue_download')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    });
    final MangaDownloadJobRow? job = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: bookKey,
      chapterKey: '/chapter/1',
    );
    expect(job, isNotNull);
    expect(job!.status, MangaDownloadJobStatus.queued);
  });

  testWidgets('在线条目 + 当前章未下载 → 在线直读：不入队、不落章目录、不给 OCR 入口',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    adapter.serve = true;
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookDir = row.extractDir;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });
    await tester.pump();

    expect(find.byKey(const ValueKey<String>('manga_content_ready')),
        findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(adapter.resolveCalls, 1);
    expect(adapter.fetchedPages, contains(0), reason: '落点页开书前先取');
    // 直读不产生下载：章目录判据仍是「未下载」，任务表空。真实文件 IO 必须在
    // runAsync 里跑，FakeAsync 区里 await 它会永远挂住。
    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    final bool downloaded = (await tester.runAsync(
      () => DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
    ))!;
    expect(downloaded, isFalse);
    expect(
      Directory(bookDir).existsSync(),
      isFalse,
      reason: '浏览 + 在线直读不得创建 downloads/{source}/{manga}',
    );
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '直读页只进临时缓存，不碰下载章目录',
    );
    expect(Directory(p.join(bookDir, '.staging')).existsSync(), isFalse);
    expect(await db.listMangaDownloadJobs(), isEmpty);
    // 页缓存在 app 临时目录下。
    expect(
      Directory(p.join(root.path, 'manga_stream_cache')).existsSync(),
      isTrue,
    );
    // 开读即记「选了这一章」。
    expect(
      OnlineMangaLibraryEntry.tryParse(after.sourceMetadata)!
          .currentChapter
          ?.key,
      '/chapter/1',
    );
  });

  testWidgets('旧布局 extractDir：阅读不重指、不创建 Download library 目录',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    adapter.serve = true;
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    late String legacyDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      // 旧布局：`<runtimeRoot>/library/<bookKey>`，不在当前 downloads 根下。
      legacyDir = p.join(root.path, 'fushi_books', bookKey);
      await Directory(legacyDir).create(recursive: true);
      await db.updateEpubBookContentPaths(bookKey, extractDir: legacyDir);

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    final EpubBookRow after = (await db.getEpubBook(bookKey))!;
    expect(
      after.extractDir,
      legacyDir,
      reason: '只阅读不得把旧 extractDir 重指到 Download library',
    );
    expect(
      Directory(p.join(root.path, 'downloads')).existsSync(),
      isFalse,
      reason: '阅读不得创建 downloads/{source}/{manga}',
    );
  });

  testWidgets('来源未安装：已有本地下载章仍可阅读，且不创建新目录', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    adapter
      ..serve = false
      ..sourceLabelText = null;
    final _MangaTestAppModel appModel =
        _MangaTestAppModel(db, library, root);

    late String bookKey;
    late String bookDir;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_placeholderEntry());
      bookKey = row.bookKey;
      expect(
        Directory(row.extractDir).existsSync(),
        isFalse,
        reason: '入库不物化目录（含数字 sourceId 目录）',
      );
      // 已有本地下载：按当前 Download library 的可读目录关联（如导入后重链的
      // 结果），来源未安装不影响读取。
      bookDir = p.join(
        root.path,
        'downloads',
        'Fixture',
        'Fixture series',
      );
      await db.updateEpubBookContentPaths(bookKey, extractDir: bookDir);
      await _writeDownloadedChapter(
        db,
        bookKey: bookKey,
        bookDir: bookDir,
        chapterKey: '/chapter/1',
      );

      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_chapter_not_downloaded')),
      findsNothing,
    );
    expect(
      adapter.resolveCalls,
      0,
      reason: '来源未安装时读本地章不得请求来源页表',
    );
    expect(
      Directory(p.join(bookDir, '.staging')).existsSync(),
      isFalse,
      reason: '阅读已有本地章不产生下载 staging',
    );
  });
}
