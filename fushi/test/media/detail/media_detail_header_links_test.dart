import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';

/// 共享详情骨架的可选交互（ticket 03）：标题与 chip 只在调用方传回调时变成可
/// 点击；不传时（小说作品页等既有页面）保持纯展示，外观与命中行为零变化。
///
/// 可点击 / 悬停的实现收敛在 [MediaDetailMouseHoverTap] 一个包装层里，因此这里
/// 只测它的公开契约（悬停标志、只响应鼠标、指针不变、null = 无交互层），页面级
/// 测试只断言「点书名 / 作者会去搜索」，不再伸手进 Text.style / MouseRegion。
void main() {
  Widget wrapperHarness({
    VoidCallback? onTap,
    required Widget Function(BuildContext context, bool hovering) builder,
  }) => MaterialApp(
    home: Scaffold(
      body: Center(
        child: MediaDetailMouseHoverTap(onTap: onTap, builder: builder),
      ),
    ),
  );

  Widget box(BuildContext context, bool hovering) => SizedBox(
    width: 200,
    height: 100,
    child: ColoredBox(
      color: hovering ? Colors.orange : Colors.blue,
      child: const Center(child: Text('target')),
    ),
  );

  Future<TestGesture> attachMouse(WidgetTester tester) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    return mouse;
  }

  group('MediaDetailMouseHoverTap（共享鼠标悬停 / 点击包装）', () {
    testWidgets('不传回调：不挂手势 / 悬停层，builder 恒收到 hovering=false', (
      WidgetTester tester,
    ) async {
      final List<bool> hoverStates = <bool>[];
      await tester.pumpWidget(
        wrapperHarness(
          builder: (BuildContext context, bool hovering) {
            hoverStates.add(hovering);
            return box(context, hovering);
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(hoverStates, isNotEmpty);
      expect(hoverStates, everyElement(isFalse));

      // null = 纯展示：没有额外手势 / 悬停层（命中与外观都不变）。
      expect(
        find.descendant(
          of: find.byType(MediaDetailMouseHoverTap),
          matching: find.byType(MouseRegion),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(MediaDetailMouseHoverTap),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );

      final TestGesture mouse = await attachMouse(tester);
      await mouse.moveTo(tester.getCenter(find.text('target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('target'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(hoverStates, everyElement(isFalse), reason: '没有回调就没有悬停反馈');
      expect(tester.takeException(), isNull);
    });

    testWidgets('传回调：悬停标志交给 builder；只响应鼠标点击，指针保持默认', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      final List<bool> hoverStates = <bool>[];
      await tester.pumpWidget(
        wrapperHarness(
          onTap: () => taps++,
          builder: (BuildContext context, bool hovering) {
            hoverStates.add(hovering);
            return box(context, hovering);
          },
        ),
      );
      await tester.pumpAndSettle();

      // 鼠标指针保持默认：包装层的 MouseRegion 不声明 click 光标。
      expect(
        tester
            .widget<MouseRegion>(
              find
                  .descendant(
                    of: find.byType(MediaDetailMouseHoverTap),
                    matching: find.byType(MouseRegion),
                  )
                  .first,
            )
            .cursor,
        MouseCursor.defer,
      );

      final TestGesture mouse = await attachMouse(tester);
      await mouse.moveTo(tester.getCenter(find.text('target')));
      await tester.pumpAndSettle();
      expect(hoverStates.last, isTrue, reason: '悬停时 builder 收到 hovering=true');

      await mouse.moveTo(const Offset(1, 1));
      await tester.pumpAndSettle();
      expect(hoverStates.last, isFalse, reason: '移出后悬停标志复位');

      // 触摸点击不触发（只响应鼠标）。
      await tester.tap(find.text('target'));
      await tester.pumpAndSettle();
      expect(taps, 0);

      // 鼠标点击触发。
      await tester.tap(find.text('target'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('MediaDetailHero / MediaDetailChipView', () {
    Widget heroHarness({VoidCallback? onTitleTap, VoidCallback? onChipTap}) =>
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: <Widget>[
                MediaDetailHero(
                  title: 'Work title',
                  onTitleTap: onTitleTap,
                  chips: <MediaDetailChip>[
                    MediaDetailChip(
                      'Author',
                      key: const ValueKey<String>('author-chip'),
                      onTap: onChipTap,
                    ),
                  ],
                ),
              ],
            ),
          ),
        );

    testWidgets('不传回调：标题与作者 chip 保持纯展示（不挂交互层，点击无反应）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(heroHarness());
      await tester.pumpAndSettle();

      expect(
        find.byType(MediaDetailMouseHoverTap),
        findsNothing,
        reason: 'null 回调不得引入手势 / 悬停层',
      );

      await tester.tap(find.text('Work title'), kind: PointerDeviceKind.mouse);
      await tester.tap(
        find.byKey(const ValueKey<String>('author-chip')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('传回调：标题与作者 chip 接入共享交互层，鼠标点击才触发', (WidgetTester tester) async {
      int titleTaps = 0;
      int chipTaps = 0;
      await tester.pumpWidget(
        heroHarness(onTitleTap: () => titleTaps++, onChipTap: () => chipTaps++),
      );
      await tester.pumpAndSettle();

      expect(
        find.ancestor(
          of: find.text('Work title'),
          matching: find.byType(MediaDetailMouseHoverTap),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('author-chip')),
          matching: find.byType(MediaDetailMouseHoverTap),
        ),
        findsOneWidget,
      );

      // 触摸点击不触发（只响应鼠标）。
      await tester.tap(find.text('Work title'));
      await tester.tap(find.byKey(const ValueKey<String>('author-chip')));
      await tester.pumpAndSettle();
      expect(titleTaps, 0);
      expect(chipTaps, 0);

      // 鼠标点击触发。
      await tester.tap(find.text('Work title'), kind: PointerDeviceKind.mouse);
      await tester.tap(
        find.byKey(const ValueKey<String>('author-chip')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(titleTaps, 1);
      expect(chipTaps, 1);
    });
  });
}
