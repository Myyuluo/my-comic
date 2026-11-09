import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_cover_placeholder.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 02：Manga 作品页封面与书架同一套「本地优先、备份 series.coverUrl
/// 远程回退、失败/空值占位」规则。用页面级 seam：真实 Drift DB + 可控运行时
/// 适配器（本测试不联网），断言只落在用户可见的封面控件与占位块上。
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
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
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

const List<OnlineMangaChapter> _oneChapter = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry({String? coverUrl}) => OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'mihon.unavailable',
  sourceId: '524579092615598717',
  series: OnlineMangaSeries(
    key: '/series/imported',
    title: 'Imported series',
    coverUrl: coverUrl,
    raw: const <String, Object?>{},
  ),
  // 有缓存章节时作品页首屏不自动联网（刷新策略）；封面测试不依赖运行时。
  chapters: _oneChapter,
);

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_cover_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<({String bookKey, String extractDir})> insertImportedSeries({
    required String? coverUrl,
    bool localCover = false,
  }) async {
    const String bookKey = 'imported-series';
    final String extractDir = p.join(root.path, 'downloads', bookKey);
    Directory(extractDir).createSync(recursive: true);
    if (localCover) {
      File(p.join(extractDir, 'cover.jpg'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    }
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Imported series',
        epubPath: p.join(extractDir, 'pages.json'),
        extractDir: extractDir,
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String?>(_entry(coverUrl: coverUrl).encode()),
      ),
    );
    return (bookKey: bookKey, extractDir: extractDir);
  }

  Future<void> pumpSeriesPage(
    WidgetTester tester,
    AppModel appModel,
    String bookKey,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(appModel, ShelfMangaSeriesTarget(bookKey)),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('manga_series_title')),
    );
  }

  testWidgets('本地没有封面文件时，作品页封面回退到 series.coverUrl', (
    WidgetTester tester,
  ) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.test/imported-series.jpg',
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);

      final Iterable<Image> images = tester.widgetList<Image>(
        find.byType(Image),
      );
      expect(
        images.any(
          (Image image) =>
              image.image is AppCachedHttpImage &&
              (image.image as AppCachedHttpImage).url ==
                  'https://example.test/imported-series.jpg',
        ),
        isTrue,
        reason: '无本地封面时作品页必须经现有 HTTP 图片缓存显示备份里的远程封面',
      );
      expect(find.byType(MangaCoverPlaceholder), findsNothing);
    });
  });

  testWidgets('远程封面加载失败时回到占位块，不留破图或未捕获异常', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.invalid/unreachable.jpg',
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);

      // 先确认确实走了远程封面路径（否则「一开始就是占位」会让本测试假绿）。
      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isTrue,
        reason: '前置：页面应先尝试远程封面',
      );

      await pumpUntilFound(tester, find.byType(MangaCoverPlaceholder));
    });

    expect(
      tester.takeException(),
      isNull,
      reason: '远程封面加载失败必须被 errorBuilder 接住，退回现有占位块',
    );
    expect(find.byType(MangaCoverPlaceholder), findsOneWidget);
  });

  testWidgets('本地封面文件优先于远程 coverUrl（作品页）', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(
            coverUrl: 'https://example.invalid/remote.jpg',
            localCover: true,
          );
      await pumpSeriesPage(tester, appModel, row.bookKey);

      final List<Image> images = tester
          .widgetList<Image>(find.byType(Image))
          .toList(growable: false);
      expect(
        images.any(
          (Image image) =>
              image.image is FileImage &&
              (image.image as FileImage).file.path ==
                  p.join(row.extractDir, 'cover.jpg'),
        ),
        isTrue,
        reason: '有本地封面文件时作品页必须继续显示它',
      );
      expect(
        images.any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '本地封面不得被远程 coverUrl 覆盖',
      );
      expect(find.byType(MangaCoverPlaceholder), findsNothing);
    });
  });

  testWidgets('coverUrl 为空时直接显示占位块，不发起远程取图', (WidgetTester tester) async {
    final _FakeAdapter adapter = _FakeAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final ({String bookKey, String extractDir}) row =
          await insertImportedSeries(coverUrl: '   ');
      await pumpSeriesPage(tester, appModel, row.bookKey);

      expect(
        tester
            .widgetList<Image>(find.byType(Image))
            .any((Image image) => image.image is AppCachedHttpImage),
        isFalse,
        reason: '空 coverUrl 不得伪造可加载的远程封面',
      );
      expect(find.byType(MangaCoverPlaceholder), findsOneWidget);
    });
  });
}
