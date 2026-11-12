import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/platform/desktop/desktop_ctl_host.dart';
import 'package:my_comic_cli/my_comic_cli.dart';

void main() {
  group('classifyCtlOpenTarget', () {
    CtlOpenResult classify(
      String target, {
      bool exists = true,
    }) => classifyCtlOpenTarget(
      target,
      fileExists: (_) => exists,
    );

    test('查词深链', () {
      expect(classify('mycomic://lookup?word=猫').kind, CtlOpenKind.lookup);
    });

    test('存在的视频文件', () {
      expect(classify('/v/ep01.mkv').kind, CtlOpenKind.video);
    });

    test('视频文件不存在 → 拒绝并说明', () {
      final CtlOpenResult result = classify('/v/ep01.mkv', exists: false);
      expect(result.accepted, isFalse);
      expect(result.reason, contains('/v/ep01.mkv'));
    });

    test('不认识的目标 → 拒绝，而不是像 argv 那样静默忽略', () {
      expect(classify('/books/a.epub').accepted, isFalse);
      expect(classify('https://example.com').accepted, isFalse);
    });
  });
}
