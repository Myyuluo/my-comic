/// Pure selection logic for `tool/pre_push_check.dart`: which local checks a set
/// of changed files needs so that what CI would turn red is caught before push.
///
/// Measured 2026-09-20..30 on upstream: of 36 PRs whose CI caught a regression
/// the PR itself introduced, 15 were red ONLY on source-scan guards and 3 more
/// on guards plus other tests; `flutter analyze` failed once in 10 days. Agents
/// ran analyze + hand-picked targeted tests, so the guards that scan the files
/// they touched (named by path literal in the guard) and the directory-scanning
/// guard batch never ran before push.
library;

/// 目录枚举型守卫（扫描整棵源码树，因此「改了 Dart 树就整批跑」）。
///
/// 上游把这份清单挂在 `docs/agent/fast-workflow.md` 的「### 清单」表格里；
/// 独立化清理删除了 `docs/agent/`，清单改为随工具一起入库，避免本地预检依赖
/// 一份已不存在的历史文档。条目仍按 `my_comic/test/` 相对路径记录，调用方只跑
/// 当前磁盘上真实存在的那些（[pre_push_check.dart] 用 testSources 过滤）。
const List<String> kEnumerationGuards = <String>[
  'test/database/package_schema_version_literal_guard_test.dart',
  'test/focus/focus_architecture_static_test.dart',
  'test/i18n/i18n_completeness_test.dart',
  'test/media/drag_drop/drag_drop_platform_guard_test.dart',
  'test/media/media_cover_write_guard_test.dart',
  'test/media/sources/book_history_split_guard_test.dart',
  'test/models/preference_keys_guard_test.dart',
  'test/pages/library_view_labels_unique_test.dart',
  'test/storage/path_rebase_coverage_guard_test.dart',
  'test/tools/book_format_discipline_guard_test.dart',
  'test/tools/dart_source_no_raw_nul_guard_test.dart',
  'test/tools/duplicate_policy_naming_guard_test.dart',
  'test/tools/image_picker_usage_guard_test.dart',
  'test/tools/integration_test_no_tester_tap_guard_test.dart',
  'test/tools/itest_focus_navigation_prerequisite_guard_test.dart',
  'test/tools/media_kind_persistence_guard_test.dart',
  'test/tools/my_comic_rename_guard_test.dart',
  'test/tools/outbound_http_discipline_guard_test.dart',
  'test/tools/outbound_user_agent_guard_test.dart',
  'test/tools/safe_file_name_guard_test.dart',
  'test/tools/source_guard_adoption_test.dart',
  'test/tools/tests_for_changes_guard_test.dart',
  'test/utils/net/network_image_proxy_guard_test.dart',
  'test/utils/share_entry_point_guard_test.dart',
  'test/webview/webview_render_process_gone_guard_test.dart',
  'test/widgets/horizontal_drag_scroll_guard_test.dart',
  'test/widgets/reorderable_scale_safety_guard_test.dart',
];

/// Whether [changed] touches a Dart source tree the enumeration guard batch
/// scans. When it does not (docs / workflows / native only), the batch is
/// skipped: the few batch guards whose scan root is outside the Dart trees name
/// that root by path literal, so tests_for_changes still selects them.
bool touchesDartTrees(Iterable<String> changed) => changed.any((String c) =>
    c.startsWith('my_comic/lib/') ||
    c.startsWith('my_comic/test/') ||
    c.startsWith('my_comic/integration_test/') ||
    RegExp(r'^packages/[^/]+/(lib|test)/').hasMatch(c));

/// Budget mode (the default) for path-literal matching: [changed] triggers
/// [ref] only when [ref] IS that file, or a directory with at most
/// [maxDirFiles] files that contains it. tests_for_changes' wide rule also
/// fires on same-directory siblings and on directories of any size -- right for
/// "which guards could care", far too wide to run locally: replaying 36
/// regression PRs, a typical PR selected 600-1500 test files that way (3 files
/// changed under pages/implementations selected 782). Large trees are what the
/// enumeration batch already scans.
bool budgetTrigger(
  String changed,
  String ref, {
  required bool Function(String) isDirectory,
  required int Function(String) dirFileCount,
  int maxDirFiles = 60,
}) {
  if (changed == ref) return true;
  if (!changed.startsWith('$ref/') || !isDirectory(ref)) return false;
  return dirFileCount(ref) <= maxDirFiles;
}

/// Splits [keys] into libraries imported by at most [hubLimit] of the tests in
/// [testSources] and "hubs" imported by more (app_model.dart,
/// preference_keys.dart, generated i18n ...). A hub change touches most of the
/// suite; locally it only keeps same-name tests and the guards, the sharded CI
/// suite covers the rest -- and the tool says so.
({Set<String> kept, Set<String> hubs}) splitHubImportKeys(
  Set<String> keys,
  Map<String, String> testSources, {
  int hubLimit = 40,
}) {
  final Set<String> kept = <String>{};
  final Set<String> hubs = <String>{};
  for (final String k in keys) {
    int importers = 0;
    for (final String src in testSources.values) {
      if (src.contains("'$k'") || src.contains('"$k"')) importers++;
      if (importers > hubLimit) break;
    }
    (importers > hubLimit ? hubs : kept).add(k);
  }
  return (kept: kept, hubs: hubs);
}

/// Packages whose tests CI never runs from the package loop (vendored / forks /
/// stubs, and my_comic_torrent which needs a real DLL). Mirrors main.yml's `skip`.
const Set<String> kCiSkippedPackages = <String>{
  'flutter_inappwebview_windows',
  'gamepads_windows',
  'my_comic_torrent',
};

/// Pure-Dart packages that CI also `dart analyze`s on their own
/// (server-gate.yml); `flutter analyze` in my_comic/ does not cover them.
const Set<String> kSeparatelyAnalyzedPackages = <String>{
  'my_comic_engine',
  'my_comic_server',
};

/// `package:` URIs that import the library a changed file belongs to.
///
/// [packageNames] maps a `packages/<dir>` directory to its pubspec name.
/// [partOwner] is the `part of '<uri>'` target of the changed file when it is a
/// part (read by the caller; null for libraries or deleted files): a part is
/// never imported itself, its owning library is.
Set<String> importKeysForChange(
  String repoPath, {
  required Map<String, String> packageNames,
  String? partOwner,
}) {
  String libraryPath = repoPath;
  if (partOwner != null) {
    final int slash = repoPath.lastIndexOf('/');
    libraryPath = _normalize('${repoPath.substring(0, slash)}/$partOwner');
  }
  if (!libraryPath.endsWith('.dart')) return <String>{};
  final List<String> seg = libraryPath.split('/');
  if (seg.length > 2 && seg[0] == 'my_comic' && seg[1] == 'lib') {
    return <String>{'package:my_comic/${seg.sublist(2).join('/')}'};
  }
  if (seg.length > 3 && seg[0] == 'packages' && seg[2] == 'lib') {
    final String? name = packageNames[seg[1]];
    if (name == null) return <String>{};
    return <String>{'package:$name/${seg.sublist(3).join('/')}'};
  }
  return <String>{};
}

String _normalize(String path) {
  final List<String> out = <String>[];
  for (final String s in path.split('/')) {
    if (s == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else if (s.isNotEmpty && s != '.') {
      out.add(s);
    }
  }
  return out.join('/');
}

/// `part of '<uri>';` target in [source], or null.
String? partOfTarget(String source) {
  final Match? m = RegExp(r'''^part of ['"]([^'"]+)['"];''', multiLine: true)
      .firstMatch(source);
  return m?.group(1);
}

/// App tests (repo-root relative, under my_comic/test/) affected through Dart
/// imports by [changed]:
/// * a changed `_test.dart` file itself;
/// * tests that import a changed library by its `package:` URI ([importKeys]);
/// * tests that import a changed non-test helper under my_comic/test/ (matched by
///   `/<basename>'` in an import, over-selecting on name clashes on purpose);
/// * `<name>_test.dart` for a changed `<name>.dart`.
/// Barrel re-exports are deliberately NOT followed (they would select most of
/// the suite); the full sharded suite on CI stays the backstop for those.
Set<String> directImpactTests({
  required Iterable<String> changed,
  required Map<String, String> testSources,
  required Set<String> importKeys,
}) {
  final Set<String> out = <String>{};
  final Set<String> helperNames = <String>{};
  final Set<String> sameNameTests = <String>{};
  for (final String c in changed) {
    if (c.startsWith('my_comic/test/') && c.endsWith('_test.dart')) {
      if (testSources.containsKey(c)) out.add(c);
      continue;
    }
    final String base = c.split('/').last;
    if (c.startsWith('my_comic/test/') && base.endsWith('.dart')) {
      helperNames.add(base);
    }
    if (base.endsWith('.dart')) {
      sameNameTests.add('${base.substring(0, base.length - 5)}_test.dart');
    }
  }
  for (final MapEntry<String, String> t in testSources.entries) {
    final String src = t.value;
    if (sameNameTests.contains(t.key.split('/').last) ||
        importKeys
            .any((String k) => src.contains("'$k'") || src.contains('"$k"')) ||
        helperNames
            .any((String h) => src.contains("/$h'") || src.contains("'$h'"))) {
      out.add(t.key);
    }
  }
  return out;
}

/// Packages under packages/ touched by [changed] whose tests CI runs.
Set<String> changedTestablePackages(Iterable<String> changed) => <String>{
      for (final String c in changed)
        if (c.startsWith('packages/') && c.split('/').length > 2)
          c.split('/')[1],
    }..removeAll(kCiSkippedPackages);

/// Whether the JS behaviour suites CI runs in the build job are affected.
bool touchesJsSuites(Iterable<String> changed) => changed.any((String c) =>
    c.startsWith('test/js/') ||
    c.startsWith('tools/browser-extension/') ||
    c.startsWith('my_comic/assets/') ||
    c.endsWith('.js') ||
    c.endsWith('.mjs'));

/// Splits test paths into batches whose joined length stays under [maxChars]:
/// `flutter.bat` goes through cmd.exe on Windows (8191-char command line; the
/// rest of the flutter test invocation fits in the remaining ~690 chars).
/// [maxFiles] > 0 also caps each batch's file count, so a long selection is run
/// as several `flutter test` calls with the machine gate re-checked in between.
List<List<String>> chunkByCommandLength(List<String> paths,
    {int maxChars = 7500, int maxFiles = 0}) {
  final List<List<String>> batches = <List<String>>[];
  List<String> cur = <String>[];
  int len = 0;
  for (final String p in paths) {
    final bool full = maxFiles > 0 && cur.length >= maxFiles;
    if (cur.isNotEmpty && (full || len + p.length + 1 > maxChars)) {
      batches.add(cur);
      cur = <String>[];
      len = 0;
    }
    cur.add(p);
    len += p.length + 1;
  }
  if (cur.isNotEmpty) batches.add(cur);
  return batches;
}

/// Every descendant of [root] in a `(pid, parent pid)` table, deepest first,
/// [root] itself excluded: what has to go when a run is cut off, so that no
/// flutter_tester / frontend_server outlives the tool as an orphan.
List<int> descendantPids(int root, Iterable<(int, int)> table) {
  final Map<int, List<int>> children = <int, List<int>>{};
  for (final (int pid, int parent) in table) {
    if (pid == parent) continue;
    children.putIfAbsent(parent, () => <int>[]).add(pid);
  }
  final List<int> out = <int>[];
  // Reused pids can make the table cyclic: mark before descending.
  final Set<int> seen = <int>{root};
  void walk(int pid) {
    for (final int child in children[pid] ?? const <int>[]) {
      if (!seen.add(child)) continue;
      walk(child);
      out.add(child);
    }
  }

  walk(root);
  return out;
}
