/// Local source 条目的 Library 元数据。
///
/// Local source 不向用户的 `localcomic` 写隐藏元数据（ADR 0013）；作品与章节的
/// 重启安全描述只存在数据库的 `epub_books.sourceMetadata` / `chaptersJson` 列里。
/// 这不是「目录即身份」的替代品——身份仍是文件夹路径，这里只记录相对路径，
/// 供缺失检测 / 重建索引重新定位。
library;

import 'dart:convert';

/// `epub_books.sourceMetadata` 里 Local source 条目的标记。
class LocalSourceMetadata {
  const LocalSourceMetadata({required this.relativePath});

  static const String marker = 'mycomic-local-source';
  static const int version = 1;

  /// 相对 Local source root 的正斜杠路径。
  final String relativePath;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': marker,
    'version': version,
    'relativePath': relativePath,
  };

  String encode() => jsonEncode(toJson());

  /// 非 Local source 条目 / 坏 JSON 返回 null。
  static LocalSourceMetadata? tryParse(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(value);
      if (decoded is! Map<Object?, Object?>) return null;
      final Map<String, Object?> json = decoded.cast<String, Object?>();
      if (json['kind']?.toString() != marker) return null;
      final int parsedVersion = (json['version'] as num?)?.toInt() ?? 0;
      if (parsedVersion != version) return null;
      final String relativePath = json['relativePath']?.toString() ?? '';
      if (relativePath.isEmpty) return null;
      return LocalSourceMetadata(relativePath: relativePath);
    } on Object {
      return null;
    }
  }
}

/// 存进 `epub_books.chaptersJson` 的一章。
///
/// [key] 是章节身份 = 相对 Manga 目录的路径（单章为 `.`）。目录/CBZ 改名 =
/// 新 key，与「作品身份是文件夹路径」同一规则。
class LocalSourceChapterRecord {
  const LocalSourceChapterRecord({
    required this.key,
    required this.name,
    required this.relativePath,
  });

  final String key;
  final String name;

  /// 相对 Manga 目录的正斜杠路径：章节目录或 `.cbz` 文件；单章为空串。
  final String relativePath;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'name': name,
    'relativePath': relativePath,
  };

  static LocalSourceChapterRecord? fromJson(Map<String, Object?> json) {
    final String key = json['key']?.toString() ?? '';
    if (key.isEmpty) return null;
    return LocalSourceChapterRecord(
      key: key,
      name: json['name']?.toString() ?? key,
      relativePath: json['relativePath']?.toString() ?? '',
    );
  }
}

String encodeLocalSourceChapters(List<LocalSourceChapterRecord> chapters) =>
    jsonEncode(<Object?>[
      for (final LocalSourceChapterRecord chapter in chapters) chapter.toJson(),
    ]);

/// 解析 Local source 的 `chaptersJson`；不是数组 / 坏 JSON / 坏条目返回空表。
List<LocalSourceChapterRecord> decodeLocalSourceChapters(String json) {
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List<Object?>) return const <LocalSourceChapterRecord>[];
    final List<LocalSourceChapterRecord> chapters =
        <LocalSourceChapterRecord>[];
    for (final Object? item in decoded) {
      if (item is! Map<Object?, Object?>) continue;
      final LocalSourceChapterRecord? chapter =
          LocalSourceChapterRecord.fromJson(item.cast<String, Object?>());
      if (chapter != null) chapters.add(chapter);
    }
    return List<LocalSourceChapterRecord>.unmodifiable(chapters);
  } on Object {
    return const <LocalSourceChapterRecord>[];
  }
}
