/// 书架、作品页与重建预热共用的封面解析 / 决策逻辑。
///
/// 三个入口的展示形态不同，但「这本书已经有什么封面、还能不能生成第一页封面」
/// 必须只有一份判据：
/// - 本地已落盘封面（`epub_books.cover_path`，可能是页图路径；也可能是作品根
///   目录的 `cover.jpg/jpeg/png`）；
/// - 按 bookKey 的持久真实封面字节（`MangaShelfCoverCache` 的 `.url` 侧车不是
///   生成封面 sentinel）；
/// - 可用来源当前封面（由调用方判定来源可用性）；
/// - 第一页生成封面。
///
/// 本文件只处理前两层的**磁盘解析**（无 DB / 无网络）：候选路径顺序、大小写
/// 不敏感解析与「已记录封面」判定。来源可用性与生成封面由调用方注入。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart'
    show kLocalSourceCoverFileNames;

/// 一部作品已解析出的、优先级高于生成封面的封面。
class MangaCoverResolution {
  const MangaCoverResolution({this.localFilePath, this.realCachedUrl});

  /// 本地已落盘封面的绝对路径（声明路径优先，其次根目录 `cover.*`）。
  final String? localFilePath;

  /// 按 bookKey 持久化的**真实来源**封面 `file://` URL；生成封面时为 null。
  final String? realCachedUrl;

  /// 是否已有更优先的封面（本地文件或真实来源字节）。
  bool get hasExistingCover => localFilePath != null || realCachedUrl != null;
}

/// 封面候选路径，声明路径优先，其次作品根目录的 `cover.jpg/jpeg/png`。
///
/// 返回绝对路径，供书架并发 `File.exists` 探测；相对路径的大小写不敏感解析见
/// [resolveMangaCoverFilePath]。
List<String> mangaCoverCandidatePaths({
  required String extractDir,
  String? coverPath,
}) {
  final List<String> candidates = <String>[];
  if (coverPath != null && coverPath.isNotEmpty) {
    String coverRel = coverPath;
    if (coverRel.startsWith('/')) coverRel = coverRel.substring(1);
    candidates.add(p.join(extractDir, coverRel));
  }
  for (final String name in kLocalSourceCoverFileNames) {
    candidates.add(p.join(extractDir, name));
  }
  return candidates;
}

/// 大小写不敏感地解析封面文件（精确大小写优先，其次逐段忽略大小写）。
///
/// 目录枚举可注入（[listDir]），纯函数便于测试；生产解析用真实文件系统。
/// 声明路径可能是页图路径（本地登记 / 备份），因此不假设文件名必须是
/// `cover.*`。
String? resolveMangaCoverCandidate({
  required String extractDir,
  required List<String> relPaths,
  required List<String> Function(String dir) listDir,
}) {
  for (final String rel in relPaths) {
    if (rel.isEmpty || p.isAbsolute(rel)) continue;
    final List<String> segs = p
        .split(rel)
        .where((String s) => s.isNotEmpty && s != '.' && s != '/')
        .toList();
    if (segs.isEmpty) continue;
    String current = extractDir;
    bool resolvedAll = true;
    for (final String seg in segs) {
      final List<String> children = listDir(current);
      String? match;
      for (final String child in children) {
        if (p.basename(child) == seg) {
          match = child;
          break;
        }
      }
      if (match == null) {
        final String segLower = seg.toLowerCase();
        for (final String child in children) {
          if (p.basename(child).toLowerCase() == segLower) {
            match = child;
            break;
          }
        }
      }
      if (match == null) {
        resolvedAll = false;
        break;
      }
      current = match;
    }
    if (resolvedAll) return current;
  }
  return null;
}

/// 解析作品封面到磁盘真实路径；没有候选命中返回 null。
///
/// 声明路径（`epub_books.cover_path`，含页图路径）优先；其次作品根目录的
/// `cover.jpg/jpeg/png`。书架 / 作品页 / 制卡 / 重建预热共用这一份解析。
String? resolveMangaCoverFilePath({
  required String extractDir,
  String? coverPath,
}) {
  final String? resolved = resolveMangaCoverCandidate(
    extractDir: extractDir,
    relPaths: <String>[
      if (coverPath != null && coverPath.isNotEmpty) coverPath,
      ...kLocalSourceCoverFileNames,
    ],
    listDir: _listDirEntries,
  );
  if (resolved != null && File(resolved).existsSync()) return resolved;
  return null;
}

List<String> _listDirEntries(String dir) {
  final Directory d = Directory(dir);
  if (!d.existsSync()) return const <String>[];
  try {
    return d
        .listSync(followLinks: false)
        .map((FileSystemEntity e) => e.path)
        .toList();
  } catch (_) {
    return const <String>[];
  }
}
