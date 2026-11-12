import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/models/theme_notifier.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_scope.dart';

// MyComicSearchField 的 large 档契约：MD3 = M3 SearchBar（56 高、28 圆角全胶囊、
// 无描边、正文竖直居中、trailing 槽 48 触控区）；Apple 没有 56 的搜索栏，
// large 仍是 36 的 iOS 搜索胶囊。regular 档不受影响（MD3 40）。

Future<void> _pump(
  WidgetTester tester, {
  required bool apple,
  required MyComicSearchFieldSize size,
  List<Widget> trailing = const <Widget>[],
  String text = '',
}) async {
  final ThemeData theme = buildMyComicThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: apple ? MyComicGlassMaterial.liquid : MyComicGlassMaterial.off,
    glassDesign: apple,
  ).copyWith(platform: TargetPlatform.windows);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: MyComicGlassScope(
        child: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 480,
              child: MyComicSearchField(
                fieldKey: const ValueKey<String>('field'),
                controller: TextEditingController(text: text),
                focusNode: FocusNode(),
                hintText: 'Search',
                onChanged: (_) {},
                onSubmitted: (_) {},
                size: size,
                trailing: trailing,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('MD3 large is a 56-tall fully rounded search bar', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: false,
      size: MyComicSearchFieldSize.large,
      text: 'abc',
    );
    final Rect field = tester.getRect(
      find.byKey(const ValueKey<String>('field')),
    );
    expect(field.height, kMyComicSearchFieldLargeHeight);
    expect(kMyComicSearchFieldLargeHeight, 56);

    final InputDecorator decorator = tester.widget(find.byType(InputDecorator));
    final InputBorder enabled = decorator.decoration.enabledBorder!;
    expect(enabled, isA<OutlineInputBorder>());
    expect(
      (enabled as OutlineInputBorder).borderRadius,
      BorderRadius.circular(28),
    );
    expect(enabled.borderSide, BorderSide.none);
    // SearchBar 聚焦不画主色描边（用状态层表达）。
    expect(decorator.decoration.focusedBorder!.borderSide, BorderSide.none);
    expect(decorator.decoration.filled, isTrue);

    // 正文在 56 高的胶囊里竖直居中（±0.5px）。
    final Rect editable = tester.getRect(find.byType(EditableText));
    expect(
      (editable.center.dy - field.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });

  testWidgets('MD3 large trailing actions get 48 touch targets', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: false,
      size: MyComicSearchFieldSize.large,
      trailing: <Widget>[
        SizedBox(
          key: const ValueKey<String>('action'),
          width: 40,
          height: 40,
          child: IconButton(onPressed: () {}, icon: const Icon(Icons.book)),
        ),
      ],
    );
    expect(find.byKey(const ValueKey<String>('action')), findsOneWidget);
    final Finder slot = find.ancestor(
      of: find.byKey(const ValueKey<String>('action')),
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is ConstrainedBox &&
            w.constraints.minWidth == 48 &&
            w.constraints.minHeight == 48,
      ),
    );
    expect(slot, findsOneWidget);
    expect(tester.getSize(slot).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(slot).height, greaterThanOrEqualTo(48));
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('field'))).height,
      56,
    );
  });

  testWidgets('MD3 regular stays 40 tall', (WidgetTester tester) async {
    await _pump(tester, apple: false, size: MyComicSearchFieldSize.regular);
    expect(
      tester.getRect(find.byKey(const ValueKey<String>('field'))).height,
      kMyComicSearchFieldHeight,
    );
  });

  testWidgets('Apple large stays a 36-tall iOS search capsule', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      apple: true,
      size: MyComicSearchFieldSize.large,
      text: 'abc',
    );
    final Rect field = tester.getRect(
      find.byKey(const ValueKey<String>('field')),
    );
    expect(field.height, 36);
    final Rect editable = tester.getRect(find.byType(EditableText));
    expect(
      (editable.center.dy - field.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });
}
