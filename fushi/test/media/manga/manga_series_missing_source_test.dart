import 'dart:io';

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
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// 票 04 页面级 seam：真实数据库 + 可控 adapter。
///
/// 来源确实未安装时，作品页显示「来源未安装：<名称>」并说明只有本机已保存的
/// 章节可用；章节打开失败给中文安装指引。缺失来源的条目仍留在 Library。
class _MissingSourceAdapter implements OnlineMangaRuntimeAdapter {
  _MissingSourceAdapter({this.label});

  /// null = 来源未安装/停用，解析不到名称（与生产 `sourceLabel` 一致）。
  final String? label;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => label;

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async => throw const OnlineMangaUnavailable(
    OnlineMangaUnavailableReason.sourceDisabled,
    'The manga source is missing or disabled',
  );

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) => throw const OnlineMangaUnavailable(
    OnlineMangaUnavailableReason.sourceDisabled,
    'The manga source is missing or disabled',
  );

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        'The manga source is missing or disabled',
      );

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
  final List<MediaItem?> opened = <MediaItem?>[];

  /// 让真实 openMedia 的阅读器内部失败变成作品页可见的章节打开失败。
  bool failOpen = false;

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
  }) async {
    if (failOpen) {
      throw const OnlineMangaUnavailable(
        OnlineMangaUnavailableReason.sourceDisabled,
        'The manga source is missing or disabled',
      );
    }
    opened.add(item);
  }
}

Widget _harness(
  AppModel appModel,
  String bookKey, {
  GlobalKey<NavigatorState>? navigatorKey,
}) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((Ref ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      navigatorKey: navigatorKey,
      home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
    ),
  ),
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

OnlineMangaLibraryEntry _placeholderEntry({String? sourceName}) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: kUnavailableMihonExtensionPackage,
      sourceId: '524579092615598717',
      sourceName: sourceName,
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
    );

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    root = await Directory.systemTemp.createTemp('manga_series_missing_');
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

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('来源缺失：显示「来源未安装：<名称>」、说明与缓存章节，不显示内部占位值', (
    WidgetTester tester,
  ) async {
    sizeView(tester);
    final _MissingSourceAdapter adapter = _MissingSourceAdapter();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: adapter,
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late EpubBookRow row;

    await tester.runAsync(() async {
      row = await library.add(_placeholderEntry(sourceName: '再漫画'));
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);
    });

    expect(
      find.text('来源未安装：再漫画'),
      findsWidgets,
      reason: '来源标签使用备份名称，而不是 mihon.unavailable',
    );
    expect(
      find.text(kUnavailableMihonExtensionPackage),
      findsNothing,
      reason: '内部占位包名不得出现在界面上',
    );
    expect(
      find.text(t.manga_series_source_missing_hint),
      findsOneWidget,
      reason: '说明当前只有本机已保存的章节，刷新/阅读需要安装扩展',
    );
    expect(find.text('Chapter 1'), findsOneWidget, reason: '已保存章节照常显示');
    expect(find.text('Chapter 2'), findsOneWidget);

    // 条目仍留在 Library：没有隐藏/删除。
    final List<EpubBookRow> books = await db.getAllEpubBooks();
    expect(books, hasLength(1));
    expect(books.single.bookKey, row.bookKey);
    expect(books.single.uid, row.uid);
  });

  testWidgets('旧条目没有来源名称：退化为「来源未安装」', (WidgetTester tester) async {
    sizeView(tester);
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _MissingSourceAdapter(),
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_placeholderEntry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);
    });

    expect(find.text(t.manga_series_source_missing), findsWidgets);
    expect(find.text(kUnavailableMihonExtensionPackage), findsNothing);
    expect(find.text(t.manga_series_source_missing_hint), findsOneWidget);
    expect(find.text('Chapter 1'), findsOneWidget);
  });

  testWidgets('来源已恢复解析：显示真实来源名，不再显示缺失来源提示', (WidgetTester tester) async {
    sizeView(tester);
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _MissingSourceAdapter(label: '再漫画'),
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root);

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _placeholderEntry(sourceName: '备份旧名'),
      );
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('再漫画'));
      await _settle(tester);
    });

    expect(find.text('再漫画'), findsWidgets);
    expect(find.text('来源未安装：备份旧名'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('manga_series_missing_source_notice')),
      findsNothing,
    );
    expect(find.text(kUnavailableMihonExtensionPackage), findsNothing);
  });

  testWidgets('章节打开失败：提示中文「来源未安装，请先安装对应扩展后重试」', (WidgetTester tester) async {
    sizeView(tester);
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _MissingSourceAdapter(),
    );
    final _TestAppModel appModel = _TestAppModel(db, library, root)
      ..failOpen = true;

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(
        _placeholderEntry(sourceName: '再漫画'),
      );
      await tester.pumpWidget(
        _harness(appModel, row.bookKey, navigatorKey: navKey),
      );
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);

      await tester.tap(find.text('Chapter 1'));
      await _settle(tester);
    });

    expect(
      find.text(t.online_source_error_source_disabled),
      findsOneWidget,
      reason: '章节打开失败给中文安装指引，而不是英文内部错误',
    );
    expect(
      find.textContaining('The manga source is missing or disabled'),
      findsNothing,
    );
    await tester.pump(const Duration(seconds: 3));
  });
}
