// ticket 08：漫画书架页「选择」底部批量栏只播放一次入场。
//
// 根因：FushiSpringReveal 完全展开后把裁剪 / 位移 / 透明包装换成裸 child，
// 子树在这一帧被重新 inflate——BatchActionBar 的 MD3 分支自带一次入场
// tween（从 0 淡入 + 上滑 24），于是从 0 重播，用户看到第二次入场。
//
// 本测试逐帧采样批量栏的渲染透明度（批量栏内容所有祖先 Opacity 的乘积）：
// 第一次完全可见之后，只要还在选择模式，就不得再掉回不可见。退出时反向
// 采样：已经开始的收起不得再回弹成一次新的淡入。
import 'dart:io';
import 'dart:math' as math;

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
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_batch_bar_pp');
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
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_batch_bar_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
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

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(const <MediaItem>[]),
          ),
          srtBooksProvider.overrideWith(
            (ref) => Future<List<SrtBook>>.value(const <SrtBook>[]),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            builder: (BuildContext context, Widget? child) =>
                child ?? const SizedBox.shrink(),
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                mangaOnly: true,
                remoteBookClientLoader: () async => null,
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

  const Duration frame = Duration(milliseconds: 16);

  /// 批量栏此刻的渲染透明度 = 内容所有祖先 [Opacity] 的乘积。
  /// 无祖先 Opacity 时为 1；栏不在树上时按 0 计。
  double barRenderedOpacity(WidgetTester tester) {
    final Finder text = find.text(t.batch_selected_count(n: 0));
    if (text.evaluate().isEmpty) return 0;
    double opacity = 1;
    for (final Element element in tester.elementList(
      find.ancestor(of: text, matching: find.byType(Opacity)),
    )) {
      opacity *= (element.widget as Opacity).opacity;
    }
    return opacity;
  }

  Future<List<double>> sampleBarOpacity(
    WidgetTester tester, {
    required int frames,
  }) async {
    final List<double> samples = <double>[];
    for (int i = 0; i < frames; i++) {
      await tester.pump(frame);
      samples.add(barRenderedOpacity(tester));
    }
    return samples;
  }

  final Finder selectToggle =
      find.byKey(const ValueKey<String>('library_select_toggle'));

  /// 采样里「从不可见跨到可见」的次数：一次入场 = 1；重播入场 = 2。
  int fadeInCrossings(List<double> samples) {
    int crossings = 0;
    for (int i = 1; i < samples.length; i++) {
      if (samples[i - 1] < 0.5 && samples[i] >= 0.5) crossings++;
    }
    return crossings;
  }

  testWidgets('点击「选择」后批量栏只播放一次入场', (WidgetTester tester) async {
    await pumpPage(tester);
    expect(selectToggle, findsOneWidget, reason: '前提：漫画页有「选择」入口');

    await tester.tap(selectToggle);
    await tester.pump();

    // ~2.9s 逐帧采样：外层弹簧 + 内层 450ms 入场都早已结束。
    final List<double> samples = await sampleBarOpacity(tester, frames: 180);
    final double peak = samples.reduce(math.max);
    expect(
      peak,
      greaterThanOrEqualTo(0.99),
      reason: '批量栏必须完成入场；采样=$samples',
    );
    expect(
      fadeInCrossings(samples),
      1,
      reason: '批量栏只许淡入一次，不能第二次入场；采样=$samples',
    );
    expect(
      samples.last,
      greaterThanOrEqualTo(0.99),
      reason: '选择模式下批量栏必须保持完全可见；采样=$samples',
    );
  });

  testWidgets('退出选择时批量栏一次收起：不再重播入场，最终从树里消失', (WidgetTester tester) async {
    await pumpPage(tester);
    await tester.tap(selectToggle);
    await tester.pump();
    await tester.pumpAndSettle();

    // 再点一次（X）退出选择模式。
    await tester.tap(selectToggle);
    await tester.pump();
    final double atExitStart = barRenderedOpacity(tester);
    final List<double> samples = await sampleBarOpacity(tester, frames: 120);

    expect(
      atExitStart,
      greaterThanOrEqualTo(0.99),
      reason: '收起开始时批量栏已经完整可见',
    );
    expect(
      samples.reduce(math.max),
      lessThanOrEqualTo(atExitStart + 0.01),
      reason: '收起过程中不得回弹成一次新的淡入；采样=$samples',
    );
    expect(
      find.text(t.batch_selected_count(n: 0)),
      findsNothing,
      reason: '收起完成后批量栏必须从树上移除（无残留）',
    );
  });
}
