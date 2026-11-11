import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_flow.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../backup_import/mihon_backup_fixture.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 05：`.tachibk` 导入成功后，漫画页的 Tag 页签 / 数量 / 归属立即刷新。
///
/// 页面级 seam（同 [manga_library_tag_tabs_test]）：挂真实漫画书架
/// `ReaderFushiHistoryPage(mangaOnly: true)` + 真 37 表内存 DB，从同一个
/// ProviderScope 里触发真实的 [runMihonBackupImport]（合成 fixture，不走网络）。
/// 断言只落在用户可见结果上：页签是否出现、数量、哪些卡在哪个页签、当前选中
/// 页签，以及失败 / 取消 / 零 Tag / 重复导入的边界。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory installDir;
  late AppPaths paths;

  setUpAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late Directory storeDir;
  late Directory backupDir;
  FilePicker? previousPicker;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('fushi_tag_refresh_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'install'))..createSync();
    AppPaths.debugExecutablePathOverride = p.join(
      installDir.path,
      'my_comic.exe',
    );
    AppPaths.debugLocalAppDataOverride = p.join(tmp.path, 'LocalAppData');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getApplicationDocumentsDirectory':
            return platformDocuments.path;
          case 'getApplicationSupportDirectory':
            return p.join(tmp.path, 'AppData');
          case 'getTemporaryDirectory':
            return p.join(tmp.path, 'systemp');
        }
        return null;
      },
    );
    paths = await AppPaths.resolve();

    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_tag_refresh_store');
    backupDir = Directory.systemTemp.createTempSync('fushi_tag_refresh_backup');
    appModel = _PathsTestAppModel(paths)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();

    FilePicker? original;
    try {
      original = FilePicker.platform;
    } catch (_) {
      original = null;
    }
    previousPicker = original;
  });

  tearDown(() async {
    if (previousPicker != null) {
      FilePicker.platform = previousPicker!;
    }
    AppPaths.debugExecutablePathOverride = null;
    AppPaths.debugLocalAppDataOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    await db.close();
    for (final Directory dir in <Directory>[storeDir, backupDir, tmp]) {
      if (dir.existsSync()) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  void usePicker(String? path) {
    FilePicker.platform = _RecordingFilePicker(resultPath: path);
  }

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((ref) => appModel),
      srtBooksProvider.overrideWith(
        (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              Consumer(
                builder: (BuildContext context, WidgetRef ref, Widget? _) =>
                    TextButton(
                      key: const ValueKey<String>('trigger_import'),
                      onPressed: () => unawaited(
                        runMihonBackupImport(
                          SettingsContext(
                            context: context,
                            appModel: appModel,
                            ref: ref,
                            readerSource: ReaderFushiSource.instance,
                            refresh: () {},
                          ),
                        ),
                      ),
                      child: const Text('import'),
                    ),
              ),
              Expanded(
                child: ReaderFushiHistoryPage(
                  mangaOnly: true,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  /// 在用例体内卸载页面：ProviderScope 释放 Drift watch stream 时会排一个
  /// 零时长定时器，FakeAsync 收尾前要把这个定时器跑掉（同 `downloads_page_test`
  /// 的 `_unmount`），否则框架报「A Timer is still pending even after the
  /// widget tree was disposed」。
  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> triggerImport(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('trigger_import')));
    await tester.pumpAndSettle();
    // 导入落库后，书架的 `fushiBooksProvider` 靠 Drift 的 watch stream 自动重算；
    // stream 事件由真实事件循环投递，FakeAsync 的 pump 收不到。放行一次真实
    // async，再 pump 让新书架渲染出来。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
  }

  Finder shelfSegment() =>
      find.byKey(const ValueKey<String>('manga_tag_tab_shelf'));

  Finder tagSegment(int tagId) =>
      find.byKey(ValueKey<String>('manga_tag_tab_$tagId'));

  Finder tagCountSegments() => find.byWidgetPredicate(
    (Widget widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'manga_tag_tab_count_',
        ),
  );

  Finder segmentCount(String scope) =>
      find.byKey(ValueKey<String>('manga_tag_tab_count_$scope'));

  String countText(WidgetTester tester, String scope) =>
      tester.widget<Text>(segmentCount(scope)).data!;

  Finder mangaCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderFushiSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  Future<String> bookKeyForTitle(String title) async {
    final List<EpubBookMeta> metas = await db.getEpubBookMetas();
    return metas
        .singleWhere((EpubBookMeta meta) => meta.title == title)
        .bookKey;
  }

  testWidgets('导入成功后标签页签、数量与归属立即刷新（报告弹窗显示期间书架已是最新）', (
    WidgetTester tester,
  ) async {
    // 合成 fixture 要写真实文件；widget 测试体跑在 FakeAsync 里，真实 IO 必须
    // 经 runAsync 走真实事件循环（导入本身用 readAsBytesSync，不需要）。
    final File backup = (await tester.runAsync(
      () => writeFixtureBackup(
        backupDir,
        categories: const <FixtureCategory>[
          FixtureCategory(name: '连载', order: 0, id: 10),
        ],
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/tagged',
            title: '连载作品',
            categoryOrders: <int>[0],
          ),
          FixtureManga(source: 123, url: '/manga/untagged', title: '独立作品'),
        ],
      ),
    ))!;
    usePicker(backup.path);
    await pumpPage(tester);

    expect(shelfSegment(), findsOneWidget);
    expect(tagCountSegments(), findsOneWidget, reason: '导入前只有「书架」页签');

    await triggerImport(tester);

    // 导入完成报告弹窗正在显示；背后的书架必须已经是最新状态。
    expect(find.text(t.dialog_done), findsOneWidget);
    final List<BookTagRow> tags = await db.getAllTags();
    expect(tags, hasLength(1));
    final int tagId = tags.single.id;
    expect(tagSegment(tagId), findsOneWidget, reason: '导入后标签页签立即出现');
    expect(countText(tester, '$tagId'), '1', reason: '页签数量立即正确');
    expect(countText(tester, 'shelf'), '1');

    final String taggedKey = await bookKeyForTitle('连载作品');
    final String untaggedKey = await bookKeyForTitle('独立作品');
    expect(mangaCard(taggedKey), findsNothing, reason: '带 Tag 的作品立即离开「书架」');
    expect(mangaCard(untaggedKey), findsOneWidget);

    // 报告弹窗是模态的：关闭后才能切页签；关闭时书架已是上面断言的最新状态。
    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    expect(tagSegment(tagId), findsOneWidget, reason: '关闭报告后页签仍在');

    await tester.tap(tagSegment(tagId));
    await tester.pumpAndSettle();
    expect(mangaCard(taggedKey), findsOneWidget);
    expect(mangaCard(untaggedKey), findsNothing);

    await disposePage(tester);
  });

  testWidgets('导入失败不触发标签刷新', (WidgetTester tester) async {
    await pumpPage(tester);
    // 页面挂载时 provider 缓存了空标签池；此后直接写库（不经页面）不会让缓存
    // 失效。失败导入若错误地刷新，这个标签就会突然出现。
    final int tagId = await db.createTag('导入前已有', 0xFF112233);
    expect(
      tagSegment(tagId),
      findsNothing,
      reason: '直接写库不会让缓存的标签 provider 自动刷新',
    );

    final File broken = (await tester.runAsync(() async {
      final File file = File(p.join(backupDir.path, 'broken.tachibk'));
      await file.writeAsString('not a tachibk');
      return file;
    }))!;
    usePicker(broken.path);
    await triggerImport(tester);

    expect(find.text(t.dialog_done), findsOneWidget, reason: '失败结果弹窗出现');
    expect(tagSegment(tagId), findsNothing, reason: '失败导入没有数据变化，不刷新');

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await disposePage(tester);
  });

  testWidgets('取消选择备份文件不触发标签刷新', (WidgetTester tester) async {
    await pumpPage(tester);
    final int tagId = await db.createTag('导入前已有', 0xFF112233);
    expect(tagSegment(tagId), findsNothing);

    usePicker(null);
    await tester.tap(find.byKey(const ValueKey<String>('trigger_import')));
    await tester.pumpAndSettle();

    expect(find.text(t.dialog_done), findsNothing, reason: '取消后不弹任何结果');
    expect(tagSegment(tagId), findsNothing, reason: '取消没有数据变化，不刷新');

    await disposePage(tester);
  });

  testWidgets('有分类但零 Library 条目的导入也立即刷新标签页签', (WidgetTester tester) async {
    // 分类已经写成 Tag，但备份没有任何 favorite 条目：报告会因 totalEntries == 0
    // 被视为「空」，标签页签仍必须刷新，否则用户看不到新建的 Tag。
    final File backup = (await tester.runAsync(
      () => writeFixtureBackup(
        backupDir,
        categories: const <FixtureCategory>[
          FixtureCategory(name: '连载', order: 0, id: 10),
        ],
        mangas: const <FixtureManga>[],
      ),
    ))!;
    usePicker(backup.path);
    await pumpPage(tester);

    expect(tagCountSegments(), findsOneWidget, reason: '导入前只有「书架」页签');
    await triggerImport(tester);

    expect(find.text(t.dialog_done), findsOneWidget);
    final List<BookTagRow> tags = await db.getAllTags();
    expect(tags.map((BookTagRow tag) => tag.name), <String>['连载']);
    expect(
      tagSegment(tags.single.id),
      findsOneWidget,
      reason: '分类已写成 Tag，即使没有 Library 条目也必须刷新标签页签',
    );

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await disposePage(tester);
  });

  testWidgets('零 Tag 备份导入后仍只有「书架」页签', (WidgetTester tester) async {
    final File backup = (await tester.runAsync(
      () => writeFixtureBackup(
        backupDir,
        mangas: const <FixtureManga>[
          FixtureManga(source: 123, url: '/manga/a', title: '作品甲'),
          FixtureManga(source: 123, url: '/manga/b', title: '作品乙'),
        ],
      ),
    ))!;
    usePicker(backup.path);
    await pumpPage(tester);

    await triggerImport(tester);

    expect(find.text(t.dialog_done), findsOneWidget);
    expect(shelfSegment(), findsOneWidget);
    expect(tagCountSegments(), findsOneWidget, reason: '零 Tag 不出现空页签');
    expect(countText(tester, 'shelf'), '2');
    final String keyA = await bookKeyForTitle('作品甲');
    final String keyB = await bookKeyForTitle('作品乙');
    expect(mangaCard(keyA), findsOneWidget);
    expect(mangaCard(keyB), findsOneWidget);

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await disposePage(tester);
  });

  testWidgets('重复导入保持幂等，当前选中页签保持不变', (WidgetTester tester) async {
    final int tagId = await db.createTag('连载', 0xFF112233);
    final File backup = (await tester.runAsync(
      () => writeFixtureBackup(
        backupDir,
        categories: const <FixtureCategory>[
          FixtureCategory(name: '连载', order: 0, id: 10),
        ],
        sources: const <FixtureSource>[
          FixtureSource(id: 123, name: 'Source A'),
        ],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/new',
            title: '新连载作品',
            categoryOrders: <int>[0],
          ),
        ],
      ),
    ))!;
    usePicker(backup.path);
    await pumpPage(tester);

    expect(tagSegment(tagId), findsOneWidget);
    await tester.tap(tagSegment(tagId));
    await tester.pumpAndSettle();
    expect(countText(tester, '$tagId'), '0');

    await triggerImport(tester);

    expect(find.text(t.dialog_done), findsOneWidget);
    expect((await db.getAllTags()).map((BookTagRow tag) => tag.name), <String>[
      '连载',
    ], reason: '同名分类匹配已有 Tag，不新建');
    expect(countText(tester, '$tagId'), '1', reason: '数量立即更新');
    expect(tagCountSegments(), findsNWidgets(2), reason: '页签不重复出现');
    final String key = await bookKeyForTitle('新连载作品');
    expect(mangaCard(key), findsOneWidget, reason: '当前选中的标签页签保持不变');

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();

    // 同一份备份再导一次：条目合并、分类匹配、Tag 分配幂等。
    await triggerImport(tester);

    expect(find.text(t.dialog_done), findsOneWidget);
    expect((await db.getAllTags()).map((BookTagRow tag) => tag.name), <String>[
      '连载',
    ]);
    expect(countText(tester, '$tagId'), '1', reason: '重复导入不重复计数');
    expect(tagCountSegments(), findsNWidgets(2));
    expect(mangaCard(key), findsOneWidget);

    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await disposePage(tester);
  });
}

class _PathsTestAppModel extends AppModel {
  _PathsTestAppModel(this._paths) : super(testPlatformServices());

  final AppPaths _paths;

  @override
  AppPaths get appPaths => _paths;
}

class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker({this.resultPath});

  final String? resultPath;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    final String? path = resultPath;
    if (path == null) return null;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: p.basename(path),
        path: path,
        size: File(path).lengthSync(),
      ),
    ]);
  }
}
