import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';
import 'package:my_comic/src/shortcuts/gamepad_service.dart';
import 'package:my_comic/src/shortcuts/input_binding.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/settings_shared.dart';

import 'widget_test_helpers.dart';

// Regression for the family of gamepad/keyboard focus-skip bugs (same root cause
// as the theme color swatches): native interactive CLUSTERS placed among
// registered MyComicFocusTargets were skipped by the directional controller,
// which walks only registered targets. These cover the three primitives the
// page fixes now route through: MyComicSelectableChip(focusId) (reader theme
// chips), MyComicAdjustableSegmented (dictionary type / sync conflict selectors),
// and MyComicFocusable (reader bottom action buttons).
void main() {
  Widget stepperThen(Widget below) {
    return MyComicFocusRoot(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AdaptiveSettingsStepperRow(
            title: 'Scale',
            value: 2,
            step: 1,
            min: 0,
            max: 4,
            format: (double v) => '${v.round()}',
            onChanged: (_) {},
          ),
          below,
        ],
      ),
    );
  }

  MyComicFocusController controllerFor(WidgetTester tester) =>
      MyComicFocusRoot.controllerOf(tester.element(find.text('Scale')));

  testWidgets('MyComicSelectableChip with focusId is a reachable focus stop',
      (WidgetTester tester) async {
    String? picked;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Wrap(
        children: <Widget>[
          MyComicSelectableChip(
            label: 'A',
            selected: false,
            focusId: const MyComicFocusId('chip-a'),
            onSelected: (_) => picked = 'a',
          ),
          MyComicSelectableChip(
            label: 'B',
            selected: false,
            focusId: const MyComicFocusId('chip-b'),
            onSelected: (_) => picked = 'b',
          ),
        ],
      ),
    )));
    await tester.pump();

    final MyComicFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(MyComicFocusDirection.down), isTrue,
        reason: 'a registered chip sits below the stepper');
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(picked, isNotNull, reason: 'A on the focused chip selects it');
  });

  testWidgets('MyComicAdjustableSegmented is reachable and D-pad Right cycles',
      (WidgetTester tester) async {
    String value = 'a';
    await tester.pumpWidget(buildTestApp(
      StatefulBuilder(
        builder: (BuildContext c, StateSetter setState) => stepperThen(
          MyComicAdjustableSegmented<String>(
            focusIdPrefix: 'seg',
            values: const <String>['a', 'b', 'c'],
            selected: value,
            onChanged: (String v) => setState(() => value = v),
            child: const SizedBox(width: 200, height: 40),
          ),
        ),
      ),
    ));
    await tester.pump();

    final MyComicFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(MyComicFocusDirection.down), isTrue,
        reason: 'the segmented selector is a registered focus stop');
    await tester.pump();
    expect(
      Actions.maybeInvoke<GamepadButtonIntent>(
        controller.activeContext!,
        const GamepadButtonIntent(GamepadButton.dpadRight),
      ),
      isTrue,
      reason: 'D-pad Right is consumed and cycles the segment in place',
    );
    await tester.pump();
    expect(value, 'b', reason: 'a → b (next value)');
  });

  testWidgets('MyComicActivatableFocusTarget action button is a reachable stop',
      (WidgetTester tester) async {
    bool tapped = false;
    await tester.pumpWidget(buildTestApp(stepperThen(
      Row(
        children: <Widget>[
          MyComicActivatableFocusTarget(
            focusIdPrefix: 'action',
            onTap: () => tapped = true,
            child: const SizedBox(width: 60, height: 48),
          ),
        ],
      ),
    )));
    await tester.pump();

    final MyComicFocusController controller = controllerFor(tester);
    controller.ensureFocus(); // stepper
    await tester.pump();

    expect(controller.move(MyComicFocusDirection.down), isTrue,
        reason: 'the action button is a registered focus stop');
    await tester.pump();
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(tapped, isTrue, reason: 'A on the focused button activates it');
  });
}
