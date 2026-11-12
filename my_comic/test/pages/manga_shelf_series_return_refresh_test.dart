// Ticket 01：从作品页返回书架时主动重取书架 provider。
//
// 症状：作品页里手动刷新 / 阅读后返回书架，卡片封面仍停在旧的空白或已失效
// 远程 URL，因为返回路径只重载了 `_shelfMapsFuture`（未读角标等），没有让
// `myComicBooksProvider` 重新解析 `MediaItem`。
//
// 页面级测试：真实 37 表内存库 + 真实书架页 + 真实 `MangaSeriesPage` 路由，
// 只断言 provider 被重新执行（书架重新解析），不伸手进私有方法。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/manga/library/manga_series_page.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/models/preferences_repository.dart';
import 'package:my_comic/src/pages/implementations/reader_my_comic_history_page.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/reader_language.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../helpers/test_platform_services.dart';

const String _bookKey = 'manga_series_return_refresh';
const String _bookTitle = '返回刷新漫画';

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/return-refresh',
    title: _bookTitle,
    raw: <String, Object?>{'url': '/series/return-refresh'},
  ),
  chapters: <OnlineMangaChapter>[],
);

MediaItem _item() => MediaItem(
  mediaIdentifier: ReaderMyComicSource.mediaIdentifierFor(_bookKey),
  title: _bookTitle,
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: MangaMyComicSource.kUniqueKey,
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'my_comic_series_return_pp',
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

  late MyComicDatabase db;
  late AppModel appModel;
  late PreferencesRepository prefs;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('my_comic_series_return_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: _bookTitle,
        epubPath: p.join(pathProviderDir.path, _bookKey, 'manga.json'),
        extractDir: p.join(pathProviderDir.path, _bookKey),
        chapterCount: 0,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(_entry().encode()),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  /// 让真实异步（DB 读、路由）落地；fake 时钟推不动它们。
  Future<void> pumpRealAsync(WidgetTester tester, {int steps = 40}) async {
    await tester.runAsync(() async {
      for (int i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('从作品页返回书架：重新执行 myComicBooksProvider 解析新封面', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1400);
    addTearDown(tester.view.reset);

    int booksLoads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
          appProvider.overrideWith((Ref ref) => appModel),
          myComicBooksProvider.overrideWith((Ref ref, Language language) {
            booksLoads++;
            return Future<List<MediaItem>>.value(<MediaItem>[_item()]);
          }),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: ReaderMyComicHistoryPage(mangaOnly: true)),
          ),
        ),
      ),
    );
    await pumpRealAsync(tester);
    final int loadsBeforeReturn = booksLoads;
    expect(loadsBeforeReturn, greaterThan(0), reason: '书架首屏必须执行一次 provider');

    final Finder card = find.byKey(
      ValueKey<String>('book_entry_${_item().mediaIdentifier}'),
    );
    expect(card, findsOneWidget);
    await tester.tap(card);
    await pumpRealAsync(tester);
    expect(find.byType(MangaSeriesPage), findsOneWidget, reason: '点击漫画卡应进入作品页');

    // 模拟用户按返回：pop 作品页，await push 返回后书架走「从作品页返回」分支。
    Navigator.of(tester.element(find.byType(MangaSeriesPage))).pop();
    await pumpRealAsync(tester);

    expect(find.byType(MangaSeriesPage), findsNothing);
    expect(
      booksLoads,
      greaterThan(loadsBeforeReturn),
      reason:
          '从作品页返回必须 invalidate 书架 provider，重新解析封面；'
          '只刷新 shelf maps 不足以让卡片读取新的持久缓存封面',
    );
  });
}
