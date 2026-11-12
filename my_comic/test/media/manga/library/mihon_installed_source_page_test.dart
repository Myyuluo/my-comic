import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/manga/library/manga_series_page.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_service.dart';
import 'package:my_comic/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_manager.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_models.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_runtime.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_source_browse_page.dart';
import 'package:my_comic/src/media/media_item.dart';
import 'package:my_comic/src/media/media_source.dart';
import 'package:my_comic/src/models/preferences_repository.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic_engine/media/manga/bookmark_repository.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:path/path.dart' as p;

import '../../../helpers/test_platform_services.dart';

/// 票 03 页面级验收：导入时扩展未安装、条目以 `mihon.unavailable` 占位；
/// 扩展安装/启用后，直接从书架打开作品页即可刷新出章节，来源名显示真实来源，
/// 条目身份（bookKey / uid / extensionPackage）保持不变。
void main() {
  const String realPackage = 'eu.kanate.tachiyomi.extension.zh.zaimanhua';
  const String realSourceId = '524579092615598717';
  const String realSourceName = '再漫画';
  const String seriesKey = '/manga/123456';

  late Directory root;
  late MyComicDatabase database;
  late _PageRuntime runtime;
  late MihonManager manager;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp(
      'mycomic-installed-source-page-',
    );
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => p.join(root.path, call.method),
        );
    database = MyComicDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(database);
    runtime = _PageRuntime();

    await database.upsertMangaExtension(
      MangaExtensionsCompanion.insert(
        packageName: realPackage,
        name: '$realPackage extension',
        versionCode: 1,
        versionName: '1.0.0',
        libVersion: '1.6',
        language: 'zh',
        apkPath: 'extensions/$realPackage.ext',
        apkSha256: 'apk-sha',
        signerSha256: 'signer-sha',
        enabled: const Value<bool>(true),
        installedAt: 1,
      ),
    );
    await database
        .replaceMangaOnlineSources(realPackage, <MangaOnlineSourcesCompanion>[
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: realPackage,
            sourceId: realSourceId,
            name: realSourceName,
            language: 'zh',
            baseUrl: const Value<String>('https://example.invalid'),
          ),
        ]);

    manager = MihonManager(
      database: database,
      rootDirectory: Directory(p.join(root.path, 'mihon')),
      runtime: runtime,
    );
    await manager.initialise();
  });

  tearDown(() async {
    manager.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await database.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('占位来源的导入作品：安装扩展后书架作品页可直接刷新并显示真实来源', (WidgetTester tester) async {
    final OnlineMangaLibraryService service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: MihonLibraryAdapter(manager),
    );
    final _TestAppModel appModel = _TestAppModel(database, service, root);
    late EpubBookRow row;
    await tester.runAsync(() async {
      // 导入时扩展未安装：占位扩展包、真实数字 sourceId、空章节（待刷新）。
      row = await service.add(
        const OnlineMangaLibraryEntry(
          runtime: OnlineMangaRuntimeKind.mihon,
          extensionPackage: kUnavailableMihonExtensionPackage,
          sourceId: realSourceId,
          series: OnlineMangaSeries(
            key: seriesKey,
            title: 'Fixture series',
            raw: <String, Object?>{'url': seriesKey, 'title': 'Fixture series'},
          ),
          chapters: <OnlineMangaChapter>[],
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            platformServicesProvider.overrideWithValue(testPlatformServices()),
            appProvider.overrideWith((Ref ref) => appModel),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: MangaSeriesPage(
                target: ShelfMangaSeriesTarget(row.bookKey),
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Chapter 1'));
    });

    expect(
      find.text('Chapter 1'),
      findsOneWidget,
      reason: '刷新经数字 sourceId 回退到已安装的 Source，章节应出现',
    );
    expect(
      find.text(realSourceName),
      findsWidgets,
      reason: '来源名解析回退到真实 Source，而不是 mihon.unavailable',
    );
    expect(find.text(kUnavailableMihonExtensionPackage), findsNothing);

    late EpubBookRow? stored;
    late List<EpubBookRow> allBooks;
    await tester.runAsync(() async {
      stored = await database.getEpubBook(row.bookKey);
      allBooks = await database.getAllEpubBooks();
    });
    expect(stored, isNotNull);
    expect(allBooks, hasLength(1), reason: '刷新只更新原条目，不得另建一本');
    final EpubBookRow storedRow = stored!;
    expect(storedRow.uid, row.uid, reason: 'uid 不变，阅读进度与 History 无需迁移');
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      storedRow.sourceMetadata,
    )!;
    expect(
      entry.extensionPackage,
      kUnavailableMihonExtensionPackage,
      reason: '运行时回退不改写存量条目的扩展包身份',
    );
    expect(entry.sourceId, realSourceId);
    expect(entry.chapters.single.key, '/chapter/1');
    expect(runtime.lastDetailsSource?.id, realSourceId);
  });

  testWidgets('从已安装来源浏览到占位条目的同一作品：命中已有条目，不重复入库', (WidgetTester tester) async {
    final OnlineMangaLibraryService service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: MihonLibraryAdapter(manager),
    );
    late EpubBookRow placeholder;
    await tester.runAsync(() async {
      placeholder = await service.add(
        const OnlineMangaLibraryEntry(
          runtime: OnlineMangaRuntimeKind.mihon,
          extensionPackage: kUnavailableMihonExtensionPackage,
          sourceId: realSourceId,
          series: OnlineMangaSeries(
            key: seriesKey,
            title: 'Fixture series',
            raw: <String, Object?>{'url': seriesKey, 'title': 'Fixture series'},
          ),
          chapters: <OnlineMangaChapter>[
            OnlineMangaChapter(
              key: '/chapter/1',
              name: 'Chapter 1',
              raw: <String, Object?>{'url': '/chapter/1'},
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: MihonSourceBrowsePage(
            manager: manager,
            target: MihonInstalledTarget(manager.sources.single),
          ),
        ),
      );
      await _pumpUntil(tester, find.text('Fixture series'));
      await tester.tap(find.text('Fixture series'));
      await _pumpUntil(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_remove_from_bookshelf'),
        ),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_add_to_bookshelf')),
      findsNothing,
      reason: 'find 按 (sourceId, series key) 命中占位条目，页面应处于已在库状态',
    );
    expect(
      find.byKey(const ValueKey<String>('manga_series_remove_from_bookshelf')),
      findsOneWidget,
    );

    late List<EpubBookRow> allBooks;
    await tester.runAsync(() async {
      allBooks = await database.getAllEpubBooks();
    });
    expect(allBooks, hasLength(1), reason: '不得为同一作品新建第二条 Library 条目');
    expect(allBooks.single.bookKey, placeholder.bookKey);
    expect(allBooks.single.uid, placeholder.uid);
  });
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 300; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('never found $finder');
}

class _PageRuntime extends Fake implements MihonRuntime {
  MihonSource? lastDetailsSource;

  @override
  Future<List<MihonFilter>> getFilters(
    MihonExtensionRef extension,
    MihonSource source, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => const <MihonFilter>[];

  @override
  Future<MihonMangaPage> getPopular(
    MihonExtensionRef extension,
    MihonSource source, {
    required int page,
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => const MihonMangaPage(
    items: <MihonManga>[
      MihonManga(url: '/manga/123456', title: 'Fixture series'),
    ],
    hasNextPage: false,
  );

  @override
  Future<MihonManga> getDetails(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async {
    lastDetailsSource = source;
    return MihonManga(
      url: manga.url,
      title: 'Fixture series',
      coverUrl: 'https://example.invalid/cover.jpg',
    );
  }

  @override
  Future<List<MihonChapter>> getChapters(
    MihonExtensionRef extension,
    MihonSource source,
    MihonManga manga, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => const <MihonChapter>[
    MihonChapter(
      url: '/chapter/1',
      name: 'Chapter 1',
      uploadedAt: 1,
      number: 1,
    ),
  ];

  @override
  Future<Uint8List> fetchSourceImage(
    MihonExtensionRef extension,
    MihonSource source,
    String url, {
    List<MihonPreference> preferences = const <MihonPreference>[],
  }) async => Uint8List.fromList(<int>[0xff, 0xd8, 0xff]);

  @override
  Future<void> dispose() async {}
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final MyComicDatabase _db;
  final OnlineMangaLibraryService _library;

  @override
  MyComicDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  @override
  MihonManager get mihonManager {
    throw UnsupportedError('not used by the shelf series page test');
  }

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
