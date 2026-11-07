import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/content_root_validation.dart';

/// Content root switch 的拒绝原因（storage-layout 票 08）。
///
/// spec 的校验口径：绝对路径、可写、不是安装目录 / 不在安装目录内 / 不是安装目录的
/// 祖先、不在 Program state root 内。校验实现见 [ContentRootTargetValidator]，
/// 与启动期校验共用同一份规则。
enum ContentRootSwitchFailure {
  notAbsolute,
  installDirectory,
  insideProgramStateRoot,
  notWritable,
  preferenceWriteFailed,
}

/// 一次 Content root switch 的结果。
class ContentRootSwitchResult {
  const ContentRootSwitchResult.success(Directory this.contentRoot)
    : failure = null;

  const ContentRootSwitchResult.failure(ContentRootSwitchFailure this.failure)
    : contentRoot = null;

  /// 成功时的新 Content root（规范化的绝对路径）。
  final Directory? contentRoot;

  /// 失败原因；成功时为 null。
  final ContentRootSwitchFailure? failure;

  bool get succeeded => failure == null;
}

/// 切换 Content root（ADR 0011 / GLOSSARY「Content root switch」）。
///
/// 只做三件事：
///  1. 校验目标位置（绝对、可写、不碰安装目录与 Program state root）；
///  2. 在目标根下创建 `downloads` / `autobackup` / `localcomic` 三个空目录；
///  3. 写入 `content_root` 偏好（目标就是当前用户默认根时改为删除偏好）。
///
/// **不**移动 / 复制 / 删除任何用户文件，**不**重基数据库里记录的路径。旧路径下
/// 的下载与本地漫画因此在下次解析时自然变成 Missing，直到用户自己搬移文件并运行
/// Rebuild download index。
class ContentRootSwitch {
  const ContentRootSwitch({
    required this.programStateRoot,
    required this.defaultContentRoot,
    required this.executablePath,
  });

  /// Program state root：目标不得位于其中。
  final Directory programStateRoot;

  /// 当前用户的默认 Content root（`<Documents>/MyComic`）。目标等于它时清除
  /// `content_root` 偏好，让 portable rebase 继续按默认根处理。
  final Directory defaultContentRoot;

  /// 正在运行的 exe 路径；目标不得是安装目录、安装目录内部或它的祖先。
  final String executablePath;

  Future<ContentRootSwitchResult> switchTo(String targetPath) async {
    final ContentRootValidationFailure? invalid =
        await ContentRootTargetValidator(
          programStateRoot: programStateRoot,
          executablePath: executablePath,
        ).validate(targetPath);
    if (invalid != null) {
      return ContentRootSwitchResult.failure(_switchFailureFor(invalid));
    }
    final String target = p.canonicalize(targetPath.trim());

    try {
      for (final String name in <String>[
        AppPaths.downloadsDirName,
        AppPaths.autobackupDirName,
        AppPaths.localComicDirName,
      ]) {
        final Directory dir = Directory(p.join(target, name));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
      }
    } on FileSystemException {
      return const ContentRootSwitchResult.failure(
        ContentRootSwitchFailure.notWritable,
      );
    }

    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool isDefault = p.equals(
        target,
        p.canonicalize(defaultContentRoot.path),
      );
      final bool stored = isDefault
          ? await prefs.remove(AppPaths.contentRootPrefKey)
          : await prefs.setString(AppPaths.contentRootPrefKey, target);
      if (!stored) {
        return const ContentRootSwitchResult.failure(
          ContentRootSwitchFailure.preferenceWriteFailed,
        );
      }
    } catch (_) {
      return const ContentRootSwitchResult.failure(
        ContentRootSwitchFailure.preferenceWriteFailed,
      );
    }

    return ContentRootSwitchResult.success(Directory(target));
  }

  static ContentRootSwitchFailure _switchFailureFor(
    ContentRootValidationFailure failure,
  ) => switch (failure) {
    ContentRootValidationFailure.notAbsolute =>
      ContentRootSwitchFailure.notAbsolute,
    ContentRootValidationFailure.installDirectory =>
      ContentRootSwitchFailure.installDirectory,
    ContentRootValidationFailure.insideProgramStateRoot =>
      ContentRootSwitchFailure.insideProgramStateRoot,
    ContentRootValidationFailure.notWritable =>
      ContentRootSwitchFailure.notWritable,
  };
}
