import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';

/// 共享详情骨架的可选交互（ticket 03）：标题与 chip 只在调用方传回调时变成可
/// 点击；不传时（小说作品页等既有页面）保持纯展示，外观与命中行为零变化。
void main() {
  Widget harness({VoidCallback? onTitleTap, VoidCallback? onChipTap}) =>
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

  Finder chip() => find.byKey(const ValueKey<String>('author-chip'));

  TextStyle titleStyle(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(
          of: find.byType(MediaDetailHero),
          matching: find.text('Work title'),
        ),
      )
      .style!;

  Color chipFill(WidgetTester tester) =>
      (tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: chip(),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration)
          .color!;

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(target));
    await tester.pumpAndSettle();
    return mouse;
  }

  testWidgets('不传回调：标题与作者 chip 保持纯展示（悬停 / 点击都不变）', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(titleStyle(tester).decoration, isNot(TextDecoration.underline));
    final Color restingFill = chipFill(tester);

    final TestGesture mouse = await hover(tester, find.text('Work title'));
    expect(
      titleStyle(tester).decoration,
      isNot(TextDecoration.underline),
      reason: '没有回调时标题不该出现悬停下划线',
    );
    await mouse.moveTo(tester.getCenter(chip()));
    await tester.pumpAndSettle();
    expect(chipFill(tester), restingFill, reason: '没有回调时 chip 不该提亮');

    // 鼠标点击不产生任何反应（没有回调），也不应有 click 光标。
    await tester.tap(find.text('Work title'), kind: PointerDeviceKind.mouse);
    await tester.tap(chip(), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(chipFill(tester), restingFill);
  });

  testWidgets('传回调：标题悬停加下划线、作者 chip 提亮，鼠标点击才触发', (WidgetTester tester) async {
    int titleTaps = 0;
    int chipTaps = 0;
    await tester.pumpWidget(
      harness(onTitleTap: () => titleTaps++, onChipTap: () => chipTaps++),
    );
    await tester.pumpAndSettle();

    expect(titleStyle(tester).decoration, isNot(TextDecoration.underline));
    final Color restingFill = chipFill(tester);

    // 鼠标指针保持默认：最近一层 MouseRegion 不声明 click 光标。
    expect(
      tester
          .widget<MouseRegion>(
            find
                .ancestor(
                  of: find.text('Work title'),
                  matching: find.byType(MouseRegion),
                )
                .first,
          )
          .cursor,
      MouseCursor.defer,
    );

    final TestGesture mouse = await hover(tester, find.text('Work title'));
    expect(titleStyle(tester).decoration, TextDecoration.underline);
    await mouse.moveTo(tester.getCenter(chip()));
    await tester.pumpAndSettle();
    expect(titleStyle(tester).decoration, isNot(TextDecoration.underline));
    expect(chipFill(tester), isNot(restingFill));

    // 触摸点击不触发（只响应鼠标）。
    await tester.tap(find.text('Work title'));
    await tester.tap(chip());
    await tester.pumpAndSettle();
    expect(titleTaps, 0);
    expect(chipTaps, 0);

    // 鼠标点击触发。
    await tester.tap(find.text('Work title'), kind: PointerDeviceKind.mouse);
    await tester.tap(chip(), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(titleTaps, 1);
    expect(chipTaps, 1);
  });
}
