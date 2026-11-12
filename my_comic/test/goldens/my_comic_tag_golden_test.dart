@Tags(<String>['golden'])
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_tag.dart';

import 'golden_test_helpers.dart';

void main() {
  group('MyComicTag golden', () {
    testWidgets('basic tag', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicTag(text: 'noun', backgroundColor: Colors.blue),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_basic.png'),
      );
    });

    testWidgets('tag with icon', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicTag(
          text: 'verb',
          backgroundColor: Colors.green,
          icon: Icons.label,
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_with_icon.png'),
      );
    });

    testWidgets('tag with trailing text', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicTag(
          text: 'freq',
          backgroundColor: Colors.purple,
          trailingText: '★3',
        ),
        size: const Size(250, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_trailing.png'),
      );
    });

    testWidgets('tag dark theme', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicTag(
          text: 'dark',
          backgroundColor: Colors.teal,
          icon: Icons.dark_mode,
        ),
        theme: ThemeData.dark(useMaterial3: true),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_dark.png'),
      );
    });

    testWidgets('tag custom foreground', (tester) async {
      await tester.pumpWidget(buildGoldenApp(
        const MyComicTag(
          text: 'custom',
          backgroundColor: Color(0xFF263238),
          foregroundColor: Colors.amber,
          icon: Icons.star,
        ),
        size: const Size(200, 60),
      ));
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('golden_files/tag_custom_color.png'),
      );
    });
  });
}
