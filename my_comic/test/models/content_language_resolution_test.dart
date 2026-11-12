import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/models/content_font_chain.dart';


void main() {
  group('resolveContentLanguage', () {
    test('三档优先级：资源手动指定 > 内容元数据 > 全局默认', () {
      expect(
        resolveContentLanguage(
          explicit: 'zh-Hant',
          metadata: 'ja',
          globalDefault: 'ko',
        ),
        'zh-Hant',
      );
      expect(
        resolveContentLanguage(metadata: 'ja', globalDefault: 'ko'),
        'ja',
      );
      expect(resolveContentLanguage(globalDefault: 'ko'), 'ko');
      expect(resolveContentLanguage(), isNull);
    });

    test('空串与纯空白视同「没设」——偏好默认值是空串，DB 列也可能存进空串', () {
      // 这条如果错了，症状是「设置里清空了默认语言，却还按空串去建链」，
      // 或者「资源上存了个空串，把真正有值的下一档挡住」。
      expect(
        resolveContentLanguage(explicit: '', metadata: 'ja'),
        'ja',
      );
      expect(
        resolveContentLanguage(explicit: '   ', metadata: 'ja'),
        'ja',
      );
      expect(resolveContentLanguage(explicit: '', globalDefault: ''), isNull);
    });

    test('返回值去掉首尾空白（用户手输的标签常带空格）', () {
      expect(resolveContentLanguage(explicit: '  ja  '), 'ja');
    });
  });

  group('字幕回退链', () {
    test('语言已知时按语言建链，日文不再落到中文字体', () {
      final List<String> ja = contentFontFamilies(
        languageTag: 'ja',
        platform: TargetPlatform.windows,
      );
      expect(ja.first, 'Yu Gothic UI');
      // 中文字体仍在链里（中日混排字幕的缺字续接），但必须排在日文之后。
      expect(
        ja.indexOf('Yu Gothic UI'),
        lessThan(ja.indexOf('Microsoft YaHei UI')),
      );
    });

    test('语言未知 → 空链 → 调用方退回历史链（逐像素不变）', () {
      expect(
        contentFontFamilies(
          languageTag: null,
          platform: TargetPlatform.windows,
        ),
        isEmpty,
      );
    });
  });
}
