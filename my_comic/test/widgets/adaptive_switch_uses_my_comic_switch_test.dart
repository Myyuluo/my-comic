// adaptiveSwitch 的 Material（M3E）分支必须走 MyComicSwitch：直接 new 一个裸
// Material Switch 会绕过 Expressive 开关（关态叉号、圆钮尺寸）与设计系统分派，
// 和其它 MyComicSwitch 调用点观感不一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_widgets.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_toggles.dart'
    show MyComicSwitch;
import 'package:material_ui/material_ui.dart';

Widget _harness(Widget Function(BuildContext) builder) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: Scaffold(
      body: Center(child: Builder(builder: builder)),
    ),
  );
}

void main() {
  testWidgets('Material 分支渲染 MyComicSwitch 并把值 / 回调 / 颜色透传', (
    WidgetTester tester,
  ) async {
    bool value = false;
    await tester.pumpWidget(
      _harness(
        (BuildContext context) => adaptiveSwitch(
          context: context,
          value: value,
          onChanged: (bool v) => value = v,
          activeColor: const Color(0xFF123456),
        ),
      ),
    );
    final Finder finder = find.byType(MyComicSwitch);
    expect(finder, findsOneWidget);
    final MyComicSwitch sw = tester.widget<MyComicSwitch>(finder);
    expect(sw.value, isFalse);
    expect(sw.activeColor, const Color(0xFF123456));
    expect(sw.onChanged, isNotNull);

    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(value, isTrue, reason: '点击必须经 MyComicSwitch 把新值回调出来');
  });

  testWidgets('onChanged 为 null 时 MyComicSwitch 处于禁用态', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        (BuildContext context) =>
            adaptiveSwitch(context: context, value: true, onChanged: null),
      ),
    );
    final MyComicSwitch sw = tester.widget<MyComicSwitch>(find.byType(MyComicSwitch));
    expect(sw.onChanged, isNull);
  });
}
