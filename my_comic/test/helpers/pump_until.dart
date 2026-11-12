import 'package:flutter_test/flutter_test.dart';

/// 有界推帧直到 [finder] 命中；超时 `fail`。
///
/// 页面级测试里真实 DB / FutureProvider 让 `pumpAndSettle` 等不到静止（周期
/// 定时器、保活订阅），只能按固定步长推帧。集中一份，避免每个测试各抄一个
/// 静默超时版本（超时后断言才发现，失败信息看不到等的是什么）。
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxTries = 100,
  Duration step = const Duration(milliseconds: 50),
}) async {
  for (int i = 0; i < maxTries; i++) {
    await Future<void>.delayed(step);
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('pumpUntilFound: never found $finder after $maxTries tries');
}
