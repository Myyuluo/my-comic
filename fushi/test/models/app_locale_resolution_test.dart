import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/utils/fushi_localisations.dart';

/// 界面语言精简为四种后的解析契约（ticket 06）。
///
/// 用户可见行为：
///  - 支持的界面语言只有 en-US、zh-CN、zh-HK、ja；
///  - 系统是繁体中文（zh-TW / zh-Hant / zh-Hant-TW）时落到 zh-HK，绝不能被
///    语言前缀匹配送到 zh-CN；
///  - 默认顺序仍是「已保存偏好 → 系统 locale → 语言前缀 → 英文兜底」，不强制
///    简体中文；
///  - 已删除语言的系统 locale 不再命中，直接回退英文。
void main() {
  Map<String, Locale> available() => <String, Locale>{
    for (final Locale locale in AppModel.supportedLocales)
      locale.toLanguageTag(): locale,
  };

  Locale resolve({String? saved, required Locale system}) =>
      AppModel.resolveAppLocale(
        savedTag: saved,
        systemLocale: system,
        available: available(),
      );

  group('支持的界面语言', () {
    test('恰好是 en-US、zh-CN、zh-HK、ja', () {
      expect(
        AppModel.supportedLocales.map((Locale l) => l.toLanguageTag()),
        <String>['en-US', 'zh-CN', 'zh-HK', 'ja'],
      );
    });

    test('生成代码里的 AppLocale 也只有这四种', () {
      expect(
        AppLocale.values
            .map(
              (AppLocale l) =>
                  Locale(l.languageCode, l.countryCode).toLanguageTag(),
            )
            .toSet(),
        <String>{'en', 'ja', 'zh-CN', 'zh-HK'},
      );
    });

    test('语言名表只剩四项，且标签能直接回查', () {
      expect(FushiLocalisations.localeNames.keys, <String>[
        'en-US',
        'zh-CN',
        'zh-HK',
        'ja',
      ]);
      expect(FushiLocalisations.localeNames['en-US'], 'English');
      expect(FushiLocalisations.localeNames['zh-CN'], '简体中文');
      expect(FushiLocalisations.localeNames['zh-HK'], '繁體中文');
      expect(FushiLocalisations.localeNames['ja'], '日本語');
    });
  });

  group('系统 locale 映射', () {
    test('精确支持的标签原样命中', () {
      expect(
        AppModel.matchSupportedLocale(const Locale('zh', 'HK'), available()),
        const Locale('zh', 'HK'),
      );
      expect(
        AppModel.matchSupportedLocale(const Locale('en', 'US'), available()),
        const Locale('en', 'US'),
      );
    });

    test('zh-TW 落到 zh-HK，而不是 zh-CN', () {
      final Locale resolved = AppModel.matchSupportedLocale(
        const Locale('zh', 'TW'),
        available(),
      )!;
      expect(resolved, const Locale('zh', 'HK'));
      expect(resolved, isNot(const Locale('zh', 'CN')));
    });

    test('zh-Hant 与 zh-Hant-TW 落到 zh-HK', () {
      expect(
        AppModel.matchSupportedLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
          available(),
        ),
        const Locale('zh', 'HK'),
      );
      expect(
        AppModel.matchSupportedLocale(
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
          available(),
        ),
        const Locale('zh', 'HK'),
      );
    });

    test('zh-Hans 仍落到 zh-CN', () {
      expect(
        AppModel.matchSupportedLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
          available(),
        ),
        const Locale('zh', 'CN'),
      );
    });

    test('地区变体按语言前缀命中（ja-JP、en-GB、zh）', () {
      expect(
        AppModel.matchSupportedLocale(const Locale('ja', 'JP'), available()),
        const Locale('ja'),
      );
      expect(
        AppModel.matchSupportedLocale(const Locale('en', 'GB'), available()),
        const Locale('en', 'US'),
      );
      expect(
        AppModel.matchSupportedLocale(const Locale('zh'), available()),
        const Locale('zh', 'CN'),
      );
    });

    test('已删除的语言不再命中', () {
      for (final String tag in <String>['ko-KR', 'fr-FR', 'de-DE', 'ru-RU']) {
        final Locale system = Locale(tag.split('-').first);
        expect(
          AppModel.matchSupportedLocale(system, available()),
          isNull,
          reason: '$tag 不再是支持的界面语言',
        );
      }
    });
  });

  group('解析顺序：已保存偏好 → 系统 locale → 语言前缀 → 英文兜底', () {
    test('已保存偏好优先于系统 locale', () {
      expect(
        resolve(saved: 'ja', system: const Locale('zh', 'TW')),
        const Locale('ja'),
      );
    });

    test('已删除语言的旧偏好被忽略，继续跟随系统', () {
      expect(
        resolve(saved: 'ko', system: const Locale('zh', 'TW')),
        const Locale('zh', 'HK'),
      );
    });

    test('没有偏好时跟随系统', () {
      expect(resolve(system: const Locale('ja', 'JP')), const Locale('ja'));
    });

    test('系统是繁体时默认不是简体', () {
      expect(
        resolve(system: const Locale('zh', 'TW')),
        const Locale('zh', 'HK'),
      );
    });

    test('不支持的系统语言回退英文', () {
      expect(
        resolve(system: const Locale('ko', 'KR')),
        const Locale('en', 'US'),
      );
    });
  });
}
