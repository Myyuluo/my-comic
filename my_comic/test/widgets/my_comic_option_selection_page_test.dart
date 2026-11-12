import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/my_comic_option_selection_page.dart';

Widget _harness(Widget child) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: child,
  );
}

List<MyComicOptionSelectionOption<String>> _langs() =>
    const <MyComicOptionSelectionOption<String>>[
      MyComicOptionSelectionOption<String>(value: 'en-US', label: 'English'),
      MyComicOptionSelectionOption<String>(value: 'ja', label: '日本語'),
      MyComicOptionSelectionOption<String>(value: 'zh-CN', label: '简体中文'),
    ];

void main() {
  testWidgets('selected entry shows a check; tapping another pops its value',
      (WidgetTester tester) async {
    String? popped = 'SENTINEL';
    await tester.pumpWidget(
      _harness(
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await pickOption<String>(
                    context,
                    title: 'Language',
                    options: _langs(),
                    selected: 'ja',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // The selected entry (日本語) renders a trailing check.
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(popped, 'en-US');
  });

  testWidgets('never renders a search field, even for long option sets',
      (WidgetTester tester) async {
    final List<MyComicOptionSelectionOption<int>> many =
        List<MyComicOptionSelectionOption<int>>.generate(
      20,
      (int i) => MyComicOptionSelectionOption<int>(value: i, label: 'Item $i'),
    );
    await tester.pumpWidget(
      _harness(
        MyComicOptionSelectionPage<int>(
          title: 'Pick',
          options: many,
          selected: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MyComicTextField), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}
