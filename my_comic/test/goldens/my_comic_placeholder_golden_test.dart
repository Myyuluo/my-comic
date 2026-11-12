@Tags(<String>['golden'])
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_placeholder_message.dart';

import 'golden_test_helpers.dart';

void main() {
  group('MyComicPlaceholderMessage golden', () {
    testWidgets('default style', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicPlaceholderMessage(
          icon: Icons.book,
          message: 'No books yet',
        ),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_default.png'),
      );
    });

    testWidgets('custom color', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicPlaceholderMessage(
          icon: Icons.error_outline,
          message: 'Something went wrong',
          color: Colors.red,
        ),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_error.png'),
      );
    });

    testWidgets('dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicPlaceholderMessage(
          icon: Icons.search_off,
          message: 'No results found',
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(300, 190),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/placeholder_dark.png'),
      );
    });
  });
}
