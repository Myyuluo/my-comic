import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';

void main() {
  testWidgets('clickable MyComicCard registers with the focus root',
      (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: MyComicFocusRoot(
        child: Column(
          children: <Widget>[
            MyComicCard(
              focusId: const MyComicFocusId('first-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
            MyComicCard(
              focusId: const MyComicFocusId('second-card'),
              onTap: () => taps += 1,
              child: const SizedBox(width: 80, height: 48),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    final BuildContext context = tester.element(find.byType(Column));
    final MyComicFocusController controller =
        MyComicFocusRoot.controllerOf(context);
    expect(
      controller.requestById(const MyComicFocusId('first-card')),
      isTrue,
    );
    await tester.pump();

    expect(controller.activeId, const MyComicFocusId('first-card'));

    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    expect(taps, 1);
  });
}
