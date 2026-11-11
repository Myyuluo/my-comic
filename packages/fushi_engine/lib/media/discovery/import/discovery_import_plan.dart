/// 发现页下载物 → 导入计划的**纯分类**层：不碰 IO，输入是路径/文件清单，
/// 输出 sealed [DiscoveryImportPlan]。执行（真正调用漫画导入器）在
/// `discovery_import_executor.dart`；分类规则全部可单测。
///
/// my-comic 独立化后只保留漫画域：小说 / PDF / 有声书 / 游戏分类分支删除，
/// 非漫画类型一律落到 [DiscoveryImportBlocker.unknownFileType]。
library;

import 'package:fushi_engine/media/discovery/discovery_models.dart';

/// 需要先解压的压缩包扩展名。zip 走内置解码，7z/rar 依赖 7-Zip 命令行。
const Set<String> kDiscoveryArchiveExtensions = <String>{'.zip', '.7z', '.rar'};

/// 漫画**图包**载体：整包交给 `MangaArchiveImporter`，不走通用解压器。
///
/// 为什么必须是独立一档、且判定要**排在** [isDiscoveryArchivePath] 之前：
/// `.rar`/`.zip` 同时落在通用压缩包集合里，先被通用解压器截胡的话，解出来的
/// 只是一堆散图，重分类只能走 `MangaImporter.importFromImageFolder`——**包内的
/// `.mokuro` OCR 层会被静默丢掉**，用户得到一部没有查词层的漫画，而且没有任何
/// 报错。`MangaArchiveImporter` 自己解包、自己找 sidecar，把整包给它才是完整路径。
const Set<String> kDiscoveryMangaArchiveExtensions = <String>{
  '.cbz',
  '.cbr',
  '.cb7',
  '.rar',
  '.zip',
};

/// 自动导入走不下去的稳定原因（UI 层负责翻译成用户文案）。
///
/// 保留旧枚举值（有声书 / 游戏域）以免历史任务行的原因码解析崩溃；漫画域只产出
/// [unknownFileType]、[archiveToolMissing]、[archiveExtractionFailed]、
/// [unsupportedOnThisHost]。
enum DiscoveryImportBlocker {
  /// 该媒体域认不出这个文件类型。
  unknownFileType,

  /// 有声书包里没有 EPUB/文本正文（历史值）。
  audiobookMissingText,

  /// 有声书包里没有字幕（历史值）。
  audiobookMissingSubtitle,

  /// 有声书包里没有音频（历史值）。
  audiobookMissingAudio,

  /// 有声书包里的正文与库中已有书同名（历史值）。
  audiobookBookAlreadyInLibrary,

  /// 游戏包里找不到可执行文件（历史值）。
  gameNoExecutable,

  /// 7z/rar 需要 7-Zip 命令行而本机没有。
  archiveToolMissing,

  /// 解压失败（损坏/带密码等）。
  archiveExtractionFailed,

  /// 分类出来了，但执行这一步的宿主没有对应的导入器。
  unsupportedOnThisHost,
}

/// 自动导入被挡下（分类不出/解压工具缺失/解压失败）。队列把它落成任务
/// failed；[blocker] 是稳定原因码，UI 层翻译。
class DiscoveryImportBlockedException implements Exception {
  const DiscoveryImportBlockedException(this.blocker, [this.detail]);

  final DiscoveryImportBlocker blocker;
  final String? detail;

  @override
  String toString() =>
      'DiscoveryImportBlockedException(${blocker.name}'
      '${detail == null ? '' : ': $detail'})';
}

sealed class DiscoveryImportPlan {
  const DiscoveryImportPlan();
}

/// 漫画图包整包导入。
final class ImportMangaArchivePlan extends DiscoveryImportPlan {
  const ImportMangaArchivePlan(this.archivePath);
  final String archivePath;
}

/// 通用压缩包先解压，再对解出的文件树重新分类。
final class ExtractArchivePlan extends DiscoveryImportPlan {
  const ExtractArchivePlan(this.archivePath);
  final String archivePath;
}

/// 多个子计划（一个目录里若干卷）。
final class MultiPlan extends DiscoveryImportPlan {
  const MultiPlan(this.children);
  final List<DiscoveryImportPlan> children;
}

/// 自动导入走不下去。
final class UnsupportedPlan extends DiscoveryImportPlan {
  const UnsupportedPlan(this.blocker);
  final DiscoveryImportBlocker blocker;
}

String _ext(String path) {
  final int dot = path.lastIndexOf('.');
  if (dot < 0 || dot < path.lastIndexOf('/') || dot < path.lastIndexOf('\\')) {
    return '';
  }
  return path.substring(dot).toLowerCase();
}

/// 是否需要先解压。
bool isDiscoveryArchivePath(String path) =>
    kDiscoveryArchiveExtensions.contains(_ext(path));

/// 是否是漫画图包载体。
bool isDiscoveryMangaArchivePath(String path) =>
    kDiscoveryMangaArchiveExtensions.contains(_ext(path));

/// 单个下载文件的分类入口。
DiscoveryImportPlan classifyDiscoveryFile(
  DiscoveryMediaKind kind,
  String filePath,
) {
  if (kind != DiscoveryMediaKind.manga) {
    return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
  }
  // 漫画载体必须**先于**通用解压判定：`.rar`/`.zip` 两边都命中，被通用
  // 解压器截胡就会丢掉包内的 `.mokuro` OCR 层（见
  // [kDiscoveryMangaArchiveExtensions] 的注释）。
  if (isDiscoveryMangaArchivePath(filePath)) {
    return ImportMangaArchivePlan(filePath);
  }
  if (isDiscoveryArchivePath(filePath)) return ExtractArchivePlan(filePath);
  return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
}

/// 解压后的文件树分类（[filePaths] 为递归文件清单，绝对路径）。
///
/// 文件系统的枚举顺序不是稳定输入，而输出顺序是**用户可见**的（逐卷导入的进度
/// 显示与落库次序），所以入口先把清单归一成路径字典序。
DiscoveryImportPlan classifyDiscoveryDirectory(
  DiscoveryMediaKind kind,
  List<String> filePaths, {
  Map<String, int> fileSizes = const <String, int>{},
}) {
  final List<String> paths = List<String>.of(filePaths)..sort();
  if (kind != DiscoveryMediaKind.manga) {
    return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
  }
  // 文件树里的每个图包各自成一卷（种子形态：一个文件夹装若干 cbz）。
  // 散图目录的导入走手动导入对话框的 folder 入口。
  final List<DiscoveryImportPlan> volumes = <DiscoveryImportPlan>[
    for (final String path in paths)
      if (isDiscoveryMangaArchivePath(path)) ImportMangaArchivePlan(path),
  ];
  if (volumes.isEmpty) {
    return const UnsupportedPlan(DiscoveryImportBlocker.unknownFileType);
  }
  if (volumes.length == 1) return volumes.single;
  return MultiPlan(volumes);
}
