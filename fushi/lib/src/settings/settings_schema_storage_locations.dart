import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/content_root_switch.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/reveal_in_file_manager.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载」的存储位置小节（ticket 03）。
///
/// 只保留一个存储入口，复用现有设置行组件与图标（ADR 0008）：
///  - `存储位置`：Content root。整行只读，行尾「变更文件夹」与「打开文件夹」。
///    更改只在新位置创建三个空文件夹，不搬移/复制旧文件、不重基库内路径，
///    成功后重启应用生效；打开使用现有 reveal-in-file-manager 原语，目录不存在
///    时先创建，失败复用现有提示。
///  - `程序数据位置`：Program state root，只读，使用回退位置时在副标题标注。
///
/// 2026-11-08（ticket 03）：移除 downloads / localcomic / autobackup 三个重复的
/// 子文件夹入口。本构建器与 SRS 备份页共用，SRS 上的同名入口同步消失。
SettingsSection buildContentRootsSection() {
  return SettingsSection(
    id: 'storage.location.section',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.settings_section_data_storage,
    footer: t.data_storage_content_root_footer,
    visible: (SettingsContext ctx) => isDesktopPlatform,
    items: <SettingsItem>[
      SettingsStatusItem(
        id: 'storage.content_root',
        title: t.data_storage_content_root_title,
        icon: FushiIcons.folder,
        subtitleBuilder: _contentRootSubtitle,
        actionLabel: t.data_storage_change_button,
        onAction: _changeContentRoot,
        secondaryActionLabel: t.data_storage_open_button,
        secondaryOnAction: _openContentRoot,
      ),
      SettingsStatusItem(
        id: 'storage.program_state_root',
        title: t.data_storage_program_state_root_title,
        icon: FushiIcons.folder,
        // 只读：没有 actionLabel / onAction。
        subtitleBuilder: _programStateRootSubtitle,
      ),
    ],
  );
}

/// 测试缝：替换「在文件管理器里打开目录」；null = 生产实现。
@visibleForTesting
Future<bool> Function(String path)? debugOpenContentRootDirectory;

/// 当前运行中的 [AppPaths]；设置页最早也只在初始化之后可达，但测试 / 极端早期
/// 可能尚未注入，读不到时返回 null（副标题留空，不崩）。
///
/// 走 [AppModel.appPathsOrNull] 的显式就绪标记，不用 `on Error` 吞 `late`
/// 未初始化异常——那会把真正的编程错误一起伪装成「还没注入」。
AppPaths? _pathsOrNull(SettingsContext ctx) => ctx.appModel.appPathsOrNull;

String? _contentRootSubtitle(SettingsContext ctx) =>
    _pathsOrNull(ctx)?.contentRoot.path;

String? _programStateRootSubtitle(SettingsContext ctx) {
  final AppPaths? paths = _pathsOrNull(ctx);
  if (paths == null) return null;
  final String path = paths.programStateRoot.path;
  return paths.programStateRootIsFallback
      ? '$path · ${t.data_storage_program_state_fallback_hint}'
      : path;
}

/// 要打开的 Content root。运行期 [AppPaths] 未就绪时退回静态解析（读同一份
/// `content_root` 偏好），与副标题的空值降级保持同一语义。
Future<Directory> _contentRootDirectory(SettingsContext ctx) async {
  final AppPaths? paths = _pathsOrNull(ctx);
  if (paths != null) return paths.contentRoot;
  return AppPaths.contentRootDirectory();
}

/// 打开 Content root 本身；目录不存在时先创建（否则文件管理器会报错）。
/// 创建或打开任一步失败（只读盘、断链、权限）都复用现有失败提示——异常不能
/// 逃出设置页，否则用户只看到「点了没反应」。
Future<void> _openContentRoot(SettingsContext ctx) async {
  final Future<bool> Function(String path) opener =
      debugOpenContentRootDirectory ?? openDirectoryInFileManager;
  bool opened = false;
  try {
    final Directory directory = await _contentRootDirectory(ctx);
    await directory.create(recursive: true);
    opened = await opener(directory.path);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('ContentRoot.open', error, stack);
    opened = false;
  }
  if (!opened && ctx.context.mounted) {
    FushiToast.show(
      msg: t.data_storage_open_failed,
      severity: ToastSeverity.error,
    );
  }
}

/// 选择新目录 → 校验/建空目录/写偏好 → 重启生效。全程不弹迁移/重建提示。
Future<void> _changeContentRoot(SettingsContext ctx) async {
  final String? picked = await pickRealDirectoryPath(
    context: ctx.context,
    appModel: ctx.appModel,
    dialogTitle: t.data_storage_change_button,
    initialDirectory: _pathsOrNull(ctx)?.contentRoot.path,
  );
  if (picked == null || picked.trim().isEmpty || !ctx.context.mounted) return;

  final ContentRootSwitchResult result = await _switchContentRoot(ctx, picked);
  if (!ctx.context.mounted) return;
  if (!result.succeeded) {
    FushiToast.show(
      msg: _failureMessage(result.failure!),
      severity: ToastSeverity.error,
    );
    return;
  }

  final lifecycle = ctx.appModel.platformServices.lifecycle;
  if (!lifecycle.supportsRestart) {
    FushiToast.show(msg: t.data_storage_switch_restart_required);
    return;
  }
  try {
    await lifecycle.restartApp();
  } catch (_) {
    if (ctx.context.mounted) {
      FushiToast.show(
        msg: t.data_storage_switch_restart_failed,
        severity: ToastSeverity.error,
      );
    }
  }
}

Future<ContentRootSwitchResult> _switchContentRoot(
  SettingsContext ctx,
  String picked,
) async {
  final AppPaths? paths = _pathsOrNull(ctx);
  final Directory programStateRoot =
      paths?.programStateRoot ?? await AppPaths.programStateRootDirectory();
  final Directory defaultContentRoot =
      await AppPaths.defaultContentRootDirectory();
  return ContentRootSwitch(
    programStateRoot: programStateRoot,
    defaultContentRoot: defaultContentRoot,
    executablePath: Platform.resolvedExecutable,
  ).switchTo(picked);
}

String _failureMessage(ContentRootSwitchFailure failure) => switch (failure) {
  ContentRootSwitchFailure.notAbsolute =>
    t.data_storage_switch_failed_not_absolute,
  ContentRootSwitchFailure.installDirectory =>
    t.data_storage_switch_failed_install_dir,
  ContentRootSwitchFailure.insideProgramStateRoot =>
    t.data_storage_switch_failed_program_state,
  ContentRootSwitchFailure.notWritable =>
    t.data_storage_switch_failed_not_writable,
  ContentRootSwitchFailure.preferenceWriteFailed =>
    t.data_storage_switch_failed_preference,
};
