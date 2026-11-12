import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';
import 'package:my_comic/src/shortcuts/gamepad_service.dart';
import 'package:my_comic/src/shortcuts/input_binding.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  group('MyComicTagChip default focusability', () {
    testWidgets(
        'a tappable MyComicTagChip registers under the focus root WITHOUT focusId',
        (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(buildTestApp(
        MyComicFocusRoot(
          child: Column(
            children: <Widget>[
              MyComicTagChip(label: 'A', onTap: () => taps += 1),
              MyComicTagChip(label: 'B', onTap: () => taps += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final MyComicFocusController controller = MyComicFocusRoot.controllerOf(
        tester.element(find.text('A')),
      );
      controller.ensureFocus();
      await tester.pump();
      expect(controller.activeId, isNotNull,
          reason: 'a tappable tag chip is a default gamepad focus target');

      Actions.maybeInvoke<ActivateIntent>(
        controller.activeContext!,
        const ActivateIntent(),
      );
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('a passive MyComicTagChip (onTap == null) is not a focus target',
        (WidgetTester tester) async {
      await tester.pumpWidget(buildTestApp(
        const MyComicFocusRoot(
          child: Column(
            children: <Widget>[
              MyComicTagChip(label: 'Passive'),
            ],
          ),
        ),
      ));
      await tester.pump();

      final MyComicFocusController controller = MyComicFocusRoot.controllerOf(
        tester.element(find.text('Passive')),
      );
      controller.move(MyComicFocusDirection.down);
      await tester.pump();
      expect(controller.activeId, isNull);
      expect(controller.fallbackNode.hasPrimaryFocus, isTrue);
    });

    testWidgets(
        'a deletable MyComicTagChip registers and deletes with gamepad X',
        (WidgetTester tester) async {
      int deletes = 0;
      await tester.pumpWidget(buildTestApp(
        MyComicFocusRoot(
          child: Column(
            children: <Widget>[
              MyComicTagChip(label: 'Ctrl+K', onDeleted: () => deletes += 1),
            ],
          ),
        ),
      ));
      await tester.pump();

      final MyComicFocusController controller = MyComicFocusRoot.controllerOf(
        tester.element(find.text('Ctrl+K')),
      );
      controller.ensureFocus();
      await tester.pump();

      expect(controller.activeId, isNotNull,
          reason: 'a deletable chip is a real gamepad target, not just a '
              'tiny pointer-only close icon');
      expect(
        Actions.maybeInvoke<GamepadButtonIntent>(
          controller.activeContext!,
          const GamepadButtonIntent(GamepadButton.x),
        ),
        isTrue,
      );
      expect(deletes, 1);
    });
  });
}
