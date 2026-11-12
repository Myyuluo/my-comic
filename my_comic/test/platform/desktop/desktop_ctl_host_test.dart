import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/platform/desktop/desktop_ctl_host.dart';
import 'package:my_comic_cli/my_comic_cli.dart';

void main() {
  group('classifyCtlOpenTarget', () {
    test('外部视频 / 查词 / 深链一律拒绝（只支持 app 内书架）', () {
      for (final String target in <String>[
        'mycomic://lookup?word=猫',
        '/v/ep01.mkv',
        '/books/a.epub',
        'https://example.com',
      ]) {
        final CtlOpenResult result = classifyCtlOpenTarget(target);
        expect(result.accepted, isFalse, reason: target);
        expect(result.reason, isNotEmpty, reason: target);
      }
    });
  });
}
