import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/utils/cover_image.dart';

/// Program state 缓存根下承载书架持久封面字节的目录名。
///
/// 位置形如 `<programState>/cache/shelf_covers`；它属于 Cache，不属于
/// Content root，也不进入 Download library。清除缓存会整目录删除。
const String kMangaShelfCoverCacheDirName = 'shelf_covers';

/// 在线漫画书架封面的持久字节缓存，按 bookKey 归属。
///
/// 与按 URL 命名的 [MihonCoverCache] 不同：书架的稳定身份是 bookKey，而源返回的
/// 封面 URL 可能每次刷新都带新签名。缓存以 bookKey 摘要命名，另存一份「产生这些
/// 字节的源 URL」侧车，用来判断是否需要后台刷新——签名 URL 过期后，只要字节还在，
/// 书架就继续显示封面；拿到新 URL 时后台替换字节，失败则原样保留旧字节。
///
/// 容量沿用 Mihon 封面缓存的思路：条数 + 字节双上限，按写入时间升序淘汰最旧条目。
/// 不做访问时间 LRU：Windows 的 atime 不可信，回写 mtime 又会打乱淘汰顺序。
class MangaShelfCoverCache {
  MangaShelfCoverCache(
    this.directory, {
    this.maxEntries = 512,
    this.maxBytes = 64 * 1024 * 1024,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);

  /// 缓存目录（通常是 `<programState>/cache/shelf_covers`）。
  final Directory directory;

  /// 最多保留的封面条数。
  final int maxEntries;

  /// 目录字节预算。单张封面常达数 MB，只有条数上限挡不住目录膨胀。
  final int maxBytes;

  /// bookKey → 缓存文件路径。bookKey 可能含路径分隔符或任意 Unicode，
  /// 统一用 sha256 摘要做文件名，保证跨平台合法且与条目一一对应。
  File coverPathFor(String bookKey) =>
      File(p.join(directory.path, '${_keyOf(bookKey)}.cover'));

  File _sourceUrlPathFor(String bookKey) =>
      File(p.join(directory.path, '${_keyOf(bookKey)}.url'));

  /// 命中返回缓存文件的 `file://` URL；没有缓存或缓存为空返回 null。
  ///
  /// 这里**不**检查年龄：签名 URL 过期与缓存年龄无关，只要字节还在就继续显示；
  /// 容量整理与「清除缓存」才是删除入口。
  Future<String?> coverUrlFor(String bookKey) async {
    final File file = coverPathFor(bookKey);
    try {
      if (!await file.exists()) return null;
      if (await file.length() == 0) return null;
      return Uri.file(file.path).toString();
    } on FileSystemException {
      return null;
    }
  }

  Future<bool> hasCover(String bookKey) async =>
      await coverUrlFor(bookKey) != null;

  /// 产生当前缓存字节的源 URL；没有缓存或没有侧车时返回 null。
  Future<String?> storedSourceUrl(String bookKey) async {
    try {
      final File file = _sourceUrlPathFor(bookKey);
      if (!await file.exists()) return null;
      final String url = (await file.readAsString()).trim();
      return url.isEmpty ? null : url;
    } on FileSystemException {
      return null;
    }
  }

  /// 是否需要为 [sourceUrl] 重新取字节。
  ///
  /// 无缓存、来源 URL 变了，或缓存文件损坏为空时为 true。URL 相同则复用——
  /// 书架每次重建都调用，不能把「显示」变成「每次联网」。
  Future<bool> needsRefresh({
    required String bookKey,
    required String? sourceUrl,
  }) async {
    if (sourceUrl == null || sourceUrl.isEmpty) return false;
    if (!await hasCover(bookKey)) return true;
    return await storedSourceUrl(bookKey) != sourceUrl;
  }

  /// 写入一份封面字节与它对应的源 URL。空字节视为失败，不覆盖旧缓存。
  ///
  /// 写盘走临时文件 + rename，崩溃不会留下截断的封面；同路径覆盖写后驱逐
  /// Flutter ImageCache 的旧解码，避免书架重建时命中换图前的图像。
  Future<bool> store({
    required String bookKey,
    required String sourceUrl,
    required List<int> bytes,
  }) async {
    if (bytes.isEmpty) return false;
    final File target = coverPathFor(bookKey);
    File? temporary;
    try {
      await directory.create(recursive: true);
      temporary = File(
        '${target.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
      );
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
      await _sourceUrlPathFor(bookKey).writeAsString(sourceUrl, flush: true);
    } on FileSystemException {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } on FileSystemException {
        // 清理竞态忽略；容量整理会处理遗留临时文件。
      }
      return false;
    }
    // 同路径覆盖写：书架/首页可能已经缓存了旧解码，必须双键驱逐。
    try {
      await evictLocalCoverCache(target.path);
    } on Object {
      // 没有 Flutter binding 的纯 Dart 环境（诊断工具）忽略即可。
    }
    await trim();
    return true;
  }

  Future<void> remove(String bookKey) async {
    for (final File file in <File>[
      coverPathFor(bookKey),
      _sourceUrlPathFor(bookKey),
    ]) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        // 已删除 / 权限变化都算尽力清理。
      }
    }
    try {
      await evictLocalCoverCache(coverPathFor(bookKey).path);
    } on Object {
      // 同上：无 binding 环境忽略。
    }
  }

  /// 清空整个缓存目录（「清除缓存」使用）。
  Future<void> clear() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on FileSystemException {
      // 并发删除 / 权限变化不影响后续回退到远程 URL 或占位。
    }
  }

  /// 当前磁盘占用（含源 URL 侧车与遗留临时文件）。
  Future<int> measureBytes() async {
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

  /// 容量整理：超过条数或字节上限时，按写入时间升序淘汰最旧封面。
  Future<void> trim() async {
    try {
      if (!await directory.exists()) return;
      final List<File> files = await directory
          .list()
          .where((FileSystemEntity entity) => entity is File)
          .cast<File>()
          .toList();
      final List<({File file, DateTime modified, int length})> covers =
          <({File file, DateTime modified, int length})>[];
      int totalBytes = 0;
      for (final File file in files) {
        final FileStat stat = await file.stat();
        totalBytes += stat.size;
        if (file.path.endsWith('.cover')) {
          covers.add((file: file, modified: stat.modified, length: stat.size));
        }
      }
      if (covers.length <= maxEntries && totalBytes <= maxBytes) return;
      covers.sort((left, right) => left.modified.compareTo(right.modified));
      int remaining = covers.length;
      for (final ({File file, DateTime modified, int length}) entry in covers) {
        if (remaining <= maxEntries && totalBytes <= maxBytes) break;
        final File sourceUrl = File(
          '${entry.file.path.substring(0, entry.file.path.length - '.cover'.length)}.url',
        );
        try {
          if (await sourceUrl.exists()) {
            totalBytes -= await sourceUrl.length();
            await sourceUrl.delete();
          }
        } on FileSystemException {
          // 侧车清理失败不阻止封面淘汰。
        }
        await entry.file.delete();
        remaining--;
        totalBytes -= entry.length;
      }
    } on FileSystemException {
      // 并发清理 / 权限变化不影响封面显示。
    }
  }

  static String _keyOf(String bookKey) =>
      sha256.convert(utf8.encode(bookKey)).toString();
}
