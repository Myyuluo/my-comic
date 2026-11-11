/// Ticket 11：设置 →「存储与下载」的「清除缓存」服务。
///
/// 只清**显式缓存目录**：
///  - Mihon 封面缓存 `<state>/mihon/cache/covers`（从不碰登录态 / 扩展数据）；
///  - 在线页流缓存 `<cache>/manga_stream_cache`（保留活跃阅读会话目录）；
///  - CBZ 解包缓存 `<cache>/local_source_archive_cache`（保留活跃阅读会话目录）；
///  - 远端封面缓存 `<cache>/remote_cover_cache`；
///  - 缩略图缓存 `<cache>/thumbnails`；
///  - `AppImageCacheManager` 的磁盘缓存（由缓存管理器自己的 store 统计 / 清空，
///    不扫描系统临时目录）；
///  - Flutter 进程内 [ImageCache]（不参与磁盘占用统计）。
///
/// 下载库（Content root 的 `downloads`）、本地图源（`local`，含 `cover.jpg`）、
/// History / Reading progress / 数据库、图源登录态都不在本服务的步骤里。
///
/// 占用统计覆盖上述显式缓存目录、图片管理器自己的磁盘 store，以及 WebView
/// profile 里 CDP 会清理的 HTTP cache 子目录（见
/// `manga_webview_cache_clear.dart`）。
/// 进度、确认框、部分成功提示和 toast 由同一套外层流程自动覆盖。
library;

import 'dart:io';

import 'package:flutter/painting.dart';

/// 一次清缓存进度快照。
class MangaCacheClearProgress {
  const MangaCacheClearProgress({
    required this.completed,
    required this.total,
    this.currentLabel,
  });

  /// 已处理步骤数。
  final int completed;

  /// 总步骤数。
  final int total;

  /// 正在执行的步骤名（给进度框用）。
  final String? currentLabel;

  /// 0..1；[total] 为 0 时为 null（不确定态）。
  double? get fraction => total <= 0 ? null : completed / total;
}

/// 单个缓存步骤的结果。
class MangaCacheClearStepResult {
  const MangaCacheClearStepResult({
    required this.id,
    required this.freedBytes,
    this.failedEntries = 0,
    this.failed = false,
    this.skipped = false,
  });

  final String id;
  final int freedBytes;

  /// 单个文件 / 目录删除失败的次数。非 0 表示该步骤部分成功。
  final int failedEntries;

  /// 整个步骤失败（例如缓存管理器抛异常）。
  final bool failed;

  /// 当前平台无法安全清理该步骤（例如非 Windows 上的 WebView / HTTP 缓存）。
  /// 跳过的步骤没有释放任何字节，整体结果按部分成功提示。
  final bool skipped;

  bool get hasFailure => failed || failedEntries > 0;
}

/// 一次清缓存的完整结果。
class MangaCacheClearReport {
  const MangaCacheClearReport({required this.steps});

  final List<MangaCacheClearStepResult> steps;

  int get freedBytes => steps.fold<int>(
    0,
    (int sum, MangaCacheClearStepResult s) => sum + s.freedBytes,
  );

  bool get hasFailures =>
      steps.any((MangaCacheClearStepResult s) => s.hasFailure);

  bool get hasSkipped => steps.any((MangaCacheClearStepResult s) => s.skipped);

  /// 只要有任何步骤失败或被跳过，就不能宣称全部清完。
  bool get hasPartial => hasFailures || hasSkipped;
}

/// 一个可清理的缓存步骤。
///
/// [measureBytes] 供副标题 / 确认框显示当前占用；只有内存图片等不占磁盘的
/// 步骤返回 0。真正的释放量始终以 [clear] 的结果为准。
abstract class MangaCacheClearStep {
  const MangaCacheClearStep();

  String get id;

  /// 进度框展示的步骤名（i18n 文案由调用方在构造时传入）。
  String get label;

  Future<int> measureBytes();

  Future<MangaCacheClearStepResult> clear();
}

/// 依次执行 [steps]；单步抛异常 / 文件删失败都不中断后续步骤。
class MangaCacheClearService {
  MangaCacheClearService({required List<MangaCacheClearStep> steps})
    : steps = List<MangaCacheClearStep>.unmodifiable(steps);

  final List<MangaCacheClearStep> steps;

  /// 所有步骤当前占用之和。单步测量失败按 0 计，不影响其它步骤。
  Future<int> measureTotalBytes() async {
    int total = 0;
    for (final MangaCacheClearStep step in steps) {
      try {
        total += await step.measureBytes();
      } on Object {
        // 大小只是展示：某一步读不到（权限 / 并发删除）就少算它，不清缓存失败。
      }
    }
    return total;
  }

  /// 逐步清理。每一步开始 / 结束时各报一次进度；失败继续。
  Future<MangaCacheClearReport> run({
    void Function(MangaCacheClearProgress progress)? onProgress,
  }) async {
    final List<MangaCacheClearStepResult> results =
        <MangaCacheClearStepResult>[];
    for (int index = 0; index < steps.length; index++) {
      final MangaCacheClearStep step = steps[index];
      onProgress?.call(
        MangaCacheClearProgress(
          completed: index,
          total: steps.length,
          currentLabel: step.label,
        ),
      );
      MangaCacheClearStepResult result;
      try {
        result = await step.clear();
      } on Object {
        result = MangaCacheClearStepResult(
          id: step.id,
          freedBytes: 0,
          failed: true,
        );
      }
      results.add(result);
      onProgress?.call(
        MangaCacheClearProgress(
          completed: index + 1,
          total: steps.length,
          currentLabel: step.label,
        ),
      );
    }
    return MangaCacheClearReport(steps: results);
  }
}

/// 删除单个文件系统实体的测试缝（默认 `entity.delete(recursive: true)`）。
typedef MangaCacheEntityDelete = Future<void> Function(FileSystemEntity entity);

Future<void> _defaultDeleteEntity(FileSystemEntity entity) async {
  if (await entity.exists()) await entity.delete(recursive: true);
}

/// 清空一个或多个目录的**内容**，保留目录本身（Mihon 封面缓存 / 远端封面 /
/// 缩略图在内存里持有目录路径，删掉目录会让后续写入失败）。
class MangaCacheDirectoryClearStep extends MangaCacheClearStep {
  MangaCacheDirectoryClearStep({
    required this.id,
    required this.label,
    required List<Directory> roots,
    MangaCacheEntityDelete? deleteEntity,
  }) : roots = List<Directory>.unmodifiable(roots),
       _deleteEntity = deleteEntity ?? _defaultDeleteEntity;

  @override
  final String id;

  @override
  final String label;

  final List<Directory> roots;
  final MangaCacheEntityDelete _deleteEntity;

  @override
  Future<int> measureBytes() => mangaCacheDirectorySize(roots);

  @override
  Future<MangaCacheClearStepResult> clear() async {
    int freed = 0;
    int failures = 0;
    for (final Directory root in roots) {
      if (!await root.exists()) continue;
      final List<FileSystemEntity> children;
      try {
        children = await root.list(followLinks: false).toList();
      } on FileSystemException {
        failures++;
        continue;
      }
      for (final FileSystemEntity child in children) {
        final ({int freed, int failures}) result = await _deleteTree(child);
        freed += result.freed;
        failures += result.failures;
      }
    }
    return MangaCacheClearStepResult(
      id: id,
      freedBytes: freed,
      failedEntries: failures,
    );
  }

  Future<({int freed, int failures})> _deleteTree(
    FileSystemEntity entity,
  ) async {
    if (entity is Directory) {
      int freed = 0;
      int failures = 0;
      List<FileSystemEntity> children;
      try {
        children = await entity.list(followLinks: false).toList();
      } on FileSystemException {
        return (freed: 0, failures: 1);
      }
      for (final FileSystemEntity child in children) {
        final ({int freed, int failures}) result = await _deleteTree(child);
        freed += result.freed;
        failures += result.failures;
      }
      try {
        await _deleteEntity(entity);
      } on FileSystemException {
        failures++;
      }
      return (freed: freed, failures: failures);
    }

    int length = 0;
    if (entity is File) {
      try {
        length = await entity.length();
      } on FileSystemException {
        // 读不到长度只是少算释放量，删除照常尝试。
      }
    }
    try {
      await _deleteEntity(entity);
      return (freed: length, failures: 0);
    } on FileSystemException {
      return (freed: 0, failures: 1);
    }
  }
}

/// 只清不在活跃阅读会话里的页缓存目录。
///
/// [pruneInactive] 复用阅读会话自己的 prune 原语（它知道哪些目录仍被会话持有），
/// 返回删除失败次数。释放量按 prune 前后目录大小差计算。
class MangaCacheSessionPruneStep extends MangaCacheClearStep {
  const MangaCacheSessionPruneStep({
    required this.id,
    required this.label,
    required this.root,
    required this.pruneInactive,
  });

  @override
  final String id;

  @override
  final String label;

  final Directory root;

  /// 返回单个条目删除失败的次数；不抛异常（原语内部已 best-effort）。
  final Future<int> Function(Directory root) pruneInactive;

  @override
  Future<int> measureBytes() => mangaCacheDirectorySize(<Directory>[root]);

  @override
  Future<MangaCacheClearStepResult> clear() async {
    final int before = await measureBytes();
    final int failures = await pruneInactive(root);
    final int after = await measureBytes();
    final int freed = before > after ? before - after : 0;
    return MangaCacheClearStepResult(
      id: id,
      freedBytes: freed,
      failedEntries: failures,
    );
  }
}

/// 缓存管理器磁盘缓存：大小由管理器自己的 store 统计，不扫描系统临时目录。
///
/// [measureBytes] 直接返回管理器统计的磁盘占用，副标题与确认框因此包含这部分；
/// 释放量仍在 [clear] 里真实计算并计入 toast。
class MangaCacheManagerClearStep extends MangaCacheClearStep {
  const MangaCacheManagerClearStep({
    required this.id,
    required this.label,
    required this.measureManagerBytes,
    required this.emptyManager,
  });

  @override
  final String id;

  @override
  final String label;

  final Future<int> Function() measureManagerBytes;
  final Future<void> Function() emptyManager;

  @override
  Future<int> measureBytes() => measureManagerBytes();

  @override
  Future<MangaCacheClearStepResult> clear() async {
    int before = 0;
    try {
      before = await measureManagerBytes();
    } on Object {
      // 管理器还没打开 / 测试宿主没有缓存 store：按 0 继续清。
    }
    try {
      await emptyManager();
      return MangaCacheClearStepResult(id: id, freedBytes: before);
    } on Object {
      int after = 0;
      try {
        after = await measureManagerBytes();
      } on Object {
        // 清失败后重新测量也失败：只能报告失败，不虚报释放量。
      }
      return MangaCacheClearStepResult(
        id: id,
        freedBytes: before > after ? before - after : 0,
        failed: true,
      );
    }
  }
}

/// Flutter 进程内图片缓存：不计入磁盘占用，清理失败算部分失败。
class MangaMemoryImageCacheClearStep extends MangaCacheClearStep {
  const MangaMemoryImageCacheClearStep({
    required this.id,
    required this.label,
    this.imageCache,
  });

  @override
  final String id;

  @override
  final String label;

  /// 测试注入；null = 使用 [PaintingBinding.instance.imageCache]。
  final ImageCache? imageCache;

  @override
  Future<int> measureBytes() async => 0;

  @override
  Future<MangaCacheClearStepResult> clear() async {
    final ImageCache cache = imageCache ?? PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
    return MangaCacheClearStepResult(id: id, freedBytes: 0);
  }
}

/// 递归统计若干目录的字节数；不存在的目录按 0 计。
Future<int> mangaCacheDirectorySize(List<Directory> roots) async {
  int total = 0;
  for (final Directory root in roots) {
    if (!await root.exists()) continue;
    try {
      await for (final FileSystemEntity entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          total += await entity.length();
        } on FileSystemException {
          // 并发删除 / 权限：跳过该文件。
        }
      }
    } on FileSystemException {
      // 整树列举失败：保留已累计部分。
    }
  }
  return total;
}
