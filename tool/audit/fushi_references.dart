// Fushi 引用扫描器（只读开发者工具，不进入 app 运行时）。
//
// 用法（在仓库根目录运行）：
//   dart tool/audit/fushi_references.dart
//   dart tool/audit/fushi_references.dart --report .scratch/independence-cleanup/reports/fushi-references.txt
//   dart tool/audit/fushi_references.dart --json --report ...json
//   dart tool/audit/fushi_references.dart --fail-on-violations
//
// 只扫描 `git ls-files` 列出的受版本控制文件；git 历史本身不在扫描范围内，
// 因为历史是允许保留的 Fushi 来源记录。allowlist 规则见
// `tool/audit/fushi_references_allowlist.json`：
//   - {"path": <glob>}：放行该文件的所有命中；
//   - {"path": <glob>, "line_pattern": <regex>}：只放行匹配该正则的行。
// 被放行的命中仍出现在报告里（标为 allowed），只有 allowlist 之外的命中才算
// violation。
library;

import 'dart:convert';
import 'dart:io';

/// 命中分类；字符串值直接进入报告。
enum FushiReferenceCategory {
  userVisibleCopy('user_visible_copy'),
  code('code'),
  docs('docs'),
  license('license'),
  thirdParty('third_party'),
  historicalDocs('historical_docs');

  const FushiReferenceCategory(this.reportName);

  final String reportName;
}

const Set<String> _docExtensions = <String>{'.md', '.txt', '.rst', '.adoc'};

const Set<String> _docBasenames = <String>{
  'README',
  'CHANGELOG',
  'AUTHORS',
  'CONTRIBUTING',
  'CODE_OF_CONDUCT',
  'TESTOWNERS',
};

/// 按路径与命中所在行判断这条引用属于哪一类。
FushiReferenceCategory categorizeReference({
  required String path,
  required String line,
  required int matchStart,
}) {
  final String normalized = path.replaceAll('\\', '/');
  final List<String> segments = normalized.split('/');
  final String basename = segments.last;
  final String upperBasename = basename.toUpperCase();

  if (upperBasename == 'LICENSE' ||
      upperBasename == 'LICENSE.MD' ||
      upperBasename == 'COPYING' ||
      upperBasename == 'COPYRIGHT' ||
      normalized.startsWith('licenses/')) {
    return FushiReferenceCategory.license;
  }
  if (normalized.startsWith('third_party/') ||
      normalized.contains('/third_party/') ||
      normalized.startsWith('ci/patches/') ||
      upperBasename.startsWith('NOTICE') ||
      basename == 'PATCHES.md') {
    return FushiReferenceCategory.thirdParty;
  }
  if (basename == 'UPSTREAM.md' ||
      normalized.startsWith('docs/adr/') ||
      normalized.startsWith('docs/bugs/') ||
      normalized.startsWith('docs/readme/') ||
      normalized.startsWith('docs/agent/') ||
      normalized.startsWith('my_comic/docs/') ||
      normalized.startsWith('.scratch/')) {
    return FushiReferenceCategory.historicalDocs;
  }
  if (normalized.endsWith('.i18n.json')) {
    return FushiReferenceCategory.userVisibleCopy;
  }
  final int dot = basename.lastIndexOf('.');
  final String extension = dot < 0 ? '' : basename.substring(dot).toLowerCase();
  if (_docExtensions.contains(extension) ||
      _docBasenames.contains(basename.toUpperCase())) {
    return FushiReferenceCategory.docs;
  }
  if (_startsComment(line)) return FushiReferenceCategory.docs;
  if (_isDirectiveLine(line)) return FushiReferenceCategory.code;
  if (_isInsideStringLiteral(line, matchStart)) {
    return FushiReferenceCategory.userVisibleCopy;
  }
  return FushiReferenceCategory.code;
}

/// import/export/part 里的 `package:fushi` 是代码依赖，不是用户可见文案。
bool _isDirectiveLine(String line) {
  final String trimmed = line.trimLeft();
  return trimmed.startsWith('import ') ||
      trimmed.startsWith('export ') ||
      trimmed.startsWith('part ');
}

bool _startsComment(String line) {
  final String trimmed = line.trimLeft();
  return trimmed.startsWith('//') ||
      trimmed.startsWith('/*') ||
      trimmed.startsWith('*') ||
      trimmed.startsWith('#') ||
      trimmed.startsWith('<!--') ||
      trimmed.startsWith('--') ||
      trimmed.startsWith(';');
}

/// 判断 [index] 是否落在所在行的单/双引号字符串里（忽略转义）。
bool _isInsideStringLiteral(String line, int index) {
  bool inSingle = false;
  bool inDouble = false;
  for (int i = 0; i < index && i < line.length; i++) {
    final String char = line[i];
    if (char == '\\' && (inSingle || inDouble)) {
      i += 1;
      continue;
    }
    if (!inDouble && char == "'") {
      inSingle = !inSingle;
    } else if (!inSingle && char == '"') {
      inDouble = !inDouble;
    }
  }
  return inSingle || inDouble;
}

/// 一条 allowlist 规则。
class AllowRule {
  AllowRule({required this.pathGlob, this.linePattern, required this.reason});

  /// 相对仓库根的路径 glob（支持 `*`、`**`、`?`，按 `/` 分隔）。
  final String pathGlob;

  /// 匹配到这里的行才放行；为 null 时放行整个文件。
  final RegExp? linePattern;

  /// 为什么允许；写进报告方便审计。
  final String reason;

  bool matches(String path, String line) {
    if (!pathMatchesGlob(path, pathGlob)) return false;
    final RegExp? pattern = linePattern;
    return pattern == null || pattern.hasMatch(line);
  }
}

/// `*` 不跨目录、`**` 跨目录、`?` 匹配单个非 `/` 字符；反斜杠按 `/` 处理。
bool pathMatchesGlob(String path, String glob) {
  final String normalizedPath = path.replaceAll('\\', '/');
  final String normalizedGlob = glob.replaceAll('\\', '/');
  return RegExp('^${_globToRegExp(normalizedGlob)}\$').hasMatch(normalizedPath);
}

String _globToRegExp(String glob) {
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < glob.length; i++) {
    final String char = glob[i];
    if (char == '*') {
      final bool doubleStar = i + 1 < glob.length && glob[i + 1] == '*';
      if (!doubleStar) {
        out.write('[^/]*');
        continue;
      }
      if (i + 2 < glob.length && glob[i + 2] == '/') {
        // `**/` 匹配零层或多层目录。
        out.write('(?:.*/)?');
        i += 2;
      } else {
        out.write('.*');
        i += 1;
      }
    } else if (char == '?') {
      out.write('[^/]');
    } else {
      out.write(RegExp.escape(char));
    }
  }
  return out.toString();
}

/// 解析 allowlist JSON。结构：`{"rules": [{path, line_pattern?, reason}]}`。
List<AllowRule> parseAllowlist(String jsonText) {
  final Object? decoded = jsonDecode(jsonText);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('allowlist 顶层必须是 JSON object');
  }
  final Object? rawRules = decoded['rules'];
  if (rawRules is! List) {
    throw const FormatException('allowlist 缺少 rules 数组');
  }
  final List<AllowRule> rules = <AllowRule>[];
  for (final Object? raw in rawRules) {
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('allowlist rules 的每一项必须是 object');
    }
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) {
      throw const FormatException('allowlist 规则缺少非空 path');
    }
    final Object? linePattern = raw['line_pattern'];
    if (linePattern != null && linePattern is! String) {
      throw const FormatException('allowlist line_pattern 必须是字符串');
    }
    final Object? reason = raw['reason'];
    rules.add(
      AllowRule(
        pathGlob: path,
        linePattern: linePattern == null ? null : RegExp(linePattern as String),
        reason: reason is String ? reason : '',
      ),
    );
  }
  return rules;
}

/// 从文件读取 allowlist。
List<AllowRule> loadAllowlist(String path) =>
    parseAllowlist(File(path).readAsStringSync());

/// 一行命中。
class FushiReferenceHit {
  const FushiReferenceHit({
    required this.path,
    required this.lineNumber,
    required this.line,
    required this.category,
    this.allowReason,
  });

  /// 相对仓库根的路径，统一用 `/`。
  final String path;
  final int lineNumber;
  final String line;
  final FushiReferenceCategory category;

  /// 非 null 表示被 allowlist 放行。
  final String? allowReason;

  bool get allowed => allowReason != null;
}

/// 一次扫描的结果。
class FushiReferenceReport {
  FushiReferenceReport({
    required List<FushiReferenceHit> hits,
    required this.scannedFileCount,
  }) : hits = List<FushiReferenceHit>.unmodifiable(hits);

  final List<FushiReferenceHit> hits;
  final int scannedFileCount;

  int get totalHits => hits.length;
  int get allowedHitCount =>
      hits.where((FushiReferenceHit h) => h.allowed).length;
  int get violationCount => totalHits - allowedHitCount;
  Iterable<FushiReferenceHit> get violations =>
      hits.where((FushiReferenceHit h) => !h.allowed);

  /// 按分类统计；[violationsOnly] 为 true 时只统计 allowlist 之外的命中。
  Map<String, int> categoryCounts({bool violationsOnly = false}) {
    final Map<String, int> counts = <String, int>{};
    for (final FushiReferenceCategory category
        in FushiReferenceCategory.values) {
      final int count = hits
          .where(
            (FushiReferenceHit h) =>
                h.category == category && (!violationsOnly || !h.allowed),
          )
          .length;
      if (count > 0) counts[category.reportName] = count;
    }
    return counts;
  }

  Map<String, dynamic> toJson() {
    final Map<String, List<FushiReferenceHit>> byFile =
        <String, List<FushiReferenceHit>>{};
    for (final FushiReferenceHit hit in hits) {
      byFile.putIfAbsent(hit.path, () => <FushiReferenceHit>[]).add(hit);
    }
    final List<String> paths = byFile.keys.toList()..sort();
    return <String, dynamic>{
      'scanner': 'fushi_references',
      'scanned_files': scannedFileCount,
      'total_hits': totalHits,
      'allowed_hits': allowedHitCount,
      'violations': violationCount,
      'category_counts': categoryCounts(),
      'violation_category_counts': categoryCounts(violationsOnly: true),
      'files': <Map<String, dynamic>>[
        for (final String path in paths)
          <String, dynamic>{
            'path': path,
            'hits': byFile[path]!.length,
            'violations': byFile[path]!
                .where((FushiReferenceHit h) => !h.allowed)
                .length,
            'categories': <String, int>{
              for (final FushiReferenceCategory category
                  in FushiReferenceCategory.values)
                if (byFile[path]!.any(
                  (FushiReferenceHit h) => h.category == category,
                ))
                  category.reportName: byFile[path]!
                      .where((FushiReferenceHit h) => h.category == category)
                      .length,
            },
            'lines': <Map<String, dynamic>>[
              for (final FushiReferenceHit hit in byFile[path]!)
                <String, dynamic>{
                  'line': hit.lineNumber,
                  'category': hit.category.reportName,
                  'allowed': hit.allowed,
                  'reason': hit.allowReason,
                  'text': hit.line,
                },
            ],
          },
      ],
    };
  }

  String toText() {
    final StringBuffer out = StringBuffer()
      ..writeln('# Fushi reference scan')
      ..writeln('tracked files scanned: $scannedFileCount')
      ..writeln(
        'hits: $totalHits  allowed: $allowedHitCount  '
        'violations: $violationCount',
      );

    final Map<String, int> allCounts = categoryCounts();
    final Map<String, int> violationCounts = categoryCounts(
      violationsOnly: true,
    );
    if (allCounts.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## Categories')
        ..writeln('category  all  violations');
      for (final FushiReferenceCategory category
          in FushiReferenceCategory.values) {
        final String name = category.reportName;
        if (!allCounts.containsKey(name)) continue;
        out.writeln('$name  ${allCounts[name]}  ${violationCounts[name] ?? 0}');
      }
    }

    if (violationCount > 0) {
      out
        ..writeln()
        ..writeln('## Violations (file:line)');
      for (final FushiReferenceHit hit in violations) {
        out.writeln(
          '${hit.path}:${hit.lineNumber}: '
          '[${hit.category.reportName}] ${hit.line.trim()}',
        );
      }
    }

    final Map<String, int> allowedByFile = <String, int>{};
    for (final FushiReferenceHit hit in hits) {
      if (hit.allowed) {
        allowedByFile[hit.path] = (allowedByFile[hit.path] ?? 0) + 1;
      }
    }
    if (allowedByFile.isNotEmpty) {
      out
        ..writeln()
        ..writeln('## Allowlisted (file: count)');
      final List<String> paths = allowedByFile.keys.toList()..sort();
      for (final String path in paths) {
        out.writeln('$path: ${allowedByFile[path]}');
      }
    }
    return out.toString();
  }

  /// 汇总版报告：分类统计、按顶层目录的违规分布、文件排名，不含行级明细。
  String toSummaryText({int topFiles = 40}) {
    final List<FushiReferenceHit> violationsList = violations.toList();
    final Map<String, int> byTopLevel = <String, int>{};
    final Map<String, int> byFile = <String, int>{};
    for (final FushiReferenceHit hit in violationsList) {
      final String topLevel = hit.path.split('/').first;
      byTopLevel[topLevel] = (byTopLevel[topLevel] ?? 0) + 1;
      byFile[hit.path] = (byFile[hit.path] ?? 0) + 1;
    }
    final List<MapEntry<String, int>> sortedTopLevel =
        byTopLevel.entries.toList()
          ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
            final int byCount = b.value.compareTo(a.value);
            return byCount != 0 ? byCount : a.key.compareTo(b.key);
          });
    final List<MapEntry<String, int>> sortedFiles = byFile.entries.toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
        final int byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });

    final StringBuffer out = StringBuffer()
      ..writeln('# Fushi reference scan (summary)')
      ..writeln('tracked files scanned: $scannedFileCount')
      ..writeln(
        'hits: $totalHits  allowed: $allowedHitCount  '
        'violations: $violationCount',
      );

    final Map<String, int> allCounts = categoryCounts();
    final Map<String, int> violationCounts = categoryCounts(
      violationsOnly: true,
    );
    out
      ..writeln()
      ..writeln('## Categories')
      ..writeln('category  all  violations');
    for (final FushiReferenceCategory category
        in FushiReferenceCategory.values) {
      final String name = category.reportName;
      if (!allCounts.containsKey(name)) continue;
      out.writeln('$name  ${allCounts[name]}  ${violationCounts[name] ?? 0}');
    }

    out
      ..writeln()
      ..writeln('## Violations by top-level path')
      ..writeln('path  violations');
    for (final MapEntry<String, int> entry in sortedTopLevel) {
      out.writeln('${entry.key}  ${entry.value}');
    }

    out
      ..writeln()
      ..writeln(
        '## Top violation files (top $topFiles of ${sortedFiles.length})',
      )
      ..writeln('path  violations');
    for (final MapEntry<String, int> entry in sortedFiles.take(topFiles)) {
      out.writeln('${entry.key}  ${entry.value}');
    }
    return out.toString();
  }
}

/// 常见二进制扩展名：直接跳过，不读内容。
const Set<String> _binaryExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.ico',
  '.webp',
  '.bmp',
  '.tif',
  '.tiff',
  '.ttf',
  '.otf',
  '.woff',
  '.woff2',
  '.dll',
  '.exe',
  '.so',
  '.dylib',
  '.a',
  '.lib',
  '.jar',
  '.apk',
  '.zip',
  '.gz',
  '.tgz',
  '.bz2',
  '.xz',
  '.7z',
  '.onnx',
  '.pyc',
  '.class',
  '.pdf',
  '.mp3',
  '.mp4',
  '.wav',
  '.flac',
  '.ogg',
  '.webm',
  '.avi',
  '.mkv',
};

/// 列出 [repoRoot] 下受版本控制的文件（相对路径，`/` 分隔，已排序）。
List<String> listTrackedFiles(String repoRoot) {
  final ProcessResult result = Process.runSync('git', <String>[
    '-C',
    repoRoot,
    'ls-files',
    '-z',
  ]);
  if (result.exitCode != 0) {
    throw ProcessException(
      'git',
      <String>['-C', repoRoot, 'ls-files', '-z'],
      '${result.stderr}',
      result.exitCode,
    );
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((String path) => path.isNotEmpty)
      .map((String path) => path.replaceAll('\\', '/'))
      .toList()
    ..sort();
}

/// 扫描 [repoRoot] 里所有受版本控制的文本文件。
///
/// 只读：不写文件、不改 git index；[allowRules] 之外的命中计入 violation。
FushiReferenceReport scanFushiReferences({
  required String repoRoot,
  required List<AllowRule> allowRules,
  String needle = 'fushi',
}) {
  final String lowerNeedle = needle.toLowerCase();
  final List<FushiReferenceHit> hits = <FushiReferenceHit>[];
  int scannedFiles = 0;

  for (final String path in listTrackedFiles(repoRoot)) {
    final int dot = path.lastIndexOf('.');
    final String extension = dot < 0 ? '' : path.substring(dot).toLowerCase();
    if (_binaryExtensions.contains(extension)) continue;

    final File file = File('$repoRoot/$path');
    List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      continue;
    }
    if (bytes.take(8000).contains(0)) continue;

    final String content;
    try {
      content = utf8.decode(bytes, allowMalformed: true);
    } on FormatException {
      continue;
    }
    scannedFiles += 1;

    final List<String> lines = content.split('\n');
    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i].endsWith('\r')
          ? lines[i].substring(0, lines[i].length - 1)
          : lines[i];
      final int matchStart = line.toLowerCase().indexOf(lowerNeedle);
      if (matchStart < 0) continue;

      String? allowReason;
      for (final AllowRule rule in allowRules) {
        if (rule.matches(path, line)) {
          allowReason = rule.reason;
          break;
        }
      }
      hits.add(
        FushiReferenceHit(
          path: path,
          lineNumber: i + 1,
          line: line,
          category: categorizeReference(
            path: path,
            line: line,
            matchStart: matchStart,
          ),
          allowReason: allowReason,
        ),
      );
    }
  }

  return FushiReferenceReport(hits: hits, scannedFileCount: scannedFiles);
}

const String _usage = '''
Usage: dart tool/audit/fushi_references.dart [options]

只读扫描受版本控制文件中的 Fushi 引用，按类别汇总并输出文件/行级报告。
默认只生成报告；加 --fail-on-violations 时在 allowlist 之外有命中才以 1 退出。

Options:
  --root <dir>            仓库根目录（默认取 git toplevel）
  --allowlist <file>      allowlist JSON（默认脚本同目录的 fushi_references_allowlist.json）
  --report <file>         把报告写入文件（默认只打印到 stdout）
  --json                  以 JSON 输出（stdout 与 --report 文件）
  --summary               只输出汇总（分类、目录分布、文件排名），不含行级明细
  --fail-on-violations    有 allowlist 之外的命中时退出码为 1
  -h, --help              显示本帮助
''';

void main(List<String> args) {
  String? root;
  String? allowlistPath;
  String? reportPath;
  bool asJson = false;
  bool summaryOnly = false;
  bool failOnViolations = false;

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
      case '--fail-on-violations':
        failOnViolations = true;
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
  final String resolvedAllowlist =
      allowlistPath ??
      '${File(Platform.script.toFilePath()).parent.path}/'
          'fushi_references_allowlist.json';
  if (!File(resolvedAllowlist).existsSync()) {
    stderr.writeln('找不到 allowlist: $resolvedAllowlist');
    exitCode = 66;
    return;
  }

  final FushiReferenceReport report = scanFushiReferences(
    repoRoot: repoRoot,
    allowRules: loadAllowlist(resolvedAllowlist),
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

  if (failOnViolations && report.violationCount > 0) {
    exitCode = 1;
  }
}

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
