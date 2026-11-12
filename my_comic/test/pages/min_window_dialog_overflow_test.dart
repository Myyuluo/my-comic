// TODO-1389: RenderFlex bottom overflow at TODO-1377 min window height.
// TODO-1377 lowered the desktop main-window minimum HEIGHT 640 -> 480 (client
// logical height about 440px). It only off-screen-verified 5 main surfaces
// (shelf/video/lookup/settings/dictionary), not dialogs/sheets. This test
// reproduces, at the min window height, three height-capped-frame + non
// -scrolling-body bottom overflows and locks the fix (scroll viewport or
// scrollable:true):
//   1. MediaSourcesDialog: MyComicReorderableColumn is non-scrolling and was the
//      one dialog MISSING the SingleChildScrollView wrap (BUG-445 shape; the
//      sibling local_audio_sources_dialog already had it).
//   2. sasayaki rematch desktop dialog: non-scrolling two-slider Column capped
//      by the outer 0.62 factor.
//   3. series rename dialog: cover image + text field non-scrolling Column
//      capped by the outer 0.74 factor.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/models.dart';

import 'package:my_comic/utils.dart';
import 'package:my_comic_core/my_comic_core.dart';

import '../helpers/test_platform_services.dart';

class _DialogTestAppModel extends AppModel {
  _DialogTestAppModel() : super(testPlatformServices());
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  ThemeData theme() => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
      );

  Future<void> pumpFrame(
    WidgetTester tester, {
    required Size screen,
    required double maxHeightFactor,
    required bool innerScrollable,
    required Widget body,
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: Scaffold(
          body: Center(
            child: MyComicDialogFrame(
              maxWidth: 480,
              maxHeightFactor: maxHeightFactor,
              scrollable: false,
              child: MyComicModalSheetFrame(
                title: 'T',
                leadingIcon: Icons.info_outline,
                scrollable: innerScrollable,
                body: body,
                footer: const SizedBox(height: 36),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Widget sentenceAudioLikeBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const <Widget>[
          SizedBox(height: 140, width: double.infinity),
          SizedBox(height: 16),
          SizedBox(height: 140, width: double.infinity),
        ],
      );

  Widget seriesLikeBody() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: const <Widget>[
          Center(child: SizedBox(width: 92, height: 120)),
          SizedBox(height: 12),
          SizedBox(height: 56),
        ],
      );

  bool isOverflow(Object? e) =>
      e != null && e.toString().toLowerCase().contains('overflow');

  group('sentenceAudioHighlight rematch dialog (0.62 cap) mechanism', () {
    testWidgets('scrollable false overflows at a short window (root cause)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 400),
        maxHeightFactor: 0.62,
        innerScrollable: false,
        body: sentenceAudioLikeBody(),
      );
      expect(isOverflow(tester.takeException()), isTrue,
          reason: 'non-scrolling two-slider Column overflows under 248px cap');
    });

    testWidgets('scrollable true scrolls without overflow (fix)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 400),
        maxHeightFactor: 0.62,
        innerScrollable: true,
        body: sentenceAudioLikeBody(),
      );
      expect(tester.takeException(), isNull, reason: 'scrollable true scrolls');
      expect(
        find.descendant(
          of: find.byType(MyComicModalSheetFrame),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
        reason: 'fixed body lives in a scroll viewport',
      );
    });
  });

  group('series rename dialog (0.74 cap) mechanism', () {
    testWidgets('scrollable false overflows at a short window (root cause)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 320),
        maxHeightFactor: 0.74,
        innerScrollable: false,
        body: seriesLikeBody(),
      );
      expect(isOverflow(tester.takeException()), isTrue,
          reason: 'cover image + field non-scrolling Column overflows');
    });

    testWidgets('scrollable true scrolls without overflow (fix)',
        (WidgetTester tester) async {
      await pumpFrame(
        tester,
        screen: const Size(360, 320),
        maxHeightFactor: 0.74,
        innerScrollable: true,
        body: seriesLikeBody(),
      );
      expect(tester.takeException(), isNull, reason: 'scrollable true scrolls');
    });
  });

}
