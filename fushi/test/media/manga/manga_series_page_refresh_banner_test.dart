import 'dart:io';

import 'package:drift/native.dart';
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
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// 刷新失败横幅文案（ticket 05）。
///
/// 页面级 seam：真实 37 表 `FushiDatabase` + 可控 adapter（按失败原因抛
/// [OnlineMangaUnavailable]）+ 真实偏好库。断言只落在用户可见的横幅标题、
/// 副标题与动作上，不碰横幅内部的实现结构。
class _FailingAdapter implements OnlineMangaRuntimeAdapter {
  _FailingAdapter(this.reason, {this.supported = true});

  final OnlineMangaUnavailableReason reason;
  final bool supported;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => supported;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      'Fake source';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async {
    throw OnlineMangaUnavailable(reason, 'fixture failure for ${reason.name}');
  }

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
    // 本测试只验证作品页横幅，不让它真的 push 阅读页。
  }
}

OnlineMangaLibraryEntry _seed() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: <OnlineMangaChapter>[],
);

Widget _harness(AppModel appModel, MangaSeriesTarget target) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: MangaSeriesPage(target: target)),
  ),
);

const String _runtimeFailureTitle = '无法获取漫画信息，请重试或查看详情';
const String _sourceDisabledTitle = '该来源未安装或已停用';
const String _platformUnsupportedTitle = '该来源运行时在本平台不可用';

/// ticket 05 要求删除的旧副标题；zh-CN 原文作为独立真值，避免依赖已删的 key。
const String _removedOfflineHint = '显示的是本机已保存的章节';

const String _retryLabel = '重试';
const String _viewDetailsLabel = '查看详情';

void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    // 横幅文案按 zh-CN 断言：spec 锁定的是中文原文，不依赖某条 locale 的措辞。
    LocaleSettings.setLocale(AppLocale.zhCn);
    root = await Directory.systemTemp.createTemp('manga_series_banner_');
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

  Future<void> pumpFailureBanner(
    WidgetTester tester,
    OnlineMangaRuntimeAdapter adapter,
    OnlineMangaLibraryService library,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _harness(
        appModel,
        SourceMangaSeriesTarget(
          adapter: adapter,
          seed: _seed(),
          service: library,
          sourceLabel: 'Fake source',
        ),
      ),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('manga_series_title')),
    );
    await pumpUntilFound(
      tester,
      find.byKey(const ValueKey<String>('manga_series_refresh_banner')),
    );
  }

  OnlineMangaLibraryService libraryFor(OnlineMangaRuntimeAdapter adapter) =>
      OnlineMangaLibraryService(
        database: db,
        rootDirectory: Directory(p.join(root.path, 'legacy')),
        adapter: adapter,
      );

  testWidgets('运行时刷新失败：标题给出下一步，且不再显示本机章节副标题', (WidgetTester tester) async {
    final _FailingAdapter adapter = _FailingAdapter(
      OnlineMangaUnavailableReason.runtimeFailure,
    );
    final Finder banner = find.byKey(
      const ValueKey<String>('manga_series_refresh_banner'),
    );

    await tester.runAsync(() async {
      await pumpFailureBanner(tester, adapter, libraryFor(adapter));
    });

    expect(
      find.descendant(of: banner, matching: find.text(_runtimeFailureTitle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: banner, matching: find.text(_removedOfflineHint)),
      findsNothing,
      reason: '无论失败原因是什么，本机章节副标题都不再显示',
    );
    expect(
      find.descendant(of: banner, matching: find.text(_retryLabel)),
      findsOneWidget,
      reason: '运行时失败仍可重试',
    );
    expect(
      find.descendant(of: banner, matching: find.text(_viewDetailsLabel)),
      findsOneWidget,
      reason: '查看详情动作保持不变',
    );
  });

  testWidgets('来源停用：保留原因标题，不显示本机章节副标题，也不给重试', (WidgetTester tester) async {
    final _FailingAdapter adapter = _FailingAdapter(
      OnlineMangaUnavailableReason.sourceDisabled,
    );
    final Finder banner = find.byKey(
      const ValueKey<String>('manga_series_refresh_banner'),
    );

    await tester.runAsync(() async {
      await pumpFailureBanner(tester, adapter, libraryFor(adapter));
    });

    expect(
      find.descendant(of: banner, matching: find.text(_sourceDisabledTitle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: banner, matching: find.text(_removedOfflineHint)),
      findsNothing,
    );
    expect(
      find.descendant(of: banner, matching: find.text(_retryLabel)),
      findsNothing,
      reason: '来源停用重试永远不会成功，可见性规则不变',
    );
    expect(
      find.descendant(of: banner, matching: find.text(_viewDetailsLabel)),
      findsOneWidget,
    );
  });

  testWidgets('平台不支持：保留原因标题，不显示本机章节副标题，也不给重试', (WidgetTester tester) async {
    final _FailingAdapter adapter = _FailingAdapter(
      OnlineMangaUnavailableReason.runtimeFailure,
      supported: false,
    );
    final Finder banner = find.byKey(
      const ValueKey<String>('manga_series_refresh_banner'),
    );

    await tester.runAsync(() async {
      await pumpFailureBanner(tester, adapter, libraryFor(adapter));
    });

    expect(
      find.descendant(
        of: banner,
        matching: find.text(_platformUnsupportedTitle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: banner, matching: find.text(_removedOfflineHint)),
      findsNothing,
    );
    expect(
      find.descendant(of: banner, matching: find.text(_retryLabel)),
      findsNothing,
      reason: '平台不支持重试永远不会成功，可见性规则不变',
    );
    expect(
      find.descendant(of: banner, matching: find.text(_viewDetailsLabel)),
      findsOneWidget,
    );
  });
}
