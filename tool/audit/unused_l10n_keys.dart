// 未使用 l10n key 扫描器（只读开发者工具，不进入 app 运行时）。
//
// 用法（在仓库根目录运行）：
//   dart tool/audit/unused_l10n_keys.dart
//   dart tool/audit/unused_l10n_keys.dart --report .scratch/independence-cleanup/reports/unused-l10n-keys.txt
//   dart tool/audit/unused_l10n_keys.dart --json --report ...json
//
// key 集合来自 base `my_comic/lib/i18n/strings.i18n.json`；默认扫描
// `my_comic/lib`、`my_comic/test`、`my_comic/integration_test` 里的 `.dart`，并排除生成的
// `strings.g.dart`。只有报告，默认不因未使用 key 退出非零；清理完成后可用
// `--fail-if-unused` 转为门禁。
//
// 引用判定：在去掉注释后的源码里，把「成员访问」的标识符链当作引用候选：
//   t.reader_title / Translations.of(context).reader_title / t.a.b
// 字符串字面量里的 `.key` 也保守计为引用（避免误删），注释里的不算。
// 动态拼 key 的访问无法静态识别，用 allowlist（tool/audit/unused_l10n_allowlist.json）
// 记录；规则支持精确 key、前缀和正则。
library;

import 'dart:convert';
import 'dart:io';

/// 展开嵌套翻译 JSON，得到点路径 leaf key 集合。
Set<String> flattenTranslationKeys(Map<String, dynamic> json) {
  final Set<String> keys = <String>{};
  void walk(Map<String, dynamic> map, String prefix) {
    for (final MapEntry<String, dynamic> entry in map.entries) {
      final String full = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      final Object? value = entry.value;
      if (value is Map<String, dynamic>) {
        walk(value, full);
      } else if (value is Map) {
        walk(Map<String, dynamic>.from(value), full);
      } else {
        keys.add(full);
      }
    }
  }

  walk(json, '');
  return keys;
}

/// 功能前缀：嵌套 key 取第一个点段；扁平 key 取第一个下划线之前的部分。
String featurePrefix(String key) {
  final String firstSegment = key.contains('.')
      ? key.substring(0, key.indexOf('.'))
      : key;
  final int underscore = firstSegment.indexOf('_');
  return underscore < 0 ? firstSegment : firstSegment.substring(0, underscore);
}

final RegExp _identifierPattern = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');
final RegExp _identifierCharPattern = RegExp(r'[A-Za-z0-9_$]');

/// 在 Dart 源码里找出被引用的 l10n key。
///
/// 只认「成员访问」：`t.key`、`Translations.of(context).key`、`t.a.b`。
/// 先去掉注释（字符串里的 `//` 不算注释）；字符串内容保留，因此插值和字符串
/// 里的 `.key` 会保守地算作引用，宁可少报未使用，也不误删在用的 key。
Set<String> extractReferencedKeys(String source, Set<String> keys) {
  if (keys.isEmpty) return <String>{};
  final String code = _stripComments(source);
  final Set<String> referenced = <String>{};
  List<String> previousChain = <String>[];
  int previousEnd = 0;

  for (final RegExpMatch match in _identifierPattern.allMatches(code)) {
    final String token = match.group(0)!;
    final String gap = code.substring(previousEnd, match.start);
    final String trimmedGap = gap.trim();
    // 成员访问允许跨过调用/索引结束符：`Translations.of(context).key`。
    final bool memberAccess = trimmedGap.endsWith('.');
    final bool contiguous = trimmedGap == '.';
    final List<String> chain = contiguous
        ? <String>[...previousChain, token]
        : <String>[token];

    if (chain.length > 1) {
      // 去掉链头的接收者（`t`、`context.t` 等），只把后面的成员路径当 key。
      for (int i = 1; i < chain.length; i++) {
        final String suffix = chain.sublist(i).join('.');
        if (keys.contains(suffix)) referenced.add(suffix);
      }
    } else if (memberAccess && keys.contains(token)) {
      referenced.add(token);
    }

    previousChain = chain;
    previousEnd = match.end;
  }
  return referenced;
}

/// 去掉 Dart 注释；保留字符串内容与换行，避免影响后续标识符扫描。
String _stripComments(String source) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  int blockDepth = 0;
  String? stringQuote;
  bool rawString = false;
  bool triple = false;

  bool isIdentifierChar(String char) => _identifierCharPattern.hasMatch(char);

  String peek(int offset) =>
      i + offset < source.length ? source[i + offset] : '';

  while (i < source.length) {
    final String char = source[i];

    if (blockDepth > 0) {
      if (char == '/' && peek(1) == '*') {
        blockDepth += 1;
        out.write('  ');
        i += 2;
        continue;
      }
      if (char == '*' && peek(1) == '/') {
        blockDepth -= 1;
        out.write('  ');
        i += 2;
        continue;
      }
      out.write(char == '\n' ? '\n' : ' ');
      i += 1;
      continue;
    }

    if (stringQuote != null) {
      out.write(char);
      if (!rawString && char == '\\') {
        if (i + 1 < source.length) {
          out.write(source[i + 1]);
          i += 2;
          continue;
        }
      }
      if (triple) {
        if (char == stringQuote &&
            peek(1) == stringQuote &&
            peek(2) == stringQuote) {
          out.write('${peek(1)}${peek(2)}');
          i += 3;
          stringQuote = null;
          triple = false;
          rawString = false;
          continue;
        }
      } else if (char == stringQuote) {
        i += 1;
        stringQuote = null;
        rawString = false;
        continue;
      }
      i += 1;
      continue;
    }

    if (char == '/' && peek(1) == '/') {
      while (i < source.length && source[i] != '\n') {
        out.write(' ');
        i += 1;
      }
      continue;
    }
    if (char == '/' && peek(1) == '*') {
      blockDepth = 1;
      out.write('  ');
      i += 2;
      continue;
    }

    final bool rawPrefix =
        (char == 'r' || char == 'R') &&
        (i == 0 || !isIdentifierChar(source[i - 1])) &&
        (peek(1) == "'" || peek(1) == '"');
    if (rawPrefix) {
      out.write(char);
      i += 1;
      continue;
    }
    if (char == "'" || char == '"') {
      final bool startsTriple = peek(1) == char && peek(2) == char;
      triple = startsTriple;
      rawString =
          i > 0 &&
          (source[i - 1] == 'r' || source[i - 1] == 'R') &&
          (i < 2 || !isIdentifierChar(source[i - 2]));
      stringQuote = char;
      out.write(char);
      i += 1;
      if (startsTriple) {
        out.write('$char$char');
        i += 2;
      }
      continue;
    }

    out.write(char);
    i += 1;
  }
  return out.toString();
}

/// 动态访问 allowlist 的一条规则：精确 key、前缀或正则，三者恰好一个。
class DynamicKeyRule {
  DynamicKeyRule({this.key, this.prefix, this.pattern, required this.reason}) {
    final int conditions =
        (key == null ? 0 : 1) +
        (prefix == null ? 0 : 1) +
        (pattern == null ? 0 : 1);
    if (conditions != 1) {
      throw const FormatException(
        '动态 allowlist 规则必须且只能指定 key / prefix / pattern 之一',
      );
    }
  }

  factory DynamicKeyRule.fromJson(Map<String, dynamic> json) {
    final Object? key = json['key'];
    final Object? prefix = json['prefix'];
    final Object? pattern = json['pattern'];
    if (key != null && key is! String) {
      throw const FormatException('动态 allowlist key 必须是字符串');
    }
    if (prefix != null && prefix is! String) {
      throw const FormatException('动态 allowlist prefix 必须是字符串');
    }
    if (pattern != null && pattern is! String) {
      throw const FormatException('动态 allowlist pattern 必须是字符串');
    }
    final Object? reason = json['reason'];
    if (reason is! String || reason.isEmpty) {
      throw const FormatException('动态 allowlist 规则必须给出非空 reason');
    }
    return DynamicKeyRule(
      key: key as String?,
      prefix: prefix as String?,
      pattern: pattern == null ? null : RegExp(pattern as String),
      reason: reason,
    );
  }

  final String? key;
  final String? prefix;
  final RegExp? pattern;
  final String reason;

  bool matches(String candidate) {
    final String? exact = key;
    if (exact != null && candidate == exact) return true;
    final String? prefixValue = prefix;
    if (prefixValue != null && candidate.startsWith(prefixValue)) return true;
    final RegExp? regex = pattern;
    return regex != null && regex.hasMatch(candidate);
  }
}

/// 解析动态访问 allowlist：`{"rules": [{key|prefix|pattern, reason}]}`。
List<DynamicKeyRule> parseDynamicAllowlist(String jsonText) {
  final Object? decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('动态 allowlist 顶层必须是 JSON object');
  }
  final Object? rawRules = decoded['rules'];
  if (rawRules is! List) {
    throw const FormatException('动态 allowlist 缺少 rules 数组');
  }
  return <DynamicKeyRule>[
    for (final Object? raw in rawRules)
      if (raw is Map<String, dynamic>)
        DynamicKeyRule.fromJson(raw)
      else
        throw const FormatException('动态 allowlist 规则必须是 object'),
  ];
}

List<DynamicKeyRule> loadDynamicAllowlist(String path) =>
    parseDynamicAllowlist(File(path).readAsStringSync());

/// 一个 key 的使用情况。
class L10nKeyUsage {
  L10nKeyUsage({
    required this.key,
    required List<String> files,
    this.allowReason,
  }) : files = List<String>.unmodifiable(files);

  final String key;

  /// 引用该 key 的源文件（相对 app root，已排序）；空表示静态扫描未找到引用。
  final List<String> files;

  final String? allowReason;

  String get prefix => featurePrefix(key);
  bool get referenced => files.isNotEmpty;
  bool get allowlisted => allowReason != null;
  bool get unused => !referenced && !allowlisted;
}

/// 按功能前缀汇总。
class PrefixStats {
  const PrefixStats({
    required this.prefix,
    required this.total,
    required this.referenced,
    required this.unused,
    required this.allowlistedUnused,
  });

  final String prefix;
  final int total;
  final int referenced;
  final int unused;
  final int allowlistedUnused;
}

/// 一次未使用 key 扫描的结果。
class UnusedL10nReport {
  UnusedL10nReport({
    required this.baseFile,
    required this.scannedFileCount,
    required List<L10nKeyUsage> keys,
  }) : keys = List<L10nKeyUsage>.unmodifiable(keys);

  final String baseFile;
  final int scannedFileCount;
  final List<L10nKeyUsage> keys;

  int get totalKeys => keys.length;
  int get referencedCount =>
      keys.where((L10nKeyUsage usage) => usage.referenced).length;
  int get unusedCount =>
      keys.where((L10nKeyUsage usage) => usage.unused).length;
  int get allowlistedUnusedCount => keys
      .where((L10nKeyUsage usage) => usage.allowlisted && !usage.referenced)
      .length;

  List<PrefixStats> prefixStats() {
    final Map<String, List<L10nKeyUsage>> grouped =
        <String, List<L10nKeyUsage>>{};
    for (final L10nKeyUsage usage in keys) {
      grouped
          .putIfAbsent(featurePrefix(usage.key), () => <L10nKeyUsage>[])
          .add(usage);
    }
    final List<String> prefixes = grouped.keys.toList()..sort();
    return <PrefixStats>[
      for (final String prefix in prefixes)
        PrefixStats(
          prefix: prefix,
          total: grouped[prefix]!.length,
          referenced: grouped[prefix]!
              .where((L10nKeyUsage usage) => usage.referenced)
              .length,
          unused: grouped[prefix]!
              .where((L10nKeyUsage usage) => usage.unused)
              .length,
          allowlistedUnused: grouped[prefix]!
              .where(
                (L10nKeyUsage usage) => usage.allowlisted && !usage.referenced,
              )
              .length,
        ),
    ];
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'scanner': 'unused_l10n_keys',
      'base_file': baseFile,
      'scanned_files': scannedFileCount,
      'total_keys': totalKeys,
      'referenced_keys': referencedCount,
      'unused_keys': unusedCount,
      'allowlisted_unused_keys': allowlistedUnusedCount,
      'prefixes': <Map<String, dynamic>>[
        for (final PrefixStats stats in prefixStats())
          <String, dynamic>{
            'prefix': stats.prefix,
            'total': stats.total,
            'referenced': stats.referenced,
            'unused': stats.unused,
            'allowlisted_unused': stats.allowlistedUnused,
          },
      ],
      'keys': <Map<String, dynamic>>[
        for (final L10nKeyUsage usage in keys)
          <String, dynamic>{
            'key': usage.key,
            'prefix': featurePrefix(usage.key),
            'referenced': usage.referenced,
            'files': usage.files,
            'allowlisted': usage.allowlisted && !usage.referenced,
            'reason': usage.allowReason,
          },
      ],
    };
  }

  String _header(String title) =>
      '# $title\n'
      'base: $baseFile\n'
      'scanned files: $scannedFileCount\n'
      'keys: $totalKeys  referenced: $referencedCount  '
      'unused: $unusedCount  allowlisted_unused: $allowlistedUnusedCount\n';

  String _prefixTable() {
    final StringBuffer out = StringBuffer()
      ..writeln()
      ..writeln('## Prefixes')
      ..writeln('prefix  total  referenced  unused  allowlisted');
    for (final PrefixStats stats in prefixStats()) {
      out.writeln(
        '${stats.prefix}  ${stats.total}  ${stats.referenced}  '
        '${stats.unused}  ${stats.allowlistedUnused}',
      );
    }
    return out.toString();
  }

  String toText() {
    final StringBuffer out = StringBuffer()
      ..write(_header('Unused l10n keys'))
      ..write(_prefixTable());

    out
      ..writeln()
      ..writeln('## Unused keys (prefix  key)');
    for (final L10nKeyUsage usage in keys) {
      if (usage.unused)
        out.writeln('${featurePrefix(usage.key)}  ${usage.key}');
    }

    final List<L10nKeyUsage> allowlisted = keys
        .where((L10nKeyUsage usage) => usage.allowlisted && !usage.referenced)
        .toList();
    if (allowlisted.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## Allowlisted unused keys (prefix  key  reason)');
      for (final L10nKeyUsage usage in allowlisted) {
        out.writeln(
          '${featurePrefix(usage.key)}  ${usage.key}  ${usage.allowReason}',
        );
      }
    }
    return out.toString();
  }

  String toSummaryText({int topPrefixes = 30}) {
    final List<PrefixStats> stats = prefixStats().toList()
      ..sort((PrefixStats a, PrefixStats b) {
        final int byUnused = b.unused.compareTo(a.unused);
        return byUnused != 0 ? byUnused : a.prefix.compareTo(b.prefix);
      });
    final StringBuffer out = StringBuffer()
      ..write(_header('Unused l10n keys (summary)'))
      ..writeln()
      ..writeln('## Prefixes by unused keys (top $topPrefixes)')
      ..writeln('prefix  total  referenced  unused  allowlisted');
    for (final PrefixStats prefix in stats.take(topPrefixes)) {
      out.writeln(
        '${prefix.prefix}  ${prefix.total}  ${prefix.referenced}  '
        '${prefix.unused}  ${prefix.allowlistedUnused}',
      );
    }
    return out.toString();
  }
}

/// 扫描 [appRoot] 的 base JSON key 集合与源码引用。
UnusedL10nReport scanUnusedL10nKeys({
  required String appRoot,
  String baseFile = 'lib/i18n/strings.i18n.json',
  List<String> scanDirectories = const <String>[
    'lib',
    'test',
    'integration_test',
  ],
  List<DynamicKeyRule> allowRules = const <DynamicKeyRule>[],
  Set<String> excludedFileNames = const <String>{'strings.g.dart'},
}) {
  final File base = File('$appRoot/$baseFile');
  if (!base.existsSync()) {
    throw FileSystemException('找不到 base l10n 文件', base.path);
  }
  final Object? decoded = jsonDecode(base.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw FormatException('base l10n 文件顶层必须是 JSON object: ${base.path}');
  }
  final Set<String> keys = flattenTranslationKeys(decoded);

  final Map<String, Set<String>> references = <String, Set<String>>{
    for (final String key in keys) key: <String>{},
  };

  final List<String> sourcePaths = <String>[];
  for (final String directory in scanDirectories) {
    final Directory root = Directory('$appRoot/$directory');
    if (!root.existsSync()) continue;
    for (final FileSystemEntity entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String relative = _relativePath(appRoot, entity.path);
      final String basename = relative.split('/').last;
      if (excludedFileNames.contains(basename)) continue;
      sourcePaths.add(relative);
    }
  }
  sourcePaths.sort();

  for (final String relative in sourcePaths) {
    final String source = File('$appRoot/$relative').readAsStringSync();
    for (final String key in extractReferencedKeys(source, keys)) {
      references[key]!.add(relative);
    }
  }

  final List<L10nKeyUsage> usages = <L10nKeyUsage>[];
  for (final String key in keys.toList()..sort()) {
    final List<String> files = references[key]!.toList()..sort();
    String? allowReason;
    if (files.isEmpty) {
      for (final DynamicKeyRule rule in allowRules) {
        if (rule.matches(key)) {
          allowReason = rule.reason;
          break;
        }
      }
    }
    usages.add(L10nKeyUsage(key: key, files: files, allowReason: allowReason));
  }

  return UnusedL10nReport(
    baseFile: baseFile,
    scannedFileCount: sourcePaths.length,
    keys: usages,
  );
}

String _relativePath(String root, String path) {
  final String normalizedRoot = root.replaceAll('\\', '/');
  final String normalizedPath = path.replaceAll('\\', '/');
  final String prefix = normalizedRoot.endsWith('/')
      ? normalizedRoot
      : '$normalizedRoot/';
  return normalizedPath.startsWith(prefix)
      ? normalizedPath.substring(prefix.length)
      : normalizedPath;
}

const String _usage = '''
Usage: dart tool/audit/unused_l10n_keys.dart [options]

读取 base strings.i18n.json 的 key 集合，扫描 app 的 lib / test / integration_test
（排除生成的 strings.g.dart），报告未使用的 key、引用文件与功能前缀。
默认只报告；加 --fail-if-unused 时在存在未使用 key（不含 allowlist）时退出码为 1。

Options:
  --root <dir>        仓库根目录（默认取 git toplevel）
  --app <dir>         app 目录（默认 my_comic，相对仓库根）
  --base <file>       base JSON（默认 lib/i18n/strings.i18n.json，相对 app）
  --scan <dir>        扫描目录（相对 app，可重复；默认 lib test integration_test）
  --allowlist <file>  动态访问 allowlist JSON（默认脚本同目录的 unused_l10n_allowlist.json）
  --report <file>     把报告写入文件（默认只打印到 stdout）
  --json              以 JSON 输出（stdout 与 --report 文件）
  --summary           只输出汇总与前缀分布，不列出未使用 key
  --fail-if-unused    存在未使用 key 时退出码为 1
  -h, --help          显示本帮助
''';

void main(List<String> args) {
  String? root;
  String? app;
  String? base;
  String? allowlistPath;
  String? reportPath;
  final List<String> scanDirectories = <String>[];
  bool asJson = false;
  bool summaryOnly = false;
  bool failIfUnused = false;

  String takeValue(int index, String flag) {
    if (index + 1 >= args.length) {
      stderr.writeln('$flag 缺少参数');
      exitCode = 64;
      return '';
    }
    return args[index + 1];
  }

  for (int i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--root':
        root = takeValue(i, '--root');
        i += 1;
      case '--app':
        app = takeValue(i, '--app');
        i += 1;
      case '--base':
        base = takeValue(i, '--base');
        i += 1;
      case '--scan':
        scanDirectories.add(takeValue(i, '--scan'));
        i += 1;
      case '--allowlist':
        allowlistPath = takeValue(i, '--allowlist');
        i += 1;
      case '--report':
        reportPath = takeValue(i, '--report');
        i += 1;
      case '--json':
        asJson = true;
      case '--summary':
        summaryOnly = true;
      case '--fail-if-unused':
        failIfUnused = true;
      case '-h':
      case '--help':
        stdout.write(_usage);
        return;
      default:
        stderr
          ..writeln('未知参数: ${args[i]}')
          ..write(_usage);
        exitCode = 64;
        return;
    }
    if (exitCode != 0) return;
  }

  final String repoRoot = root ?? _defaultRepoRoot();
  final String resolvedApp = app ?? 'my_comic';
  final String appRoot = _isAbsolute(resolvedApp)
      ? resolvedApp
      : '$repoRoot/$resolvedApp';
  final String resolvedAllowlist =
      allowlistPath ??
      '${File(Platform.script.toFilePath()).parent.path}/'
          'unused_l10n_allowlist.json';
  if (!File(resolvedAllowlist).existsSync()) {
    stderr.writeln('找不到动态 allowlist: $resolvedAllowlist');
    exitCode = 66;
    return;
  }

  final UnusedL10nReport report = scanUnusedL10nKeys(
    appRoot: appRoot,
    baseFile: base ?? 'lib/i18n/strings.i18n.json',
    scanDirectories: scanDirectories.isEmpty
        ? const <String>['lib', 'test', 'integration_test']
        : scanDirectories,
    allowRules: loadDynamicAllowlist(resolvedAllowlist),
  );

  final String output = asJson
      ? const JsonEncoder.withIndent('  ').convert(report.toJson())
      : summaryOnly
      ? report.toSummaryText()
      : report.toText();
  stdout.write(output);
  if (!output.endsWith('\n')) stdout.writeln();

  if (reportPath != null) {
    final File file = File(reportPath);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(output.endsWith('\n') ? output : '$output\n');
  }

  if (failIfUnused && report.unusedCount > 0) {
    exitCode = 1;
  }
}

bool _isAbsolute(String path) =>
    path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

String _defaultRepoRoot() {
  final ProcessResult result = Process.runSync('git', <String>[
    'rev-parse',
    '--show-toplevel',
  ]);
  if (result.exitCode == 0) {
    final String top = (result.stdout as String).trim();
    if (top.isNotEmpty) return top;
  }
  return Directory.current.path;
}
