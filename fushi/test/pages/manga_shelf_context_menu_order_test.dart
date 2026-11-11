// 长按 / 右键漫画卡的菜单排布（2026-11-05 漫画页 UI 修正）。
//
// 用户口径：编辑信息排第一；不再出现重命名；删除从危险区挪到列表末位，但必须
// 保留红色危险样式、点击后仍走原有删除确认；作品页「管理本卷」复用同一份菜单。
//
// 这是页面级测试：真实 37 表内存库 + 真实 Manifest 页面，长按卡片打开菜单，
// 只断言用户可见的文案、顺序、颜色与弹窗，不伸手进私有方法。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

const String _bookKey = 'manga_menu_volume';

MediaItem _mangaItem() => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(_bookKey),
  title: 'Alpha卷',
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

/// 等异步 DB 读完成并推进一帧（作品页 _load 是真实异步）。
Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// 菜单元件按阅读顺序（先上后下，同一行先左后右）排列后的文案。
List<String> _readingOrder(WidgetTester tester, List<String> labels) {
  final List<({String label, Offset at})> items =
      <({String label, Offset at})>[
    for (final String label in labels)
      (label: label, at: tester.getTopLeft(find.text(label))),
  ];
  items.sort((({String label, Offset at}) a, ({String label, Offset at}) b) {
    final int byRow = a.at.dy.compareTo(b.at.dy);
    return byRow != 0 ? byRow : a.at.dx.compareTo(b.at.dx);
  });
  return items.map((({String label, Offset at}) item) => item.label).toList();
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();
  final bool hasRevealHost =
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_manga_menu_pp');
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
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_menu_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    // 长按菜单要经 MediaItem.getMediaSource 解析 mediaType → source（dialog 的
    // 显示名/封面），不 populate 会在打开对话框时命中 late 字段。
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> insertLocalVolume() async {
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: 'Alpha卷',
        epubPath: '/tmp/$_bookKey',
        extractDir: '/tmp/$_bookKey',
        chapterCount: 0,
        chaptersJson: '[]',
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
  }

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(testPlatformServices()),
      appProvider.overrideWith((ref) => appModel),
      fushiBooksProvider.overrideWith(
        (ref, language) => Future<List<MediaItem>>.value(<MediaItem>[
          _mangaItem(),
        ]),
      ),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ReaderFushiHistoryPage(
            mangaOnly: true,
          ),
        ),
      ),
    ),
  );

  Future<void> sizeNarrowAndTall(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 1600);
    addTearDown(tester.view.reset);
  }

  List<String> expectedLabels() => <String>[
    t.dialog_edit_info,
    if (hasRevealHost) t.media_file_location_open,
    t.book_mark_completed_action,
    t.library_progress_reset_action,
    t.tag_label,
    t.dialog_delete,
  ];

  Future<void> openMangaMenu(WidgetTester tester) async {
    await sizeNarrowAndTall(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Alpha卷').first);
    await tester.pumpAndSettle();
  }

  void expectDeleteIsDestructive(WidgetTester tester) {
    final Text deleteText = tester.widget<Text>(find.text(t.dialog_delete));
    final ColorScheme colors =
        Theme.of(tester.element(find.text(t.dialog_delete))).colorScheme;
    expect(
      deleteText.style?.color,
      colors.error,
      reason: '删除即使排在列表里也必须保留危险红色',
    );
  }

  testWidgets('长按漫画卡：菜单顺序固定，无重命名，删除末位且为红色', (WidgetTester tester) async {
    await openMangaMenu(tester);

    final List<String> expected = expectedLabels();
    expect(find.text(t.book_rename), findsNothing, reason: '重命名已从漫画卡菜单移除');
    expect(
      _readingOrder(tester, expected),
      expected,
      reason: '编辑信息 → 打开文件位置 → 标记已读完 → 重置阅读状态 → 标签 → 删除',
    );
    expectDeleteIsDestructive(tester);
  });

  testWidgets('点列表末位的删除仍走统一移出确认', (WidgetTester tester) async {
    await openMangaMenu(tester);

    await tester.runAsync(() async {
      await tester.tap(find.text(t.dialog_delete));
      await tester.pump();
      await _pumpUntil(
        tester,
        find.text(t.manga_series_remove_from_bookshelf),
      );
    });

    expect(
      find.text(t.manga_series_remove_from_bookshelf),
      findsOneWidget,
      reason: '删除从危险区移进列表，但统一移出确认流程不能绕过（票 02）',
    );
    expect(find.text(t.manga_series_remove_confirm), findsOneWidget);
  });

  testWidgets('作品页「管理本卷」打开同一份顺序与样式的菜单', (WidgetTester tester) async {
    await insertLocalVolume();
    await sizeNarrowAndTall(tester);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    const ValueKey<String> manageKey =
        ValueKey<String>('manga_series_manage_volume');
    // 点漫画卡进作品页（与书架卡 onTap 同一条路径）。作品页 _load 是真实异步
    // DB 读，fake 时钟的 pump 送不到，走 runAsync 等「管理本卷」出现。
    await tester.runAsync(() async {
      await tester.tap(find.text('Alpha卷').first);
      await tester.pump();
      await _pumpUntil(tester, find.byKey(manageKey));
    });
    expect(find.byKey(manageKey), findsOneWidget, reason: '作品页应已打开');

    // 作品页「管理本卷」→ 同一个书架菜单。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(manageKey));
      await tester.pump();
      await _pumpUntil(tester, find.text(t.dialog_edit_info));
    });

    final List<String> expected = expectedLabels();
    expect(find.text(t.book_rename), findsNothing, reason: '作品页菜单同样不能出现重命名');
    expect(
      _readingOrder(tester, expected),
      expected,
      reason: '作品页管理本卷必须复用书架菜单的同一顺序',
    );
    expectDeleteIsDestructive(tester);
  });
}
