@Tags(<String>['golden'])
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_marquee.dart';

import 'golden_test_helpers.dart';

void main() {
  group('MyComicMarquee golden', () {
    testWidgets('short text fits without scrolling', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicMarquee(
          text: 'Short',
          style: TextStyle(fontSize: 16),
        ),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_short.png'),
      );
    });

    testWidgets('Japanese text fits at adequate width', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicMarquee(
          text: '吾輩は猫',
          style: TextStyle(fontSize: 16),
        ),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_japanese_short.png'),
      );
    });

    testWidgets('with custom style non-overflow', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicMarquee(
          text: 'Styled',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.deepPurple,
          ),
        ),
        size: const Size(300, 50),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_styled.png'),
      );
    });

    testWidgets('dark theme non-overflow', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicMarquee(
          text: 'Dark mode',
          style: TextStyle(fontSize: 16, color: Colors.white),
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 40),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/marquee_dark.png'),
      );
    });
  });
}
