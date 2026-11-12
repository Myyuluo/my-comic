import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/manga/manga_library_page.dart';
import 'package:my_comic/src/models/preferences_repository.dart';
import 'package:my_comic/src/utils/components/my_comic_floating_chrome.dart'
    show MyComicShellInlineTitle;
import 'package:my_comic/utils.dart';
import 'package:my_comic_engine/media/manga/bookmark_repository.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 漫画页页面级测试的公共夹具。
///
/// 挂真实页面（默认 [MangaLibraryPage]：壳 + 书架页），书架列表 provider 受控，
/// 标签 / 阅读历史走真实 37 表内存 DB，path_provider 指向测试临时目录（封面不
/// 碰真 I/O）。夹具只装配环境，不替测试断言——各测试仍按用户可见结果自己断言。
///
/// 复审（2026-11-09，manga-library-layout-polish）：这组页面测试此前各自抄了
/// 一份 path_provider mock / DB / AppModel / buildApp / seedManga / pumpPage，
/// 收敛到这里；新页面测试直接复用，不再复制骨架。
class MangaLibraryPageHarness<M extends AppModel> {
  MangaLibraryPageHarness._({
    required this.pathProviderDir,
    required this.db,
    required this.prefs,
    required this.appModel,
    required this.storeDir,
  });

  static Directory? _pathProviderDir;

  /// 安装 path_provider 的测试 mock；每个测试文件在 `setUpAll` 调一次。
  static void setUpPathProvider(
    TestWidgetsFlutterBinding binding, {
    required String tempPrefix,
  }) {
    _pathProviderDir = Directory.systemTemp.createTempSync(tempPrefix);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => _pathProviderDir!.path,
    );
  }

  /// 卸载 path_provider mock 并删除临时目录；每个测试文件在 `tearDownAll` 调一次。
  static void tearDownPathProvider(TestWidgetsFlutterBinding binding) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    final Directory? dir = _pathProviderDir;
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
    _pathProviderDir = null;
  }

  /// 新建一套数据库 / 偏好 / AppModel / 临时目录。
  ///
  /// 需要记录打开调用的测试用 [appModelFactory] 传入自己的构造器（如
  /// [RecordingAppModel]）；默认是真实 [AppModel]。
  static Future<MangaLibraryPageHarness<M>> create<M extends AppModel>({
    required String tempPrefix,
    M Function()? appModelFactory,
  }) async {
    final Directory pathProviderDir =
        _pathProviderDir ??
        (throw StateError('先调用 MangaLibraryPageHarness.setUpPathProvider'));
    LocaleSettings.setLocale(AppLocale.zhCn);
    final MyComicDatabase db = MyComicDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory storeDir = Directory.systemTemp.createTempSync(tempPrefix);
    final M appModel = appModelFactory != null
        ? appModelFactory()
        : AppModel(testPlatformServices()) as M;
    appModel
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
    return MangaLibraryPageHarness<M>._(
      pathProviderDir: pathProviderDir,
      db: db,
      prefs: prefs,
      appModel: appModel,
      storeDir: storeDir,
    );
  }

  /// mock 后的 path_provider 根目录。
  final Directory pathProviderDir;

  final MyComicDatabase db;
  final PreferencesRepository prefs;
  final M appModel;
  final Directory storeDir;

  /// 受控书架列表；[seedManga] 追加，provider override 直接喂它。
  final List<MediaItem> mangaItems = <MediaItem>[];

  /// 关闭数据库并删除临时目录。
  Future<void> dispose() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 插入一本漫画书（37 表 EpubBooks 行 + 受控 MediaItem），返回书 uid
  /// （给 [seedRecency] 用）。
  Future<String> seedManga(
    String bookKey,
    String title, {
    int position = 0,
    int duration = 1,
    int chapterCount = 0,
    String mediaTypeIdentifier = 'reader_media_type',
  }) async {
    final String uid = 'uid_$bookKey';
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        uid: Value<String>(uid),
        title: title,
        epubPath: '${pathProviderDir.path}/$bookKey/manga.json',
        extractDir: '${pathProviderDir.path}/$bookKey',
        chapterCount: chapterCount,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
      ),
    );
    mangaItems.add(
      MediaItem(
        mediaIdentifier: ReaderMyComicSource.mediaIdentifierFor(bookKey),
        title: title,
        mediaTypeIdentifier: mediaTypeIdentifier,
        mediaSourceIdentifier: MangaMyComicSource.kUniqueKey,
        position: position,
        duration: duration,
        canDelete: false,
        canEdit: true,
      ),
    );
    return uid;
  }

  /// 写一条阅读位置（继续阅读候选按 lastReadAt 选最近读的那本）。
  Future<void> seedRecency(String uid, int updatedAt) async {
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: uid,
        sectionIndex: 0,
        normCharOffset: 0,
        updatedAt: updatedAt,
      ),
    );
  }

  /// 在 [title]/[child] 外壳里挂 [child]：与生产一致的外壳标题 / 内联标题
  /// scope + 受控 provider。
  ///
  /// [overrideBooks] = false 时不覆写 [myComicBooksProvider]：页面走真实的
  /// `ReaderMyComicSource.getBooksFromDb` + 真 DB（Library membership 过滤等
  /// 数据层行为的页面级验证用）。
  Widget buildScaffold({
    required String title,
    required Widget child,
    bool overrideBooks = true,
    ThemeData? theme,
  }) {
    return ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((ref) => appModel),
        if (overrideBooks)
          myComicBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(mangaItems),
          ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: MyComicShellTitleScope(
              title: title,
              child: MyComicShellInlineTitle(enabled: true, child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 漫画页（壳 + 书架页）的完整 app。
  Widget buildApp({bool overrideBooks = true, ThemeData? theme}) =>
      buildScaffold(
        title: t.manga_library,
        child: const MangaLibraryPage(),
        overrideBooks: overrideBooks,
        theme: theme,
      );

  /// 设置测试窗口尺寸后挂 [buildApp] 并 settle。
  ///
  /// 只适用于受控书架列表（[buildApp] 默认 override）；真实 provider 的页面
  /// 加载动效无限循环，测试需自行固定帧推进（见 `manga_library_membership_test`）。
  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1400, 1200),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(theme: theme));
    await tester.pumpAndSettle();
  }
}

/// 记录 [AppModel.openMedia] 调用的页面级假模型（继续阅读点击断言用）。
class RecordingAppModel extends AppModel {
  RecordingAppModel() : super(testPlatformServices());

  final List<MediaItem?> opened = <MediaItem?>[];

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
    opened.add(item);
  }
}
