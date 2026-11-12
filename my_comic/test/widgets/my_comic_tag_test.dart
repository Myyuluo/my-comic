import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_tag.dart';

import 'widget_test_helpers.dart';

void main() {
  group('MyComicTag', () {
    test('uses design token chip radius for every rounded tag surface', () {
      final String source =
          File('lib/src/utils/components/my_comic_tag.dart').readAsStringSync();

      expect(source, contains('tokens.radii.chipRadius'));
      expect(
          source, isNot(contains('BorderRadius.circular(tokens.radii.chip)')));
    });

    testWidgets('renders text label', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'noun',
          backgroundColor: Colors.blue,
        ),
      ));

      expect(find.text('noun'), findsOneWidget);
    });

    testWidgets('renders icon when provided', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'verb',
          backgroundColor: Colors.green,
          icon: Icons.label,
        ),
      ));

      expect(find.byIcon(Icons.label), findsOneWidget);
    });

    testWidgets('does not render icon when null', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'adj',
          backgroundColor: Colors.orange,
        ),
      ));

      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('renders trailingText in separate container', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'freq',
          backgroundColor: Colors.purple,
          trailingText: '★3',
        ),
      ));

      expect(find.text('freq'), findsOneWidget);
      expect(find.text('★3'), findsOneWidget);
    });

    testWidgets('InkWell is tappable when message is set', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'click me',
          backgroundColor: Colors.red,
          message: 'Toast message',
        ),
      ));

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNotNull);
    });

    testWidgets('InkWell has no onTap when message is null', (tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTag(
          text: 'no action',
          backgroundColor: Colors.grey,
        ),
      ));

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNull);
    });
  });
}
