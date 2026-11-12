import 'dart:convert';

/// Rebases every file-font `path` inside a persisted font-list JSON string
/// (`[{name, path, enabled}, ...]`) from [oldRoot] onto [newRoot] via
/// [rewritePath]. System fonts (`path == null`) and paths not under [oldRoot]
/// are left untouched — malformed values return verbatim.
String rebaseFontListJson(
  String json,
  String oldRoot,
  String newRoot, {
  String Function(String path)? rewritePath,
}) {
  String rewrite(String path) =>
      rewritePath == null ? rebasePath(path, oldRoot, newRoot) : rewritePath(path);
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! List) return json;
    final List<dynamic> out = decoded.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Object? path = e['path'];
      if (path is! String) return e;
      return <String, dynamic>{
        ...Map<String, dynamic>.from(e),
        'path': rewrite(path),
      };
    }).toList();
    return jsonEncode(out);
  } catch (_) {
    return json;
  }
}

/// Rebases every file-font `path` inside the canonical font catalog JSON
/// (`{version, fonts:[{id, name, path}]}`) from [oldRoot] onto [newRoot].
String rebaseFontCatalogJson(
  String json,
  String oldRoot,
  String newRoot, {
  String Function(String path)? rewritePath,
}) {
  String rewrite(String path) =>
      rewritePath == null ? rebasePath(path, oldRoot, newRoot) : rewritePath(path);
  try {
    final dynamic decoded = jsonDecode(json);
    if (decoded is! Map) return json;
    final Map<String, dynamic> root = Map<String, dynamic>.from(decoded);
    final dynamic fonts = root['fonts'];
    if (fonts is! List) return json;
    root['fonts'] = fonts.map<dynamic>((dynamic e) {
      if (e is! Map) return e;
      final Map<String, dynamic> row = Map<String, dynamic>.from(e);
      final Object? path = row['path'];
      if (path is! String) return row;
      return <String, dynamic>{
        ...row,
        'path': rewrite(path),
      };
    }).toList();
    return jsonEncode(root);
  } catch (_) {
    return json;
  }
}

/// Rewrites [path] under [oldRoot] onto [newRoot], keeping the relative suffix.
String rebasePath(String path, String oldRoot, String newRoot) {
  final String oldNormalized =
      oldRoot.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
  final String pathNormalized = path.replaceAll('\\', '/');
  if (!pathNormalized.startsWith('$oldNormalized/')) return path;
  final String suffix = pathNormalized.substring(oldNormalized.length);
  final String newNormalized =
      newRoot.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
  return '$newNormalized$suffix';
}
