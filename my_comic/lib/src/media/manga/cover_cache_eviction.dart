import 'dart:io';

/// 在线封面磁盘缓存的默认容量：512 条 / 64 MiB。
///
/// 书架持久封面缓存（按 bookKey）与 Mihon 封面缓存（按 URL）共用同一份预算；
/// 单张封面常达数 MB，只有条数上限挡不住目录膨胀。
const int kCoverCacheMaxEntries = 512;
const int kCoverCacheMaxBytes = 64 * 1024 * 1024;

/// 两类在线封面缓存共用的 mtime 淘汰策略。
///
/// 规则：统计目录下全部文件的字节数；按写入时间（mtime）升序淘汰条目，直到
/// 条数与字节数都回到上限以内。刻意不做访问时间 LRU：Windows 的 atime 不可信，
/// 命中时回写 mtime 又会同时重置缓存年龄与淘汰顺序。
///
/// 书架缓存的文件布局是 `<key>.cover` + `<key>.url` 侧车；通过
/// [entrySuffix] / [sidecarSuffix] 让淘汰只排序 `.cover`，删条目时先删侧车并
/// 扣掉它的字节。Mihon 缓存只有一个文件，两个后缀都留空即可。
class CoverCacheEvictionPolicy {
  const CoverCacheEvictionPolicy({
    this.maxEntries = kCoverCacheMaxEntries,
    this.maxBytes = kCoverCacheMaxBytes,
    this.entrySuffix,
    this.sidecarSuffix,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);

  /// 最多保留的条目数。
  final int maxEntries;

  /// 目录字节预算（含侧车与遗留临时文件）。
  final int maxBytes;

  /// 只有以此后缀结尾的文件参与条数排名；null = 目录下所有文件都是条目。
  final String? entrySuffix;

  /// 条目被淘汰时一并删除的同名侧车后缀（如 `.url`）。
  final String? sidecarSuffix;

  /// 当前磁盘占用。
  Future<int> measureBytes(Directory directory) async {
    try {
      if (!await directory.exists()) return 0;
      int total = 0;
      await for (final FileSystemEntity entity in directory.list(
        recursive: false,
      )) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } on FileSystemException {
          // 并发删除时跳过。
        }
      }
      return total;
    } on FileSystemException {
      return 0;
    }
  }

  /// 超过条数或字节上限时，按写入时间升序淘汰最旧条目。
  Future<void> trim(Directory directory) async {
    try {
      if (!await directory.exists()) return;
      final List<File> files = await directory
          .list()
          .where((FileSystemEntity entity) => entity is File)
          .cast<File>()
          .toList();
      final List<({File file, DateTime modified, int length})> entries =
          <({File file, DateTime modified, int length})>[];
      int totalBytes = 0;
      for (final File file in files) {
        final FileStat stat = await file.stat();
        totalBytes += stat.size;
        final String? suffix = entrySuffix;
        if (suffix != null && !file.path.endsWith(suffix)) continue;
        entries.add((file: file, modified: stat.modified, length: stat.size));
      }
      if (entries.length <= maxEntries && totalBytes <= maxBytes) return;
      entries.sort((left, right) => left.modified.compareTo(right.modified));
      int remaining = entries.length;
      for (final ({File file, DateTime modified, int length}) entry
          in entries) {
        if (remaining <= maxEntries && totalBytes <= maxBytes) break;
        totalBytes -= await _deleteSidecar(entry.file);
        totalBytes -= entry.length;
        await entry.file.delete();
        remaining--;
      }
    } on FileSystemException {
      // 并发清理 / 权限变化不影响封面显示。
    }
  }

  /// 删除条目的侧车，返回从目录字节数中扣掉的字节。
  Future<int> _deleteSidecar(File entry) async {
    final String? suffix = sidecarSuffix;
    final String? entrySuffix = this.entrySuffix;
    if (suffix == null || entrySuffix == null) return 0;
    final String path = entry.path;
    if (!path.endsWith(entrySuffix)) return 0;
    final File sidecar = File(
      '${path.substring(0, path.length - entrySuffix.length)}$suffix',
    );
    try {
      if (await sidecar.exists()) {
        final int length = await sidecar.length();
        await sidecar.delete();
        return length;
      }
    } on FileSystemException {
      // 侧车清理失败不阻止封面淘汰。
    }
    return 0;
  }
}
