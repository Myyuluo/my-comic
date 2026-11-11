// Fushi 引用扫描器（tool/audit/fushi_references.dart）的行为测试。
//
// 扫描器只读版本控制中的文本文件，不进入产品运行时；这里只测它对外暴露的
// 纯函数与扫描结果，不关心内部实现。
//
// ignore_for_file: always_use_package_imports

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../tool/audit/fushi_references.dart';

void main() {
  group('pathMatchesGlob', () {
    test('精确路径只匹配自身', () {
      expect(pathMatchesGlob('LICENSE', 'LICENSE'), isTrue);
      expect(pathMatchesGlob('LICENSE.md', 'LICENSE'), isFalse);
    });

    test('* 不跨目录', () {
      expect(pathMatchesGlob('docs/0001.md', 'docs/*.md'), isTrue);
      expect(pathMatchesGlob('docs/adr/0001.md', 'docs/*.md'), isFalse);
    });

    test('** 可跨目录，也可匹配零层目录', () {
      expect(pathMatchesGlob('docs/adr/0001.md', 'docs/adr/**'), isTrue);
      expect(pathMatchesGlob('docs/adr/a/b.md', 'docs/adr/**'), isTrue);
      expect(pathMatchesGlob('third_party/pkg/NOTICE', '**/NOTICE*'), isTrue);
      expect(pathMatchesGlob('NOTICE', '**/NOTICE*'), isTrue);
      expect(
        pathMatchesGlob('third_party/pkg/README.md', '**/NOTICE*'),
        isFalse,
      );
    });

    test('Windows 反斜杠路径按 / 处理', () {
      expect(pathMatchesGlob(r'docs\adr\0001.md', 'docs/adr/**'), isTrue);
    });
  });

  group('categorizeReference', () {
    FushiReferenceCategory category(String path, String line) {
      final RegExpMatch match = RegExp(
        'fushi',
        caseSensitive: false,
      ).firstMatch(line)!;
      return categorizeReference(
        path: path,
        line: line,
        matchStart: match.start,
      );
    }

    test('许可证、第三方与历史文档按路径分类', () {
      expect(
        category('LICENSE', 'Copyright Fushi'),
        FushiReferenceCategory.license,
      );
      expect(
        category('third_party/desktop_drop/PATCHES.md', 'Fushi patch'),
        FushiReferenceCategory.thirdParty,
      );
      expect(
        category('ci/patches/hosted/x/FUSHI_PATCH.md', 'Fushi patch'),
        FushiReferenceCategory.thirdParty,
      );
      expect(
        category('UPSTREAM.md', 'Based on Fushi v3.0.0'),
        FushiReferenceCategory.historicalDocs,
      );
      expect(
        category('docs/adr/0001-base-on-fushi-snapshot.md', 'Fushi snapshot'),
        FushiReferenceCategory.historicalDocs,
      );
      expect(
        category('docs/bugs/001.md', 'Fushi bug'),
        FushiReferenceCategory.historicalDocs,
      );
      expect(
        category('.scratch/spec.md', 'Fushi upstream'),
        FushiReferenceCategory.historicalDocs,
      );
    });

    test('l10n JSON 归类为用户可见文案', () {
      expect(
        category('fushi/lib/i18n/strings.i18n.json', '"app": "Fushi"'),
        FushiReferenceCategory.userVisibleCopy,
      );
    });

    test('代码里的字符串字面量归类为用户可见文案', () {
      expect(
        category('fushi/lib/src/main.dart', "  final name = 'Fushi';"),
        FushiReferenceCategory.userVisibleCopy,
      );
      expect(
        category('fushi/lib/src/main.dart', '  Text("Fushi")'),
        FushiReferenceCategory.userVisibleCopy,
      );
    });

    test('代码里的注释归类为文档', () {
      expect(
        category('fushi/lib/src/main.dart', '// Fushi entrypoint'),
        FushiReferenceCategory.docs,
      );
      expect(
        category('fushi/lib/src/main.dart', '/// Fushi entrypoint'),
        FushiReferenceCategory.docs,
      );
    });

    test('标识符、import 与路径归类为代码', () {
      expect(
        category('fushi/lib/src/main.dart', "import 'package:fushi/x.dart';"),
        FushiReferenceCategory.code,
      );
      expect(
        category('fushi/lib/src/main.dart', 'class FushiApp {}'),
        FushiReferenceCategory.code,
      );
      expect(
        category('fushi/pubspec.yaml', 'name: fushi'),
        FushiReferenceCategory.code,
      );
    });

    test('Markdown 与文本文件归类为文档', () {
      expect(category('README.md', '# Fushi'), FushiReferenceCategory.docs);
      expect(
        category('NOTICE.txt', 'Fushi notice'),
        FushiReferenceCategory.thirdParty,
      );
    });
  });

  group('AllowRule', () {
    test('只有 path 的规则放行整个文件', () {
      final rule = AllowRule(pathGlob: 'LICENSE', reason: 'GPL 全文');
      expect(rule.matches('LICENSE', 'Copyright Fushi'), isTrue);
    });

    test('line_pattern 只放行匹配行', () {
      final rule = AllowRule(
        pathGlob: 'README.md',
        linePattern: RegExp(r'Fushi v3\.0\.0'),
        reason: '来源署名',
      );
      expect(rule.matches('README.md', 'Based on Fushi v3.0.0'), isTrue);
      expect(rule.matches('README.md', 'Fushi the app'), isFalse);
      expect(rule.matches('OTHER.md', 'Based on Fushi v3.0.0'), isFalse);
    });

    test('parseAllowlist 解析 path、line_pattern 与 reason', () {
      final List<AllowRule> rules = parseAllowlist(r'''
      {"rules": [
        {"path": "LICENSE", "reason": "GPL 全文"},
        {"path": "README.md", "line_pattern": "Fushi v3\\.0\\.0", "reason": "来源署名"}
      ]}''');
      expect(rules, hasLength(2));
      expect(rules[0].pathGlob, 'LICENSE');
      expect(rules[0].reason, 'GPL 全文');
      expect(rules[0].linePattern, isNull);
      expect(rules[1].pathGlob, 'README.md');
      expect(rules[1].linePattern!.hasMatch('Fushi v3.0.0'), isTrue);
      expect(rules[1].reason, '来源署名');
    });
  });

  group('scanFushiReferences', () {
    late Directory repo;

    setUp(() {
      repo = _makeFixtureRepo();
    });

    tearDown(() {
      repo.deleteSync(recursive: true);
    });

    test('只扫描受版本控制的文本文件，并分类 / 标记 allowlist', () {
      final List<AllowRule> rules = parseAllowlist(r'''
      {"rules": [
        {"path": "LICENSE", "reason": "GPL 全文"},
        {"path": "**/NOTICE*", "reason": "第三方声明"},
        {"path": "docs/adr/**", "reason": "ADR"},
        {"path": "README.md", "line_pattern": "Fushi v3\\.0\\.0", "reason": "来源署名"}
      ]}''');

      final FushiReferenceReport report = scanFushiReferences(
        repoRoot: repo.path,
        allowRules: rules,
      );

      expect(report.scannedFileCount, 6);
      expect(report.totalHits, 8);
      expect(report.allowedHitCount, 4);
      expect(report.violationCount, 4);
      expect(report.hits.map((FushiReferenceHit h) => h.path).toSet(), <String>{
        'LICENSE',
        'README.md',
        'docs/adr/0001.md',
        'fushi/lib/i18n/strings.i18n.json',
        'fushi/lib/src/main.dart',
        'third_party/pkg/NOTICE',
      });

      final List<FushiReferenceHit> mainHits = report.hits
          .where((FushiReferenceHit h) => h.path == 'fushi/lib/src/main.dart')
          .toList();
      expect(mainHits.map((FushiReferenceHit h) => h.lineNumber), <int>[
        1,
        2,
        3,
      ]);
      expect(
        mainHits.map((FushiReferenceHit h) => h.category),
        <FushiReferenceCategory>[
          FushiReferenceCategory.docs,
          FushiReferenceCategory.code,
          FushiReferenceCategory.userVisibleCopy,
        ],
      );
      expect(mainHits.every((FushiReferenceHit h) => !h.allowed), isTrue);

      final FushiReferenceHit readme = report.hits.singleWhere(
        (FushiReferenceHit h) => h.path == 'README.md',
      );
      expect(readme.allowed, isTrue);
      expect(readme.category, FushiReferenceCategory.docs);

      final FushiReferenceHit untracked = report.hits.singleWhere(
        (FushiReferenceHit h) => h.path == 'LICENSE',
      );
      expect(untracked.allowed, isTrue);
      expect(untracked.allowReason, 'GPL 全文');
    });

    test('toJson 与 toText 输出文件级和行级结果', () {
      final FushiReferenceReport report = scanFushiReferences(
        repoRoot: repo.path,
        allowRules: <AllowRule>[
          AllowRule(pathGlob: 'LICENSE', reason: 'GPL 全文'),
        ],
      );

      final Map<String, dynamic> json =
          jsonDecode(jsonEncode(report.toJson())) as Map<String, dynamic>;
      expect(json['scanner'], 'fushi_references');
      expect(json['total_hits'], 8);
      expect(json['violations'], 7);
      final List<dynamic> files = json['files'] as List<dynamic>;
      expect(
        files.map((dynamic f) => (f as Map<String, dynamic>)['path']),
        <String>[
          'LICENSE',
          'README.md',
          'docs/adr/0001.md',
          'fushi/lib/i18n/strings.i18n.json',
          'fushi/lib/src/main.dart',
          'third_party/pkg/NOTICE',
        ],
      );
      final Map<String, dynamic> mainFile = files
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (Map<String, dynamic> f) => f['path'] == 'fushi/lib/src/main.dart',
          );
      expect(mainFile['hits'], 3);
      expect(mainFile['violations'], 3);
      final List<dynamic> lines = mainFile['lines'] as List<dynamic>;
      expect((lines.first as Map<String, dynamic>)['line'], 1);
      expect((lines.first as Map<String, dynamic>)['category'], 'docs');
      expect((lines.first as Map<String, dynamic>)['allowed'], isFalse);

      final String text = report.toText();
      expect(text, contains('tracked files scanned: 6'));
      expect(text, contains('hits: 8  allowed: 1  violations: 7'));
      expect(
        text,
        contains('fushi/lib/src/main.dart:1: [docs] // Fushi entrypoint'),
      );
      expect(text, contains('fushi/lib/src/main.dart:2: [code]'));
    });

    test('toSummaryText 只输出汇总、目录分布与文件排名', () {
      final FushiReferenceReport report = scanFushiReferences(
        repoRoot: repo.path,
        allowRules: const <AllowRule>[],
      );

      final String summary = report.toSummaryText(topFiles: 2);
      expect(summary, contains('violations: 8'));
      expect(summary, contains('## Violations by top-level path'));
      expect(summary, contains('fushi  4'));
      expect(summary, contains('## Top violation files'));
      expect(summary, contains('fushi/lib/src/main.dart  3'));
      expect(
        summary,
        isNot(contains('fushi/lib/src/main.dart:1:')),
        reason: 'summary 不应包含行级明细',
      );
    });
  });
}

Directory _makeFixtureRepo() {
  final Directory dir = Directory.systemTemp.createTempSync('fushi-scan-');
  _writeText(dir, 'LICENSE', 'Copyright (c) 2024 Fushi contributors\n');
  _writeText(
    dir,
    'fushi/lib/src/main.dart',
    '// Fushi entrypoint\n'
        "import 'package:fushi/i18n/strings.g.dart';\n"
        "final String name = 'Fushi';\n",
  );
  _writeText(
    dir,
    'fushi/lib/i18n/strings.i18n.json',
    '{"app_name": "Fushi"}\n',
  );
  _writeText(dir, 'third_party/pkg/NOTICE', 'Fushi third-party notice\n');
  _writeText(dir, 'docs/adr/0001.md', 'Fushi snapshot provenance\n');
  _writeText(dir, 'README.md', '# MyComic\nBased on Fushi v3.0.0\n');
  File('${dir.path}/logo.bin')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[0, 70, 117, 115, 104, 105]);
  File('${dir.path}/logo.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(<int>[70, 117, 115, 104, 105]);

  final ProcessResult init = Process.runSync('git', <String>[
    '-C',
    dir.path,
    'init',
  ]);
  if (init.exitCode != 0) fail('git init 失败：${init.stderr}');
  final ProcessResult add = Process.runSync('git', <String>[
    '-C',
    dir.path,
    'add',
    '-A',
  ]);
  if (add.exitCode != 0) fail('git add 失败：${add.stderr}');

  // 未跟踪文件不应被扫描。
  _writeText(dir, 'untracked.md', 'Fushi should not be scanned\n');
  return dir;
}

void _writeText(Directory root, String relativePath, String content) {
  final File file = File('${root.path}/$relativePath');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}
