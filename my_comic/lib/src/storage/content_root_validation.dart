import 'dart:io';

import 'package:path/path.dart' as p;

/// 一个候选 Content root 不满足 spec 校验口径的原因。
///
/// spec：绝对路径、可写、不是安装目录、不在安装目录内、不是安装目录的祖先、
/// 不在 Program state root 内。
enum ContentRootValidationFailure {
  notAbsolute,
  installDirectory,
  insideProgramStateRoot,
  notWritable,
}

/// Content root 目标校验的**唯一实现**。
///
/// 两条入口共用同一套规则，避免「切换时校验、启动时放过」的漂移：
///  - 用户在设置里切换 Content root（[ContentRootSwitch]）；
///  - 启动时读取已保存的 `content_root` 偏好（`AppPaths.resolve`）。
///
/// 校验会真实建目录并写探针文件确认可写（探针用完即删），因此调用方必须先确认
/// 目标存在（启动路径的「不可达 → 逃生屏」语义不能被这里改成静默新建空库）。
class ContentRootTargetValidator {
  const ContentRootTargetValidator({
    required this.programStateRoot,
    required this.executablePath,
  });

  /// Program state root：目标不得位于其中。
  final Directory programStateRoot;

  /// 正在运行的 exe 路径；目标不得是安装目录、安装目录内部或它的祖先。
  final String executablePath;

  /// 校验 [targetPath]；返回 null = 通过。
  Future<ContentRootValidationFailure?> validate(String targetPath) async {
    final String raw = targetPath.trim();
    if (raw.isEmpty || !p.isAbsolute(raw)) {
      return ContentRootValidationFailure.notAbsolute;
    }
    final String target = p.canonicalize(raw);

    if (executablePath.trim().isNotEmpty) {
      final String installDirectory = p.canonicalize(p.dirname(executablePath));
      // 目标 = 安装目录、在安装目录内部、或是安装目录的祖先都不行。
      if (isSameOrWithin(installDirectory, target) ||
          isSameOrWithin(target, installDirectory)) {
        return ContentRootValidationFailure.installDirectory;
      }
    }

    if (isSameOrWithin(programStateRoot.path, target)) {
      return ContentRootValidationFailure.insideProgramStateRoot;
    }

    if (!await probeWritable(target)) {
      return ContentRootValidationFailure.notWritable;
    }
    return null;
  }

  /// [candidate] 是否等于 [root] 或位于 [root] 之下（大小写按平台语义）。
  static bool isSameOrWithin(String root, String candidate) {
    final String canonicalRoot = p.canonicalize(root);
    final String canonicalCandidate = p.canonicalize(candidate);
    return p.equals(canonicalRoot, canonicalCandidate) ||
        p.isWithin(canonicalRoot, canonicalCandidate);
  }

  /// 真实建目录并写一个探针文件确认可写；探针用完即删。
  static Future<bool> probeWritable(String target) async {
    try {
      final Directory dir = Directory(target);
      await dir.create(recursive: true);
      final File probe = File(
        p.join(target, '.my_comic_content_root_probe_$pid'),
      );
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
