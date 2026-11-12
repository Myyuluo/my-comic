import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/utils/misc/my_comic_byte_format.dart';

void main() {
  group('MyComicByteFormat.bytes', () {
    test('null → —（未知大小占位）', () {
      expect(MyComicByteFormat.bytes(null), '—');
    });

    test('B 档整数不带小数', () {
      expect(MyComicByteFormat.bytes(0), '0 B');
      expect(MyComicByteFormat.bytes(512), '512 B');
      expect(MyComicByteFormat.bytes(1023), '1023 B');
    });

    test('KB/MB/GB 保留 1 位小数', () {
      expect(MyComicByteFormat.bytes(1024), '1.0 KB');
      expect(MyComicByteFormat.bytes(1536), '1.5 KB');
      expect(MyComicByteFormat.bytes(5 * 1024 * 1024), '5.0 MB');
      expect(MyComicByteFormat.bytes(3 * 1024 * 1024 * 1024), '3.0 GB');
    });

    test('GB 封顶不再升档', () {
      expect(
        MyComicByteFormat.bytes(2048 * 1024 * 1024 * 1024),
        '2048.0 GB',
      );
    });

    test('负值保留符号并正常换档', () {
      expect(MyComicByteFormat.bytes(-512), '-512 B');
      expect(MyComicByteFormat.bytes(-2048), '-2.0 KB');
    });
  });

  group('MyComicByteFormat.speed', () {
    test('null / 负值 / 非有限 → —', () {
      expect(MyComicByteFormat.speed(null), '—');
      expect(MyComicByteFormat.speed(-1), '—');
      expect(MyComicByteFormat.speed(double.infinity), '—');
      expect(MyComicByteFormat.speed(double.nan), '—');
    });

    test('速率 = bytes 文案 + /s 后缀', () {
      expect(MyComicByteFormat.speed(1536), '1.5 KB/s');
      expect(MyComicByteFormat.speed(0), '0 B/s');
    });
  });
}
