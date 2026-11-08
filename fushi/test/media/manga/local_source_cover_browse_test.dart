import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/local_source/local_source_browse_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 04：本地图源封面的后台补齐。
///
/// 进入本地图源先显示扫描结果与占位；封面逐个在后台生成，每完成一部就更新
/// 对应网格卡片（无需重新扫描、不阻塞首屏）；作品页显示生成后的封面。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

Widget _harness(AppModel appModel) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(child: MaterialApp(home: LocalSourceBrowsePage())),
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 120; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

Finder _coverImage(String coverPath) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Image &&
      widget.image is FileImage &&
      p.equals((widget.image as FileImage).file.path, coverPath),
  description: 'cover.jpg 的 FileImage',
);

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('local_source_cover_browse_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    // 后台封面补齐可能仍持有片刻文件句柄（Windows 下删除会报「另一个程序正在
    // 使用」）；给后台任务一点时间收尾。
    for (int attempt = 0; attempt < 20 && tmp.existsSync(); attempt++) {
      try {
        tmp.deleteSync(recursive: true);
        break;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Directory writeManga(String title, {String chapter = 'Ch 1'}) {
    final Directory mangaDir = Directory(
      p.join(paths.localComicRoot.path, title),
    );
    final File page = File(p.join(mangaDir.path, chapter, '001.png'))
      ..createSync(recursive: true);
    final img.Image image = img.Image(width: 90, height: 120)
      ..clear(img.ColorRgb8(255, 0, 0));
    page.writeAsBytesSync(img.encodePng(image));
    return mangaDir;
  }

  testWidgets('进入页面先显示扫描结果，封面后台补齐后卡片自行更新（无需重新进入）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final String alphaCover = p.join(writeManga('Alpha').path, 'cover.jpg');
    final String betaCover = p.join(writeManga('Beta').path, 'cover.jpg');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      // 网格先出现（扫描结果不等封面）；此后的封面生成由页面后台推进。
      await _pumpUntil(tester, find.text('Alpha'));
      expect(find.text('Alpha'), findsOneWidget, reason: '扫描结果先画出来');
      expect(find.text('Beta'), findsOneWidget);

      for (int i = 0; i < 120; i++) {
        if (File(alphaCover).existsSync() && File(betaCover).existsSync()) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(File(alphaCover).existsSync(), isTrue, reason: 'Alpha 的 cover.jpg 已生成');
      expect(File(betaCover).existsSync(), isTrue, reason: 'Beta 的 cover.jpg 已生成');

      // 后台完成 → 页面通知网格重建 → 对应卡片换成真实封面。
      await _pumpUntil(tester, _coverImage(alphaCover));
      await _pumpUntil(tester, _coverImage(betaCover));
    });
    expect(_coverImage(alphaCover), findsOneWidget);
    expect(_coverImage(betaCover), findsOneWidget);
  });

  testWidgets('网格卡片与作品页都显示后台生成的封面', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory mangaDir = writeManga('Alpha');
    final String coverPath = p.join(mangaDir.path, 'cover.jpg');

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths)));
      await _pumpUntil(tester, find.text('Alpha'));
      expect(find.text('Alpha'), findsOneWidget, reason: '网格先出现');

      for (int i = 0; i < 120 && !File(coverPath).existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(File(coverPath).existsSync(), isTrue, reason: '后台已生成封面');

      // 后台完成 → 目录通知页面 → 对应卡片更新为真实封面。
      await _pumpUntil(tester, _coverImage(coverPath));
      await tester.pump();
    });
    expect(_coverImage(coverPath), findsOneWidget, reason: '网格卡片显示封面');

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(ValueKey<String>('local_source_item_${mangaDir.path}')),
      );
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
      await _pumpUntil(tester, _coverImage(coverPath));
    });
    expect(_coverImage(coverPath), findsWidgets, reason: '未入库作品页也显示生成的封面');
  });
}
