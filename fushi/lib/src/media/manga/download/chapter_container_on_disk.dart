import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart'
    show MangaPagesManifest;

/// 磁盘上的一个章节容器：文件夹章节或 CBZ 压缩包章节。
///
/// 下载服务（认领已存在的容器）与 Rebuild download index（扫描下载目录）共用
/// 这一种值类型，避免两处各维护一份几乎相同的私有模型。
///
/// [manifest] / [complete] 只有重建扫描会填充；下载认领路径按需自行读 manifest
/// 判断完整，不依赖这两个字段。
class ChapterContainerOnDisk {
  const ChapterContainerOnDisk.folder({
    required this.containerName,
    required this.directory,
    this.manifest,
    this.complete = false,
  }) : archiveFile = null;

  const ChapterContainerOnDisk.archive({
    required this.containerName,
    required this.archiveFile,
    this.manifest,
    this.complete = false,
  }) : directory = null;

  /// 单段容器名：章节目录名，或含 `.cbz` 扩展名的文件名。
  final String containerName;

  /// 章节目录；archive 容器为 null。
  final Directory? directory;

  /// CBZ 压缩包；folder 容器为 null。
  final File? archiveFile;

  /// 容器的 `pages.json`（不存在 / 解析失败 = null）。
  final MangaPagesManifest? manifest;

  /// 页表存在且整章完整（仅重建扫描填充）。
  final bool complete;

  MangaChapterContainerKind get kind => directory != null
      ? MangaChapterContainerKind.folder
      : MangaChapterContainerKind.archive;

  bool get isArchive => archiveFile != null;
}
