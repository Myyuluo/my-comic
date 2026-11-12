@Tags(<String>['golden'])
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_divider.dart';

import 'golden_test_helpers.dart';

void main() {
  group('MyComicDivider golden', () {
    testWidgets('light theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicDivider(),
        size: const Size(300, 30),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/divider_light.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicDivider(),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 30),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/divider_dark.png'),
      );
    });
  });
}
