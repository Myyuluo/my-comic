import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/focus/my_comic_focus_controller.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';

import 'widget_test_helpers.dart';

void main() {
  testWidgets('MyComicSearchField registers its text focus node with the root',
      (WidgetTester tester) async {
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode(debugLabel: 'search-field');
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);

    await tester.pumpWidget(buildTestApp(
      MyComicFocusRoot(
        child: MyComicSearchField(
          focusId: const MyComicFocusId('search'),
          controller: controller,
          focusNode: focusNode,
          hintText: 'Search',
          onChanged: (_) {},
          onSubmitted: (_) {},
        ),
      ),
    ));
    await tester.pump();

    // 搜索框已从 MD3 SearchBar 换成与媒体库页一致的描边 TextField，
    // 这里取的是同一棵子树里的输入控件元素，断言意图不变。
    final MyComicFocusController root = MyComicFocusRoot.controllerOf(
      tester.element(find.byType(TextField)),
    );
    expect(root.requestById(const MyComicFocusId('search')), isTrue);
    await tester.pump();

    expect(root.activeId, const MyComicFocusId('search'));
    expect(focusNode.hasPrimaryFocus, isTrue);
  });

  testWidgets('MyComicTextField registers with an owned focus node',
      (WidgetTester tester) async {
    await tester.pumpWidget(buildTestApp(
      const MyComicFocusRoot(
        child: MyComicTextField(
          focusId: MyComicFocusId('text-field'),
          hintText: 'Name',
        ),
      ),
    ));
    await tester.pump();

    final MyComicFocusController root = MyComicFocusRoot.controllerOf(
      tester.element(find.byType(TextFormField)),
    );
    expect(root.requestById(const MyComicFocusId('text-field')), isTrue);
    await tester.pump();

    expect(root.activeId, const MyComicFocusId('text-field'));
    expect(FocusManager.instance.primaryFocus?.debugLabel, contains('Name'));
  });
}
