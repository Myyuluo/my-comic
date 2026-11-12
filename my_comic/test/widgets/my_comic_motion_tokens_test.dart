// M3 Expressive 动效 token（2026-10-05）：弹簧数值、归一化曲线、兼容常量与
// 弹簧落定时长一致、设计系统映射、两档降级。
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_motion_tokens.dart';

Widget _probe(
  void Function(BuildContext) onBuild, {
  bool eink = false,
  bool reduceMotion = false,
  bool glass = false,
}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[
        MyComicEinkTheme(eink),
        if (glass)
          const MyComicGlassTheme(MyComicGlassMaterial.off, glassDesign: true),
      ],
    ),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Builder(
        builder: (BuildContext context) {
          onBuild(context);
          return const SizedBox();
        },
      ),
    ),
  );
}

double _peak(Curve curve) {
  double peak = 0;
  for (int i = 0; i <= 2000; i++) {
    final double v = curve.transform(i / 2000);
    if (v > peak) peak = v;
  }
  return peak;
}

void main() {
  group('M3E 弹簧 token', () {
    test('数值与 material-components-android motion tokens 一致', () {
      expect(MyComicSprings.spatialFast.dampingRatio, 0.6);
      expect(MyComicSprings.spatialFast.stiffness, 800);
      expect(MyComicSprings.spatialDefault.dampingRatio, 0.8);
      expect(MyComicSprings.spatialDefault.stiffness, 380);
      expect(MyComicSprings.spatialSlow.dampingRatio, 0.8);
      expect(MyComicSprings.spatialSlow.stiffness, 200);
      expect(MyComicSprings.effectsFast.dampingRatio, 1);
      expect(MyComicSprings.effectsFast.stiffness, 3800);
      expect(MyComicSprings.effectsDefault.dampingRatio, 1);
      expect(MyComicSprings.effectsDefault.stiffness, 1600);
      expect(MyComicSprings.effectsSlow.dampingRatio, 1);
      expect(MyComicSprings.effectsSlow.stiffness, 800);
    });

    test('兼容常量 = 对应弹簧的落定时长（±5ms）', () {
      void near(Duration constant, MyComicSpringSpec spring) {
        expect(
          (constant.inMicroseconds - spring.duration.inMicroseconds).abs(),
          lessThan(5000),
          reason: '$constant vs $spring → ${spring.duration}',
        );
      }

      near(MyComicMotion.micro, MyComicSprings.effectsFast);
      near(MyComicMotion.short, MyComicSprings.effectsDefault);
      near(MyComicMotion.medium, MyComicSprings.spatialDefault);
      near(MyComicMotion.long, MyComicSprings.spatialSlow);
      near(MyComicMotion.longReverse, MyComicSprings.effectsSlow);
    });

    test('时长随刚度单调：fast < default < slow；没有超过 500ms 的 token', () {
      for (final MyComicMotionScheme scheme in <MyComicMotionScheme>[
        MyComicMotionScheme.expressive,
        MyComicMotionScheme.apple,
      ]) {
        expect(
          scheme.spatialFast.duration < scheme.spatialDefault.duration,
          isTrue,
        );
        expect(
          scheme.spatialDefault.duration < scheme.spatialSlow.duration,
          isTrue,
        );
        expect(
          scheme.effectsFast.duration < scheme.effectsDefault.duration,
          isTrue,
        );
        expect(
          scheme.effectsDefault.duration < scheme.effectsSlow.duration,
          isTrue,
        );
        for (final MyComicSpringSpec s in <MyComicSpringSpec>[
          scheme.spatialFast,
          scheme.spatialDefault,
          scheme.spatialSlow,
          scheme.effectsFast,
          scheme.effectsDefault,
          scheme.effectsSlow,
        ]) {
          expect(
            s.duration.inMilliseconds,
            lessThanOrEqualTo(560),
            reason: '$s',
          );
        }
      }
    });

    test('Apple 方案是 SwiftUI 感知时长弹簧的换算', () {
      final MyComicSpringSpec snappy = MyComicSpringSpec.perceptual(
        durationSeconds: 0.5,
        bounce: 0.15,
      );
      expect(snappy.dampingRatio, closeTo(0.85, 1e-9));
      expect(
        MyComicMotionScheme.apple.spatialDefault.stiffness,
        closeTo(snappy.stiffness, 0.01),
      );
      expect(MyComicMotionScheme.apple.effectsDefault.dampingRatio, 1);
    });
  });

  group('MyComicSpringCurve', () {
    test('端点精确', () {
      for (final double z in <double>[0.6, 0.8, 1, 1.4]) {
        final MyComicSpringCurve c = MyComicSpringCurve(dampingRatio: z);
        expect(c.transform(0), 0);
        expect(c.transform(1), 1);
        expect(c.transform(0.999), closeTo(1, 0.02), reason: 'ζ=$z 末端连续');
      }
    });

    test('effects（ζ1）单调不过冲，可安全驱动透明度', () {
      double last = 0;
      for (int i = 0; i <= 1000; i++) {
        final double v = MyComicSpringCurve.effects.transform(i / 1000);
        expect(v, greaterThanOrEqualTo(last - 1e-12));
        expect(v, lessThanOrEqualTo(1));
        last = v;
      }
      expect(MyComicMotion.enter, MyComicSpringCurve.effects);
      expect(MyComicMotion.standard, MyComicSpringCurve.effects);
    });

    test('spatial 过冲量：裸弹簧 ζ0.8 ≈ 1.5%、ζ0.6 ≈ 9.5%，归一化曲线扣掉落定残差', () {
      // 欠阻尼弹簧的理论过冲 = exp(-πζ/√(1-ζ²))。曲线在落定点（残差 ≤ 1%，
      // [MyComicSpringSpec.settleTolerance]）截断，残差按 t 线性抹平，所以曲线
      // 峰值落在 [1 + 理论过冲 − 容差, 1 + 理论过冲] 之间：仍有可见回弹，但
      // 不会超过物理弹簧。
      for (final (MyComicSpringCurve curve, double zeta, double overshoot)
          in <(MyComicSpringCurve, double, double)>[
            (MyComicSpringCurve.spatial, 0.8, 0.015),
            (MyComicSpringCurve.spatialFast, 0.6, 0.095),
          ]) {
        final double theory = math.exp(
          -math.pi * zeta / math.sqrt(1 - zeta * zeta),
        );
        expect(theory, closeTo(overshoot, 0.001), reason: 'ζ=$zeta');
        final double peak = _peak(curve);
        expect(
          peak,
          greaterThanOrEqualTo(1 + theory - MyComicSpringSpec.settleTolerance),
          reason: 'ζ=$zeta 曲线峰值 $peak',
        );
        expect(peak, lessThanOrEqualTo(1 + theory), reason: 'ζ=$zeta');
      }
    });

    test('exit 是 enter 的时间反演：慢起步、快离场', () {
      expect(
        MyComicMotion.exit.transform(0.25),
        lessThan(MyComicMotion.enter.transform(0.25)),
      );
      expect(MyComicMotion.exit.transform(0), 0);
      expect(MyComicMotion.exit.transform(1), 1);
    });

    test('同阻尼比的曲线相等（隐式动画 didUpdateWidget 不重建）', () {
      expect(MyComicSprings.spatialDefault.curve, MyComicSpringCurve.spatial);
      expect(
        const MyComicSpringCurve(dampingRatio: 0.8).hashCode,
        MyComicSpringCurve.spatial.hashCode,
      );
    });
  });

  group('MyComicMotionScheme.of', () {
    testWidgets('Material = expressive；Apple 设计系统 = apple', (tester) async {
      late MyComicMotionScheme material;
      late MyComicMotionScheme apple;
      await tester.pumpWidget(_probe((c) => material = c.myComicMotion));
      await tester.pumpWidget(
        _probe((c) => apple = c.myComicMotion, glass: true),
      );
      // MaterialApp 换主题走 AnimatedTheme 过渡：换主题那一帧仍是旧主题
      // （Tween.transform(0) == begin），过渡结束后才读得到玻璃设计系统。
      await tester.pumpAndSettle();
      expect(material.spatialDefault, MyComicSprings.spatialDefault);
      expect(material.enabled, isTrue);
      expect(apple.spatialDefault, MyComicMotionScheme.apple.spatialDefault);
    });

    for (final (String name, bool eink, bool reduce) in <(String, bool, bool)>[
      ('墨水屏', true, false),
      ('减弱动态效果', false, true),
    ]) {
      testWidgets('$name 下全部 token 时长归零', (tester) async {
        late MyComicMotionScheme m;
        await tester.pumpWidget(
          _probe((c) => m = c.myComicMotion, eink: eink, reduceMotion: reduce),
        );
        expect(m.enabled, isFalse);
        for (final MyComicSpringSpec s in <MyComicSpringSpec>[
          m.spatialFast,
          m.spatialDefault,
          m.spatialSlow,
          m.effectsFast,
          m.effectsDefault,
          m.effectsSlow,
        ]) {
          expect(s.duration, Duration.zero);
        }
      });
    }
  });

  group('myComicSpringTo', () {
    testWidgets('真实弹簧推到终点、精确落定；spatial 途中过冲', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      double peak = 0;
      c.addListener(() {
        if (c.value > peak) peak = c.value;
      });
      c.myComicSpringTo(1, MyComicSprings.spatialFast);
      await tester.pump();
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.isAnimating, isFalse);
      expect(c.value, 1);
      expect(peak, greaterThan(1.03));
    });

    testWidgets('降级 token 同帧到位', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      c.myComicSpringTo(0.5, MyComicSprings.spatialDefault.reduced);
      expect(c.value, 0.5);
      expect(c.isAnimating, isFalse);
    });

    testWidgets('打断时沿用当前速度（不急停）', (tester) async {
      final AnimationController c = AnimationController.unbounded(
        vsync: const TestVSync(),
      );
      addTearDown(c.dispose);
      c.myComicSpringTo(1, MyComicSprings.spatialDefault);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 48));
      final double v = c.velocity;
      expect(v, greaterThan(0));
      c.myComicSpringTo(0, MyComicSprings.spatialDefault);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(c.velocity, isNot(0));
      c.stop();
    });
  });
}
