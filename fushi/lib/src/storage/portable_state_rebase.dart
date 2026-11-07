import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/profile/profile_keys.dart' show ProfileKeys;
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/path_rebase_coverage.dart'
    show PathRebasePref, PathValueShape, kPathRebasePrefs;
import 'package:fushi/src/sync/backup_service.dart'
    show rebaseFontCatalogJson, rebaseFontListJson;

/// Ticket 02：Portable state 的启动期路径 rebase。
///
/// 便携拷贝 = 程序目录 + `userdata`，Content root 不随包走。跨 Windows 用户 /
/// 跨机器启动后，库里的绝对路径会全部悬空：
///
///  - Content root 旧默认 `...\Documents\MyComic` → 当前用户默认 `Documents\MyComic`。
///    只在旧根是**默认根形状**且当前也用默认根时自动改写；用户切到自定义 Content
///    root 时不改写（旧下载显示 Missing，由 Rebuild download index 恢复）。
///  - Program state root 随程序目录换了位置 → `state/custom_fonts/...` 的字体绝对
///    路径要跟着改；否则字体设置还指着旧安装目录。
///
/// 台账 `portable_last_content_root` / `portable_last_state_root` 存在 DB 的
/// `preferences` 表：它描述的就是这个库里的路径，必须与库同生共死（与
/// `SandboxRelocation` 同款理由——库被拷到另一台机器时台账也一起被拷走）。
/// 没有台账时（本功能上线前就已拷走的库）从存量路径反推默认根形状，只有能明确
/// 认定一个旧根才改写，不猜。
///
/// 失败不阻塞启动：调用方记录并继续，下次启动再试。自定义 Content root 不可达
/// 仍由 [AppPaths.resolve] 抛 `DataRootUnavailableException` 走逃生屏——本类不碰
/// 那个判定。
class PortableStateRebase {
  PortableStateRebase._();

  /// 上次启动实际使用的 Content root 绝对路径。
  static const String lastContentRootPrefKey = 'portable_last_content_root';

  /// 上次启动实际使用的 Program state root 中 `state/` 的绝对路径。
  static const String lastStateRootPrefKey = 'portable_last_state_root';

  /// 仅供测试：让 reconcile 在第一次读库前失败，验证失败路径不阻塞启动。
  @visibleForTesting
  static bool debugFailBeforeRebase = false;

  /// 启动期对账并改写库内路径。任何异常都收进 [PortableStateRebaseOutcome.error]，
  /// 不向上抛（启动不能因为自愈失败进不去）。
  static Future<PortableStateRebaseOutcome> reconcile({
    required FushiDatabase db,
    required AppPaths paths,
    String? staleContentRoot,
  }) async {
    try {
      if (debugFailBeforeRebase) {
        throw StateError('debugFailBeforeRebase');
      }
      final List<EpubBookRow> books = await db.getAllEpubBooks();
      final Map<String, String> prefs = await db.getAllPrefs();

      final String? oldContentRoot = _resolveOldContentRoot(
        paths: paths,
        staleContentRoot: staleContentRoot,
        ledgerContentRoot: prefs[lastContentRootPrefKey],
        books: books,
      );
      final String? oldStateRoot = _resolveOldStateRoot(
        paths: paths,
        ledgerStateRoot: prefs[lastStateRootPrefKey],
        prefs: prefs,
      );

      int booksRebased = 0;
      int historyRebased = 0;
      int fontPrefsRebased = 0;

      if (oldContentRoot != null) {
        booksRebased = await _rebaseBookPaths(
          db,
          books: books,
          oldRoot: oldContentRoot,
          newRoot: paths.contentRoot.path,
        );
        historyRebased = await _rebaseMediaOpenHistory(
          db,
          oldRoot: oldContentRoot,
          newRoot: paths.contentRoot.path,
        );
      }
      if (oldStateRoot != null) {
        fontPrefsRebased = await _rebaseFontPrefs(
          db,
          oldRoot: oldStateRoot,
          newRoot: paths.stateRoot.path,
        );
      }

      await db.setPref(lastContentRootPrefKey, paths.contentRoot.path);
      await db.setPref(lastStateRootPrefKey, paths.stateRoot.path);
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');

      return PortableStateRebaseOutcome(
        booksRebased: booksRebased,
        historyRebased: historyRebased,
        fontPrefsRebased: fontPrefsRebased,
        oldContentRoot: oldContentRoot,
        oldStateRoot: oldStateRoot,
      );
    } on Object catch (error) {
      return PortableStateRebaseOutcome.failed(error);
    }
  }

  // ── 旧根判定 ────────────────────────────────────────────────────────

  /// 旧 Content root：显式检测到的旧用户默认根优先；其次台账；最后从存量书路径
  /// 反推。只有「当前也用默认根」且「旧根是默认根形状」才返回，避免把用户切到
  /// 自定义根的动作变成自动搬路径。
  static String? _resolveOldContentRoot({
    required AppPaths paths,
    required String? staleContentRoot,
    required String? ledgerContentRoot,
    required List<EpubBookRow> books,
  }) {
    final String current = paths.contentRoot.path;
    final String? stale = _nonEmpty(staleContentRoot);
    if (stale != null && !_samePath(stale, current)) return stale;

    final String? ledger = _nonEmpty(ledgerContentRoot);
    if (ledger != null &&
        !_samePath(ledger, current) &&
        paths.contentRootIsDefault &&
        _isDefaultContentRootPath(ledger)) {
      return ledger;
    }

    if (!paths.contentRootIsDefault) return null;
    final Set<String> candidates = <String>{};
    for (final EpubBookRow book in books) {
      final String? oldRoot = _defaultContentRootPrefixOf(book.extractDir);
      if (oldRoot == null || _samePath(oldRoot, current)) continue;
      candidates.add(oldRoot);
    }
    // 多个候选 = 库里混着不同旧根；不猜。
    return candidates.length == 1 ? candidates.single : null;
  }

  /// 旧 state 根：台账优先；无台账时从字体 pref 路径反推
  /// `<oldState>/custom_fonts/...`（仅当路径里明确出现 `state/custom_fonts`）。
  static String? _resolveOldStateRoot({
    required AppPaths paths,
    required String? ledgerStateRoot,
    required Map<String, String> prefs,
  }) {
    final String current = paths.stateRoot.path;
    final String? ledger = _nonEmpty(ledgerStateRoot);
    if (ledger != null && !_samePath(ledger, current)) return ledger;

    final Set<String> candidates = <String>{};
    for (final PathRebasePref spec in kPathRebasePrefs) {
      if (spec.shape != PathValueShape.fontCatalogJson &&
          spec.shape != PathValueShape.fontListJson) {
        continue;
      }
      final String? raw = prefs[spec.key];
      if (raw == null || raw.isEmpty) continue;
      for (final String path in _fontPathsInJson(raw)) {
        final String? oldRoot = _stateRootPrefixOf(path);
        if (oldRoot == null || _samePath(oldRoot, current)) continue;
        candidates.add(oldRoot);
      }
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  // ── 改写 ────────────────────────────────────────────────────────────

  static Future<int> _rebaseBookPaths(
    FushiDatabase db, {
    required List<EpubBookRow> books,
    required String oldRoot,
    required String newRoot,
  }) async {
    int changed = 0;
    await db.transaction(() async {
      for (final EpubBookRow book in books) {
        final String? rebased = _rebaseUnder(book.extractDir, oldRoot, newRoot);
        if (rebased == null || rebased == book.extractDir) continue;
        await db.customStatement(
          'UPDATE epub_books SET extract_dir = ? WHERE book_key = ?',
          <Object?>[rebased, book.bookKey],
        );
        changed += 1;
      }
    });
    return changed;
  }

  /// 首页历史 / 最近打开的 `snapshot_json.imageUrl` 可能是本地书封面的
  /// `file://<旧 Content root>/...` URI。不解码成文件路径再编码，分隔符与百分号
  /// 编码都会错（与 `DocumentsPathRebaser.rebaseFileUri` 同一范式）。
  static Future<int> _rebaseMediaOpenHistory(
    FushiDatabase db, {
    required String oldRoot,
    required String newRoot,
  }) async {
    final rows = await db.customSelect(
      '''SELECT media_source, media_id, snapshot_json
             FROM media_open_history
             WHERE snapshot_json LIKE '%file://%' ''',
    ).get();
    int changed = 0;
    for (final row in rows) {
      final String raw = row.read<String>('snapshot_json');
      String? next;
      try {
        final dynamic decoded = jsonDecode(raw);
        if (decoded is Map) {
          final Map<String, dynamic> snapshot = Map<String, dynamic>.from(
            decoded,
          );
          final Object? imageUrl = snapshot['imageUrl'];
          if (imageUrl is String) {
            final String? rebased = _rebaseFileUri(imageUrl, oldRoot, newRoot);
            if (rebased != null && rebased != imageUrl) {
              snapshot['imageUrl'] = rebased;
              next = jsonEncode(snapshot);
            }
          }
        }
      } on FormatException {
        // 坏 JSON 不动；历史展示退化为无封面即可，不该阻断启动。
      }
      if (next == null) continue;
      await db.customStatement(
        'UPDATE media_open_history SET snapshot_json = ? '
        'WHERE media_source = ? AND media_id = ?',
        <Object?>[
          next,
          row.read<String>('media_source'),
          row.read<String>('media_id'),
        ],
      );
      changed += 1;
    }
    return changed;
  }

  /// 字体是 Portable state，路径落 `<state>/custom_fonts`。同时改
  /// `preferences` 与每个 Profile 的 `profile_settings` 快照，否则用户切一次
  /// Profile 就会把刚 rebase 好的路径整体回滚（BUG-1174 的教训）。
  static Future<int> _rebaseFontPrefs(
    FushiDatabase db, {
    required String oldRoot,
    required String newRoot,
  }) async {
    int changed = 0;
    final Map<String, String> prefs = await db.getAllPrefs();
    for (final PathRebasePref spec in kPathRebasePrefs) {
      final String? raw = prefs[spec.key];
      if (raw == null) continue;
      final String? rebased = _rebaseFontPrefValue(
        spec,
        raw,
        oldRoot: oldRoot,
        newRoot: newRoot,
      );
      if (rebased == null || rebased == raw) continue;
      await db.setPref(spec.key, rebased);
      changed += 1;
    }

    final rows = await db
        .customSelect(
          'SELECT id, key, value FROM profile_settings WHERE category = ?',
          variables: <Variable<Object>>[
            Variable<String>(ProfileKeys.categoryPref),
          ],
        )
        .get();
    for (final row in rows) {
      final PathRebasePref? spec = _fontPrefFor(row.read<String>('key'));
      if (spec == null) continue;
      final String value = row.read<String>('value');
      final String? rebased = _rebaseFontPrefValue(
        spec,
        value,
        oldRoot: oldRoot,
        newRoot: newRoot,
      );
      if (rebased == null || rebased == value) continue;
      await db.customStatement(
        'UPDATE profile_settings SET value = ? WHERE id = ?',
        <Object?>[rebased, row.read<int>('id')],
      );
      changed += 1;
    }
    return changed;
  }

  static PathRebasePref? _fontPrefFor(String key) {
    for (final PathRebasePref spec in kPathRebasePrefs) {
      if (spec.key != key) continue;
      if (spec.shape == PathValueShape.fontCatalogJson ||
          spec.shape == PathValueShape.fontListJson) {
        return spec;
      }
      return null;
    }
    return null;
  }

  static String? _rebaseFontPrefValue(
    PathRebasePref spec,
    String raw, {
    required String oldRoot,
    required String newRoot,
  }) {
    String rewrite(String path) => _rebaseUnder(path, oldRoot, newRoot) ?? path;
    switch (spec.shape) {
      case PathValueShape.fontCatalogJson:
        return rebaseFontCatalogJson(
          raw,
          oldRoot,
          newRoot,
          rewritePath: rewrite,
        );
      case PathValueShape.fontListJson:
        return rebaseFontListJson(raw, oldRoot, newRoot, rewritePath: rewrite);
      default:
        return null;
    }
  }

  // ── 路径工具 ────────────────────────────────────────────────────────

  static String? _nonEmpty(String? value) {
    final String? trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  static String _normalizeSlashes(String value) => value.replaceAll('\\', '/');

  static String _stripTrailingSlashes(String value) =>
      value.replaceFirst(RegExp(r'/+$'), '');

  static bool _samePath(String a, String b) =>
      _stripTrailingSlashes(_normalizeSlashes(a)).toLowerCase() ==
      _stripTrailingSlashes(_normalizeSlashes(b)).toLowerCase();

  /// [path] 是否落在 [oldRoot] 下；是则返回挂到 [newRoot] 的路径，否则 null。
  /// 前缀比较按段、大小写不敏感（Windows 盘符 / 用户名大小写不可控），且
  /// `/a/books_extra` 不属于 `/a/books`。
  static String? _rebaseUnder(String path, String oldRoot, String newRoot) {
    final String normalizedPath = _normalizeSlashes(path);
    final String normalizedOld = _stripTrailingSlashes(
      _normalizeSlashes(oldRoot),
    );
    if (normalizedOld.isEmpty || normalizedPath.isEmpty) return null;
    final String lowerPath = normalizedPath.toLowerCase();
    final String lowerOld = normalizedOld.toLowerCase();
    if (lowerPath == lowerOld) return newRoot;
    if (!lowerPath.startsWith('$lowerOld/')) return null;
    final List<String> tail = normalizedPath
        .substring(normalizedOld.length + 1)
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    return p.joinAll(<String>[newRoot, ...tail]);
  }

  static String? _rebaseFileUri(String value, String oldRoot, String newRoot) {
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'file') return null;
    final String filePath;
    try {
      filePath = uri.toFilePath();
    } on UnsupportedError {
      return null;
    }
    final String? rebased = _rebaseUnder(filePath, oldRoot, newRoot);
    if (rebased == null || rebased == filePath) return null;
    return Uri.file(rebased).toString();
  }

  static bool _isDefaultContentRootPath(String path) {
    final List<String> segments = _normalizeSlashes(path)
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) return false;
    return segments.last.toLowerCase() ==
            AppPaths.contentRootDirName.toLowerCase() &&
        segments[segments.length - 2].toLowerCase() == 'documents';
  }

  /// 从 `.../Documents/MyComic/...` 里取出默认根前缀；不是默认根形状返回 null。
  static String? _defaultContentRootPrefixOf(String path) {
    final List<String> segments = _normalizeSlashes(path)
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    for (int i = 1; i < segments.length; i++) {
      if (segments[i].toLowerCase() !=
          AppPaths.contentRootDirName.toLowerCase()) {
        continue;
      }
      if (segments[i - 1].toLowerCase() == 'documents') {
        final bool absolute =
            path.startsWith('/') ||
            path.startsWith(r'\\') ||
            (path.length >= 2 && path[1] == ':');
        if (!absolute) return null;
        // Windows 盘符在 split 后第一段是 `C:`；保留它。
        return segments.sublist(0, i + 1).join('/');
      }
    }
    return null;
  }

  /// 从 `<root>/state/custom_fonts/...` 取出 `<root>`；否则 null。
  static String? _stateRootPrefixOf(String path) {
    final List<String> segments = _normalizeSlashes(path)
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    for (int i = 1; i < segments.length - 1; i++) {
      if (segments[i].toLowerCase() != AppPaths.stateDirName.toLowerCase()) {
        continue;
      }
      if (segments[i + 1].toLowerCase() !=
          AppPaths.customFontsDirName.toLowerCase()) {
        continue;
      }
      final String root = segments.sublist(0, i).join('/');
      if (root.isEmpty) return null;
      return root;
    }
    return null;
  }

  static List<String> _fontPathsInJson(String raw) {
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is List) {
        return <String>[
          for (final dynamic entry in decoded)
            if (entry is Map && entry['path'] is String)
              entry['path'] as String,
        ];
      }
      if (decoded is Map) {
        final dynamic fonts = decoded['fonts'];
        if (fonts is List) {
          return <String>[
            for (final dynamic entry in fonts)
              if (entry is Map && entry['path'] is String)
                entry['path'] as String,
          ];
        }
      }
    } on FormatException {
      // 坏值按无路径处理。
    }
    return const <String>[];
  }
}

/// 一次启动期 portable rebase 的结果。
class PortableStateRebaseOutcome {
  const PortableStateRebaseOutcome({
    required this.booksRebased,
    required this.historyRebased,
    required this.fontPrefsRebased,
    this.oldContentRoot,
    this.oldStateRoot,
  }) : error = null;

  const PortableStateRebaseOutcome.failed(Object this.error)
    : booksRebased = 0,
      historyRebased = 0,
      fontPrefsRebased = 0,
      oldContentRoot = null,
      oldStateRoot = null;

  final int booksRebased;
  final int historyRebased;
  final int fontPrefsRebased;
  final String? oldContentRoot;
  final String? oldStateRoot;

  /// 非 null = 本次自愈失败（已由调用方记录，启动继续，下次启动重试）。
  final Object? error;

  bool get rebased =>
      booksRebased > 0 || historyRebased > 0 || fontPrefsRebased > 0;

  @override
  String toString() => error != null
      ? 'PortableStateRebase(failed: $error)'
      : 'PortableStateRebase(books: $booksRebased, history: $historyRebased, '
            'fontPrefs: $fontPrefsRebased, '
            'content: $oldContentRoot -> current, state: $oldStateRoot -> current)';
}
