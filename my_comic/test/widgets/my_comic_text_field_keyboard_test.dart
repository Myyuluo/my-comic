import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';

import 'widget_test_helpers.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';

void main() {
  group('MyComicTextField on-screen keyboard affordance', () {
    testWidgets('desktop + controller shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget,
          reason: 'desktop gamepad users need an on-screen keyboard');
    });

    testWidgets('mobile does NOT show the ⌨ (system IME is available)',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.keyboard), findsNothing);
    });

    testWidgets('a caller-supplied suffix is never overridden',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c, suffixIcon: const Icon(Icons.clear)),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.keyboard), findsNothing);
      expect(find.byIcon(Icons.clear), findsOneWidget);
    });

    testWidgets(
        'no controller (initialValue) shows no ⌨ (nothing to type into)',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTextField(initialValue: 'x'),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.keyboard), findsNothing);
    });

    testWidgets('mobile + controller shows a one-tap paste button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.paste), findsOneWidget);
      expect(find.byIcon(MyComicIcons.keyboard), findsNothing,
          reason: 'mobile uses the system IME, not the on-screen keyboard');
    });

    testWidgets('desktop shows the keyboard button, not paste',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      addTearDown(c.dispose);
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
      expect(find.byIcon(MyComicIcons.paste), findsNothing);
    });

    testWidgets(
        'mobile paste button inserts clipboard text and fires onChanged',
        (WidgetTester tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': 'hi'}
            : null,
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final TextEditingController c = TextEditingController(text: 'a');
      addTearDown(c.dispose);
      c.selection = const TextSelection.collapsed(offset: 1);
      final List<String> changes = <String>[];
      await tester.pumpWidget(buildTestApp(
        MyComicTextField(controller: c, onChanged: changes.add),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      await tester.tap(find.byIcon(MyComicIcons.paste));
      await tester.pumpAndSettle();
      expect(c.text, 'ahi');
      expect(changes.last, 'ahi');
    });

    testWidgets('mobile no-controller shows no paste button',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicTextField(initialValue: 'x'),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.android),
      ));
      await tester.pump();
      expect(find.byIcon(MyComicIcons.paste), findsNothing);
    });
  });

  group('search fields on-screen keyboard affordance', () {
    testWidgets('desktop MyComicSearchField shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        MyComicSearchField(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();

      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
    });

    testWidgets('optional clear button clears text and keeps search focus',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController(text: 'term');
      final FocusNode focusNode = FocusNode();
      final List<String> clears = <String>[];
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        MyComicSearchField(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          clearButtonKey: const ValueKey<String>('search-clear'),
          onChanged: (_) {},
          onClear: () {
            c.clear();
            clears.add(c.text);
          },
          onSubmitted: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();

      expect(
          find.byKey(const ValueKey<String>('search-clear')), findsOneWidget);
      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byKey(const ValueKey<String>('search-clear')));
      await tester.pump();

      expect(c.text, isEmpty);
      expect(clears, <String>['']);
      expect(focusNode.hasFocus, isTrue);
      expect(find.byKey(const ValueKey<String>('search-clear')), findsNothing);
      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
    });

    testWidgets('desktop compact search row shows the ⌨ button',
        (WidgetTester tester) async {
      final TextEditingController c = TextEditingController();
      final FocusNode focusNode = FocusNode();
      addTearDown(c.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(buildTestApp(
        MyComicCompactSearchRow(
          controller: c,
          focusNode: focusNode,
          hintText: 'Search',
          onSubmit: (_) {},
        ),
        theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
      ));
      await tester.pump();

      expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
    });
  });

  testWidgets('desktop MyComicEditorPanel shows the ⌨ button',
      (WidgetTester tester) async {
    final TextEditingController c = TextEditingController();
    addTearDown(c.dispose);

    await tester.pumpWidget(buildTestApp(
      SizedBox(
        width: 480,
        height: 320,
        child: MyComicEditorPanel(controller: c),
      ),
      theme: ThemeData(useMaterial3: true, platform: TargetPlatform.windows),
    ));
    await tester.pump();

    expect(find.byIcon(MyComicIcons.keyboard), findsOneWidget);
  });
}
