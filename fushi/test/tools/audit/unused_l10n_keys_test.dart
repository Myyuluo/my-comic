// 未使用 l10n key 扫描器（tool/audit/unused_l10n_keys.dart）的行为测试。
//
// 扫描器读取 base `strings.i18n.json` 的 key 集合，扫描 app 的 lib / test /
// integration_test，排除生成的 strings.g.dart；只报告，不修改产品代码。
//
// ignore_for_file: always_use_package_imports

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/audit/unused_l10n_keys.dart';

void main() {
  group('flattenTranslationKeys', () {
    test('扁平与嵌套 key 都展开为点路径', () {
      expect(
        flattenTranslationKeys(<String, dynamic>{
          'a': 'x',
          'b': <String, dynamic>{
            'c': 'y',
            'd': <String, dynamic>{'e': 'z'},
          },
        }),
        <String>{'a', 'b.c', 'b.d.e'},
      );
    });

    test('空 map 与空对象不产生 key', () {
      expect(flattenTranslationKeys(<String, dynamic>{}), isEmpty);
      expect(
        flattenTranslationKeys(<String, dynamic>{'only': <String, dynamic>{}}),
        isEmpty,
      );
    });
  });

  group('featurePrefix', () {
    test('扁平 key 取第一个下划线之前的部分', () {
      expect(featurePrefix('video_error_message'), 'video');
      expect(featurePrefix('manga_title'), 'manga');
    });

    test('没有下划线时整段就是前缀', () {
      expect(featurePrefix('settings'), 'settings');
    });

    test('嵌套 key 用第一个点段', () {
      expect(featurePrefix('settings.appearance.theme'), 'settings');
      expect(featurePrefix('settings.download_dir'), 'settings');
    });
  });

  group('extractReferencedKeys', () {
    // 用 zz_ 前缀避免与真实 base key 重名：本文件本身会被扫描器扫描，
    // 字符串里的 `t.<真实 key>` 会被保守计为引用。
    const Set<String> keys = <String>{
      'zz_reader_title',
      'zzsettings',
      'zzsettings.appearance.theme',
      'zz_about_attribution',
    };

    test('t.key 与链式调用后的 .key 都算引用', () {
      expect(
        extractReferencedKeys(
          'final t = Translations.of(context);\n'
          'return t.zz_reader_title;',
          keys,
        ),
        <String>{'zz_reader_title'},
      );
      expect(
        extractReferencedKeys('Translations.of(context).zz_reader_title', keys),
        <String>{'zz_reader_title'},
      );
    });

    test('多段 key 按点链匹配，路径上的每个成员后缀都算候选', () {
      expect(
        extractReferencedKeys('t.zzsettings.appearance.theme', keys),
        <String>{'zzsettings', 'zzsettings.appearance.theme'},
      );
    });

    test('注释里的 key 不算引用', () {
      expect(
        extractReferencedKeys('// t.zz_reader_title\nfinal x = 1;', keys),
        isEmpty,
      );
      expect(
        extractReferencedKeys('/* t.zz_reader_title */ final x = 1;', keys),
        isEmpty,
      );
    });

    test('字符串里的 // 不会开启注释', () {
      expect(
        extractReferencedKeys(
          "const u = 'http://example.com';\nfinal y = t.zz_reader_title;",
          keys,
        ),
        <String>{'zz_reader_title'},
      );
    });

    test('字符串字面量里的 .key 保守计为引用', () {
      expect(
        extractReferencedKeys("const s = 't.zz_reader_title';", keys),
        <String>{'zz_reader_title'},
      );
      expect(
        extractReferencedKeys("const s = '\${t.zz_reader_title}';", keys),
        <String>{'zz_reader_title'},
      );
    });

    test('裸标识符不算引用', () {
      expect(extractReferencedKeys('final reader_title = 1;', keys), isEmpty);
    });

    test('同前缀的更长标识符不算引用', () {
      expect(extractReferencedKeys('t.zz_reader_title_extra', keys), isEmpty);
    });
  });

  group('parseDynamicAllowlist', () {
    test('支持精确 key、前缀与正则，且必须给出 reason', () {
      final List<DynamicKeyRule> rules = parseDynamicAllowlist(r'''
      {"rules": [
        {"key": "exact_key", "reason": "精确"},
        {"prefix": "dynamic_", "reason": "前缀"},
        {"pattern": "^suffix_.*_key$", "reason": "正则"}
      ]}''');
      expect(rules, hasLength(3));
      expect(rules[0].matches('exact_key'), isTrue);
      expect(rules[0].matches('exact_key_2'), isFalse);
      expect(rules[1].matches('dynamic_anything'), isTrue);
      expect(rules[2].matches('suffix_any_key'), isTrue);
      expect(rules[2].matches('nope'), isFalse);
      expect(rules[1].reason, '前缀');
    });

    test('一条规则只能有一个匹配条件', () {
      expect(
        () => parseDynamicAllowlist(
          '{"rules": [{"key": "a", "prefix": "b", "reason": "x"}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => parseDynamicAllowlist('{"rules": [{"reason": "x"}]}'),
        throwsFormatException,
      );
    });
  });

  group('scanUnusedL10nKeys', () {
    late Directory app;

    setUp(() {
      app = _makeFixtureApp();
    });

    tearDown(() {
      app.deleteSync(recursive: true);
    });

    test('扫描 lib/test/integration_test，排除 strings.g.dart，并支持动态 allowlist', () {
      final UnusedL10nReport report = scanUnusedL10nKeys(
        appRoot: app.path,
        allowRules: parseDynamicAllowlist(r'''
        {"rules": [{"key": "dynamic_key", "reason": "动态拼 key"}]}'''),
      );

      expect(report.totalKeys, 5);
      expect(report.scannedFileCount, 3);
      expect(report.referencedCount, 2);
      expect(report.unusedCount, 2);
      expect(report.allowlistedUnusedCount, 1);

      final L10nKeyUsage used = report.keys.singleWhere(
        (L10nKeyUsage usage) => usage.key == 'used_key',
      );
      expect(used.referenced, isTrue);
      expect(used.files, <String>['lib/main.dart', 'test/app_test.dart']);
      expect(used.prefix, 'used');

      final L10nKeyUsage nestedUsed = report.keys.singleWhere(
        (L10nKeyUsage usage) => usage.key == 'nested.used',
      );
      expect(nestedUsed.referenced, isTrue);
      expect(nestedUsed.files, <String>['lib/main.dart']);

      final L10nKeyUsage dead = report.keys.singleWhere(
        (L10nKeyUsage usage) => usage.key == 'dead_key',
      );
      expect(dead.referenced, isFalse);
      expect(dead.allowlisted, isFalse);
      expect(dead.unused, isTrue);
      expect(dead.files, isEmpty);

      final L10nKeyUsage dynamicKey = report.keys.singleWhere(
        (L10nKeyUsage usage) => usage.key == 'dynamic_key',
      );
      expect(dynamicKey.referenced, isFalse);
      expect(dynamicKey.allowlisted, isTrue);
      expect(dynamicKey.unused, isFalse);
      expect(dynamicKey.allowReason, '动态拼 key');

      final List<PrefixStats> prefixes = report.prefixStats();
      expect(prefixes.map((PrefixStats stats) => stats.prefix), <String>[
        'dead',
        'dynamic',
        'nested',
        'used',
      ]);
      final PrefixStats nested = prefixes.singleWhere(
        (PrefixStats stats) => stats.prefix == 'nested',
      );
      expect(nested.total, 2);
      expect(nested.referenced, 1);
      expect(nested.unused, 1);
      final PrefixStats dynamic = prefixes.singleWhere(
        (PrefixStats stats) => stats.prefix == 'dynamic',
      );
      expect(dynamic.allowlistedUnused, 1);
    });

    test('toJson 与 toText 输出 key、引用文件与功能前缀', () {
      final UnusedL10nReport report = scanUnusedL10nKeys(
        appRoot: app.path,
        allowRules: <DynamicKeyRule>[],
      );

      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
      expect(json['scanner'], 'unused_l10n_keys');
      expect(json['base_file'], 'lib/i18n/strings.i18n.json');
      expect(json['scanned_files'], 3);
      expect(json['total_keys'], 5);
      expect(json['referenced_keys'], 2);
      expect(json['unused_keys'], 3);
      expect(json['allowlisted_unused_keys'], 0);
      final List<dynamic> keys = json['keys'] as List<dynamic>;
      expect(
        keys.map((dynamic k) => (k as Map<String, dynamic>)['key']),
        <String>[
          'dead_key',
          'dynamic_key',
          'nested.dead',
          'nested.used',
          'used_key',
        ],
      );
      final Map<String, dynamic> used = keys
          .cast<Map<String, dynamic>>()
          .singleWhere((Map<String, dynamic> k) => k['key'] == 'used_key');
      expect(used['referenced'], isTrue);
      expect(used['files'], <String>['lib/main.dart', 'test/app_test.dart']);
      expect(used['prefix'], 'used');

      final String text = report.toText();
      expect(
        text,
        contains('keys: 5  referenced: 2  unused: 3  allowlisted_unused: 0'),
      );
      expect(text, contains('## Unused keys (prefix  key)'));
      expect(text, contains('dead  dead_key'));
      expect(text, contains('nested  nested.dead'));

      final String summary = report.toSummaryText();
      expect(summary, contains('keys: 5  referenced: 2  unused: 3'));
      expect(summary, contains('## Prefixes'));
      expect(summary, isNot(contains('dead  dead_key')));
    });
  });
}

Directory _makeFixtureApp() {
  final Directory app = Directory.systemTemp.createTempSync('l10n-scan-');
  _writeText(
    app,
    'lib/i18n/strings.i18n.json',
    const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'dead_key': 'Dead',
      'dynamic_key': 'Dynamic',
      'nested': <String, dynamic>{'dead': 'Nested dead', 'used': 'Nested used'},
      'used_key': 'Used',
    }),
  );
  _writeText(
    app,
    'lib/main.dart',
    'final t = Translations.of(context);\n'
        'return t.used_key;\n'
        '// t.dead_key\n'
        'final nested = t.nested.used;\n',
  );
  _writeText(
    app,
    'test/app_test.dart',
    "expect(Translations.of(context).used_key, 'Used');\n",
  );
  _writeText(app, 'integration_test/itest.dart', '// no keys here\n');
  _writeText(
    app,
    'lib/i18n/strings.g.dart',
    'class Translations { dynamic get dead_key => null; '
        'dynamic get dynamic_key => null; '
        'dynamic get nested => null; }\n',
  );
  return app;
}

void _writeText(Directory root, String relativePath, String content) {
  final File file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
