import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';
import 'package:my_comic/src/focus/my_comic_focus_target.dart';

void main() {
  testWidgets('MyComicFocusRoot restores focus when the primary node is removed',
      (WidgetTester tester) async {
    final FocusNode first = FocusNode(debugLabel: 'first');
    final FocusNode second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    bool showFirst = true;
    StateSetter setOuter = (_) {};
    await tester.pumpWidget(MaterialApp(
      home: MyComicFocusRoot(
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return Column(
              children: <Widget>[
                if (showFirst)
                  MyComicFocusTarget(
                    id: const MyComicFocusId('first'),
                    focusNode: first,
                    child: const SizedBox(width: 40, height: 40),
                  ),
                MyComicFocusTarget(
                  id: const MyComicFocusId('second'),
                  focusNode: second,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ],
            );
          },
        ),
      ),
    ));

    first.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(first));

    setOuter(() => showFirst = false);
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(
      second.hasPrimaryFocus,
      isTrue,
      reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
    );
  });

  testWidgets('MyComicFocusRoot keeps a fallback focus for passive routes',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: MyComicFocusRoot(
        child: Center(child: Text('passive')),
      ),
    ));
    await tester.pump();

    final MyComicFocusController controller = MyComicFocusRoot.controllerOf(
      tester.element(find.text('passive')),
    );
    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
  });

  testWidgets(
      'disabling the focused target moves focus to the next enabled one',
      (WidgetTester tester) async {
    final FocusNode first = FocusNode(debugLabel: 'first');
    final FocusNode second = FocusNode(debugLabel: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    bool firstEnabled = true;
    StateSetter setOuter = (_) {};
    await tester.pumpWidget(MaterialApp(
      home: MyComicFocusRoot(
        child: StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) {
            setOuter = setState;
            return Column(
              children: <Widget>[
                MyComicFocusTarget(
                  id: const MyComicFocusId('first'),
                  focusNode: first,
                  enabled: firstEnabled,
                  child: const SizedBox(width: 40, height: 40),
                ),
                MyComicFocusTarget(
                  id: const MyComicFocusId('second'),
                  focusNode: second,
                  child: const SizedBox(width: 40, height: 40),
                ),
              ],
            );
          },
        ),
      ),
    ));

    first.requestFocus();
    await tester.pump();
    expect(first.hasPrimaryFocus, isTrue);

    setOuter(() => firstEnabled = false);
    await tester.pump();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus, isNotNull);
    expect(second.hasPrimaryFocus, isTrue);
  });

  testWidgets('pushed routes own directional focus targets',
      (WidgetTester tester) async {
    final FocusNode outer = FocusNode(debugLabel: 'outer');
    final FocusNode inner = FocusNode(debugLabel: 'inner');
    addTearDown(outer.dispose);
    addTearDown(inner.dispose);

    late MyComicFocusController controller;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MyComicFocusRoot(
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              controller = MyComicFocusRoot.controllerOf(context);
              return Column(
                children: <Widget>[
                  MyComicFocusTarget(
                    id: const MyComicFocusId('outer'),
                    focusNode: outer,
                    child: TextButton(
                      onPressed: () => Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) => Scaffold(
                            body: MyComicFocusTarget(
                              id: const MyComicFocusId('inner'),
                              focusNode: inner,
                              child: const SizedBox(
                                width: 120,
                                height: 80,
                                child: Center(child: Text('inner target')),
                              ),
                            ),
                          ),
                        ),
                      ),
                      child: const Text('outer target'),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    outer.requestFocus();
    await tester.pump();
    expect(controller.activeId, const MyComicFocusId('outer'));

    await tester.tap(find.text('outer target'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(controller.activeId, const MyComicFocusId('inner'));
    expect(inner.hasPrimaryFocus, isTrue);
    expect(outer.hasPrimaryFocus, isFalse);
  });

  testWidgets('modal routes own directional focus targets',
      (WidgetTester tester) async {
    final FocusNode outer = FocusNode(debugLabel: 'outer');
    final FocusNode dialog = FocusNode(debugLabel: 'dialog');
    addTearDown(outer.dispose);
    addTearDown(dialog.dispose);

    late MyComicFocusController controller;
    await tester.pumpWidget(
      MaterialApp(
        builder: (BuildContext context, Widget? child) => MyComicFocusRoot(
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              controller = MyComicFocusRoot.controllerOf(context);
              return MyComicFocusTarget(
                id: const MyComicFocusId('outer'),
                focusNode: outer,
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (BuildContext context) => Dialog(
                      child: MyComicFocusTarget(
                        id: const MyComicFocusId('dialog'),
                        focusNode: dialog,
                        child: const SizedBox(
                          width: 120,
                          height: 80,
                          child: Center(child: Text('dialog target')),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('outer target'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    outer.requestFocus();
    await tester.pump();
    expect(controller.activeId, const MyComicFocusId('outer'));

    await tester.tap(find.text('outer target'));
    await tester.pumpAndSettle();
    await tester.pump();

    expect(controller.activeId, const MyComicFocusId('dialog'));
    expect(dialog.hasPrimaryFocus, isTrue);
    expect(outer.hasPrimaryFocus, isFalse);
  });
}
