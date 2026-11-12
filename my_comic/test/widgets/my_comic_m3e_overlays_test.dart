import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/my_comic_m3e_overlays.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_feedback.dart'
    show MyComicLinearProgressIndicator;
import 'package:my_comic/src/utils/components/glass/my_comic_glass_overlays.dart'
    show MyComicAlertDialog;
import 'package:my_comic/src/utils/misc/show_app_dialog.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';

/// M3E 共享浮层（对话框路由 / 标准模板 / 底部弹层自适应）的行为测试。
void main() {
  Future<BuildContext> pumpHost(
    WidgetTester tester, {
    Size size = const Size(420, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              hostContext = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return hostContext;
  }

  group('MyComicSpringCurve', () {
    test('端点钉死、欠阻尼中途回弹越过 1', () {
      const MyComicSpringCurve curve = MyComicSpringCurve(
        stiffness: 380,
        dampingRatio: 0.72,
        duration: Duration(milliseconds: 450),
      );
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      double peak = 0;
      for (int i = 1; i < 100; i++) {
        peak = peak < curve.transform(i / 100)
            ? curve.transform(i / 100)
            : peak;
      }
      expect(peak, greaterThan(1.0));
      expect(peak, lessThan(1.1));
    });

    test('临界阻尼单调不过冲', () {
      const MyComicSpringCurve curve = MyComicSpringCurve(
        stiffness: 380,
        dampingRatio: 1,
        duration: Duration(milliseconds: 420),
      );
      double last = 0;
      for (int i = 1; i < 100; i++) {
        final double v = curve.transform(i / 100);
        expect(v, greaterThanOrEqualTo(last));
        expect(v, lessThanOrEqualTo(1.0));
        last = v;
      }
    });
  });

  testWidgets('showAppDialog 推 MyComicDialogRoute，遮罩为 scrim@32%', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    showAppDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(title: Text('hello')),
    );
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    final ModalRoute<Object?> route = ModalRoute.of(
      tester.element(find.text('hello')),
    )!;
    expect(route, isA<MyComicDialogRoute<void>>());
    final ColorScheme cs = Theme.of(context).colorScheme;
    expect(
      (route as MyComicDialogRoute<void>).barrierColor,
      cs.scrim.withValues(alpha: 0.32),
    );
  });

  testWidgets('确认模板：取消 → false，确认 → true，Enter 直接确认', (
    WidgetTester tester,
  ) async {
    final BuildContext context = await pumpHost(tester);
    Future<bool> result = showMyComicConfirmDialog(
      context: context,
      title: '删除？',
      message: '不可撤销',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
      icon: Icons.delete_outline,
      destructive: true,
    );
    await tester.pumpAndSettle();
    expect(find.byType(MyComicDialogHeroIcon), findsOneWidget);
    await tester.tap(find.text('NO'));
    await tester.pumpAndSettle();
    expect(await result, isFalse);

    result = showMyComicConfirmDialog(
      context: context,
      title: '删除？',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('DEL'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);

    result = showMyComicConfirmDialog(
      context: context,
      title: '删除？',
      confirmLabel: 'DEL',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets('确认模板：Esc 关闭返回 false', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<bool> result = showMyComicConfirmDialog(
      context: context,
      title: 'Esc',
      confirmLabel: 'OK',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('文本输入模板：空值禁止提交、Enter 提交 trim 后文本', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<String?> result = showMyComicTextInputDialog(
      context: context,
      title: '命名',
      confirmLabel: 'OK',
      cancelLabel: 'NO',
    );
    await tester.pumpAndSettle();
    final Finder ok = find.widgetWithText(FilledButton, 'OK');
    expect(tester.widget<FilledButton>(ok).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  abc  ');
    await tester.pump();
    expect(tester.widget<FilledButton>(ok).onPressed, isNotNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(await result, 'abc');
  });

  testWidgets('单选模板：点一项返回其值；当前项带对勾', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<int?> result = showMyComicChoiceDialog<int>(
      context: context,
      title: '选择',
      selected: 2,
      options: const <MyComicChoiceOption<int>>[
        MyComicChoiceOption<int>(value: 1, label: 'one'),
        MyComicChoiceOption<int>(value: 2, label: 'two'),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(MyComicIcons.check), findsOneWidget);
    await tester.tap(find.text('one'));
    await tester.pumpAndSettle();
    expect(await result, 1);
  });

  testWidgets('多选模板：切换后确认返回集合', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final Future<Set<String>?> result = showMyComicMultiChoiceDialog<String>(
      context: context,
      title: '多选',
      initial: const <String>{'a'},
      confirmLabel: 'OK',
      cancelLabel: 'NO',
      options: const <MyComicChoiceOption<String>>[
        MyComicChoiceOption<String>(value: 'a', label: 'A'),
        MyComicChoiceOption<String>(value: 'b', label: 'B'),
      ],
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(await result, <String>{'b'});
  });

  testWidgets('进度模板：handle.close 关闭对话框并完成 done', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    final MyComicProgressDialogHandle handle = showMyComicProgressDialog(
      context: context,
      title: '导入中',
      initialProgress: 0.25,
    );
    // MD3 下确定态进度条是 M3E 波浪条（MyComicWavyLinearProgress），波形按设计
    // 持续向前流动，对话框开着时永远不会 settle：按进场动效时长泵帧。
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(MyComicLinearProgressIndicator), findsOneWidget);
    expect(find.text('导入中'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    handle.progress.value = 0.5;
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    handle.close();
    await tester.pumpAndSettle();
    expect(find.text('导入中'), findsNothing);
    await handle.done;
  });

  testWidgets('底部弹层：窄屏是带拖动条的 BottomSheet，宽屏是居中浮动面板', (
    WidgetTester tester,
  ) async {
    BuildContext context = await pumpHost(tester);
    adaptiveModalSheet<void>(
      context: context,
      builder: (_) => const Text('sheet body'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(MyComicM3eSheetBody), findsOneWidget);
    Navigator.of(tester.element(find.text('sheet body'))).pop();
    await tester.pumpAndSettle();

    context = await pumpHost(tester, size: const Size(1600, 900));
    adaptiveModalSheet<void>(
      context: context,
      builder: (_) => const Text('sheet body'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(MyComicM3eFloatingSheet), findsOneWidget);
  });

  testWidgets('底部弹层两档：点拖动条在半屏与 92% 之间切换', (WidgetTester tester) async {
    final BuildContext context = await pumpHost(tester);
    adaptiveModalSheet<void>(
      context: context,
      expandable: true,
      builder: (_) => ListView(
        children: <Widget>[
          for (int i = 0; i < 80; i++) SizedBox(height: 40, child: Text('$i')),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final double collapsed = tester.getSize(find.byType(BottomSheet)).height;
    expect(collapsed, closeTo(900 * kMyComicSheetHalfFraction, 1));
    await tester.tapAt(
      tester.getTopLeft(find.byType(BottomSheet)) + const Offset(210, 24),
    );
    await tester.pumpAndSettle();
    final double expanded = tester.getSize(find.byType(BottomSheet)).height;
    expect(expanded, closeTo(900 * kMyComicSheetFullFraction, 1));
  });
  // BUG-3211：AlertDialog 的 icon 槽在 stretch Column 里（宽约束是紧的），hero 底板
  // 曾被撑成满宽横条（「选择句子上下文」顶部的黄色波浪 + 小小的「99」引号）。
  for (final bool scrollable in <bool>[false, true]) {
    testWidgets('对话框 hero 图标底板保持见方（scrollable: $scrollable）', (
      WidgetTester tester,
    ) async {
      final BuildContext context = await pumpHost(tester);
      unawaited(
        showAppDialog<void>(
          context: context,
          builder: (BuildContext _) => MyComicAlertDialog(
            scrollable: scrollable,
            icon: const MyComicDialogHeroIcon(
              icon: MyComicIcons.quote,
              tone: MyComicHeroTone.primary,
              size: 48,
            ),
            title: const Text('选择句子上下文'),
            content: const SizedBox(width: 460, height: 40),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder plate = find.descendant(
        of: find.byType(MyComicDialogHeroIcon),
        matching: find.byWidgetPredicate(
          (Widget w) => w is DecoratedBox && w.decoration is ShapeDecoration,
        ),
      );
      expect(plate, findsOneWidget);
      expect(tester.getSize(plate), const Size(48, 48));
      // 居中：底板中心与对话框标题区同一条竖直中线。
      final double dialogCenter = tester.getCenter(find.byType(AlertDialog)).dx;
      expect(tester.getCenter(plate).dx, closeTo(dialogCenter, 0.5));
    });
  }
}
