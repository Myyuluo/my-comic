import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, immutable, kDebugMode, visibleForTesting;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:my_comic/src/models/app_model.dart';

/// 真应用集成测试的目录选择结果注入；release 构建恒忽略。
@visibleForTesting
String? debugRealDirectoryPathOverride;

/// 「选一个文件夹并返回它的**真实文件系统绝对路径**」的统一入口。
///
/// MyComic 只支持 Windows 桌面，`FilePicker.getDirectoryPath()` 返回的就是真实
/// 文件系统路径，调用方可以直接交给 `dart:io` 使用。
///
/// [dialogTitle] / [initialDirectory] 原样透传。
Future<String?> pickRealDirectoryPath({
  required BuildContext context,
  required AppModel appModel,
  String? dialogTitle,
  String? initialDirectory,
}) async {
  if (kDebugMode && debugRealDirectoryPathOverride != null) {
    return debugRealDirectoryPathOverride;
  }
  return FilePicker.platform.getDirectoryPath(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
}

/// 一次「为导入而选目录」的结果。
///
/// [path] 是要读的那棵树的根。Windows 上始终是用户原始位置的真实路径。
///
/// [stagingRoot] 保留给历史上跨平台 staging 拷贝的调用方契约；Windows 上恒为
/// null（原位路径，不许删）。
@immutable
class PickedImportDirectory {
  const PickedImportDirectory({required this.path, this.stagingRoot});

  /// 要导入的目录树根（绝对路径，`dart:io` 可直接读）。
  final String path;

  /// 暂存拷贝的根；null = [path] 是用户原位目录。
  final Directory? stagingRoot;

  /// 删掉暂存拷贝（原位目录时什么都不做）。
  ///
  /// 删除失败只记诊断不抛：暂存在系统临时目录下，系统会回收；把一次已经成功的导入
  /// 因为清理失败报成失败才是错的。
  Future<void> discardStaging() async {
    final Directory? root = stagingRoot;
    if (root == null) return;
    try {
      if (await root.exists()) await root.delete(recursive: true);
    } on FileSystemException catch (e) {
      debugPrint('[mycomic-import] staging cleanup failed: ${root.path}: $e');
    }
  }
}

/// 目录导入的整卷拷贝失败。Windows 上不会发生，保留类型给导入调用方的 catch
/// 子句继续编译。
class DirectoryImportCopyException implements Exception {
  const DirectoryImportCopyException(this.message);

  /// 原生侧给出的原因（诊断用）。
  final String message;

  @override
  String toString() => 'DirectoryImportCopyException($message)';
}

/// 「选一个目录来**导入**（读内容）」的统一入口。
///
/// Windows 上就是 [pickRealDirectoryPath]；暂存拷贝是已删除移动端平台的旧契约，
/// 这里保留返回类型与 [PickedImportDirectory.stagingRoot]（恒 null）让导入调用方
/// 的清理逻辑无需特判。
///
/// 返回 null = 用户取消。
Future<PickedImportDirectory?> pickImportDirectory({
  required BuildContext context,
  required AppModel appModel,
  required String stagingName,
  String? dialogTitle,
  String? initialDirectory,
}) async {
  final String? path = await pickRealDirectoryPath(
    context: context,
    appModel: appModel,
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
  );
  return path == null ? null : PickedImportDirectory(path: path);
}

/// 「选一个**文件**并返回它的真实文件系统绝对路径」的统一入口。
///
/// Windows 上 `FilePicker.pickFiles()` 返回真实路径、不复制。本入口只丢弃出处，
/// 不承诺返回路径可长期引用；需要出处时用 [pickRealFilePathDetailed]。
///
/// [allowedExtensions] 为不带点的小写扩展名集；null = 不过滤。
Future<String?> pickRealFilePath({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  try {
    final PickedFilePath? picked = await pickRealFilePathDetailed(
      context: context,
      appModel: appModel,
      allowedExtensions: allowedExtensions,
    );
    return picked?.path;
  } on PickedFileWithoutPathException {
    // 本入口的既有契约是「拿不到就返回 null」，既有调用方并不 catch。
    return null;
  }
}

/// 平台交回了条目、却没有一条带可用路径。
///
/// 与「用户取消」必须区分（BUG-446）：取消是静默返回，这个是**失败**，调用方要记
/// 诊断并给用户可见反馈。压成同一个 null 就等于把一类失败伪装成一次取消。
class PickedFileWithoutPathException implements Exception {
  const PickedFileWithoutPathException({required this.count});

  /// 平台交回的条目数（用于诊断日志）。
  final int count;

  @override
  String toString() => 'PickedFileWithoutPathException(count: $count)';
}

/// 一次文件选择的结果：路径 **+ 这条路径是不是用户原始位置的真实路径**。
@immutable
class PickedFilePath {
  const PickedFilePath({required this.path, required this.isRealPath});

  /// 选中文件的绝对路径。
  final String path;

  /// Windows 上 `FilePicker` 返回用户原始位置的真实路径，恒为 true。
  final bool isRealPath;
}

/// [pickRealFilePath] 的带出处版本。Windows 上出处恒为 true。
Future<PickedFilePath?> pickRealFilePathDetailed({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  final _RawPickResult raw = await _fallbackPickRaw(
    context: context,
    allowMultiple: false,
    allowedExtensions: allowedExtensions,
  );
  if (raw.rawCount == 0) return null; // 用户取消：静默。
  if (raw.paths.isEmpty) {
    // 平台交回了条目却没有可用 path = 失败，必须可见（BUG-446）。
    if (raw.missingPathCount > 0) {
      throw PickedFileWithoutPathException(count: raw.rawCount);
    }
    return null;
  }
  return PickedFilePath(path: raw.paths.first, isRealPath: true);
}

/// 「选一个文件、走系统文件选择器，返回其路径」。
///
/// [allowedExtensions] 为不带点的小写扩展名集；null = 不过滤。
Future<String?> pickSystemFilePath({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) =>
    _fallbackPickFile(context: context, allowedExtensions: allowedExtensions);

/// [pickSystemFilePath] 的多选版。返回列表恒可增长（BUG-1574 纪律）。
Future<List<String>> pickSystemFilePaths({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) =>
    _fallbackPickFiles(
      context: context,
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
    );

/// 平台安全的「按扩展名选文件」，语义等同
/// `FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: …)`。
Future<FilePickerResult?> pickFilesByExtensions({
  required BuildContext? context,
  Iterable<String>? allowedExtensions,
  bool allowMultiple = false,
  bool withData = false,
  String? dialogTitle,
  String? initialDirectory,
}) {
  final Set<String> extensions = _normalizeExtensions(allowedExtensions);
  return FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
    type: extensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: extensions.isEmpty ? null : extensions.toList(),
    allowMultiple: allowMultiple,
    withData: withData,
  );
}

/// 「选多个文件并返回真实文件系统绝对路径」。
///
/// 🔴 **每条返回路径都必须是可增长（growable）的 [List]**，包括「用户取消」
/// 「页面已销毁」这类空结果。Dart 的编译期常量列表是 `UnmodifiableListMixin`，
/// 调用方拿到后先就地 `sort` 再判空（BUG-1574）。
Future<List<String>> pickRealFilePaths({
  required BuildContext context,
  required AppModel appModel,
  Set<String>? allowedExtensions,
}) async {
  if (!context.mounted) return <String>[];
  return _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: true,
  );
}

/// 回退到 file_picker 选单个文件。
Future<String?> _fallbackPickFile({
  required BuildContext context,
  Set<String>? allowedExtensions,
}) async {
  final List<String> paths = await _fallbackPickFiles(
    context: context,
    allowedExtensions: allowedExtensions,
    allowMultiple: false,
  );
  return paths.isEmpty ? null : paths.single;
}

/// 回退到 file_picker 选文件。
Future<List<String>> _fallbackPickFiles({
  required BuildContext context,
  required bool allowMultiple,
  Set<String>? allowedExtensions,
}) async =>
    (await _fallbackPickRaw(
      context: context,
      allowMultiple: allowMultiple,
      allowedExtensions: allowedExtensions,
    ))
        .paths;

/// [_fallbackPickRaw] 的返回：可用路径 + 平台**原始**交回情况。
class _RawPickResult {
  const _RawPickResult({
    required this.paths,
    required this.rawCount,
    required this.missingPathCount,
  });

  /// 扩展名过滤后的可用绝对路径。
  final List<String> paths;

  /// 平台交回的条目数（含没有 path 的）；0 = 用户取消。
  final int rawCount;

  /// 交回的条目里没有 path 的条目数。
  final int missingPathCount;
}

Future<_RawPickResult> _fallbackPickRaw({
  required BuildContext context,
  required bool allowMultiple,
  Set<String>? allowedExtensions,
}) async {
  final Set<String> normalizedExtensions = _normalizeExtensions(
    allowedExtensions,
  );
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: normalizedExtensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: normalizedExtensions.isEmpty
        ? null
        : normalizedExtensions.toList(),
    allowMultiple: allowMultiple,
  );

  // 不写 `const <PlatformFile>[]`：本文件按 BUG-1574 的纪律一律不产出不可变集合
  // （守卫 real_path_picker_growable_test 整文件盲扫）。`.toList()` 本身可增长。
  final List<PlatformFile> files = result?.files ?? <PlatformFile>[];
  final int rawCount = files.length;
  final int missingPathCount =
      files.where((PlatformFile f) => f.path == null).length;
  final List<String> paths =
      files.map((PlatformFile file) => file.path).whereType<String>().toList();
  return _RawPickResult(
    paths: paths,
    rawCount: rawCount,
    missingPathCount: missingPathCount,
  );
}

Set<String> _normalizeExtensions(Iterable<String>? extensions) {
  // 同上：本文件不向外交出不可变集合（零特例，省得下一个消费方 add 时再炸一次）。
  if (extensions == null || extensions.isEmpty) return <String>{};
  return extensions
      .map((String ext) => ext.toLowerCase().replaceFirst('.', ''))
      .where((String ext) => ext.isNotEmpty)
      .toSet();
}
