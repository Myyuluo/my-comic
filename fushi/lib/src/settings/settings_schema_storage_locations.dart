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

/// 设置 →「存储与下载」的存储位置小节（ticket 08）。
///
/// 只增加必要文案与入口，复用现有设置行组件与图标（ADR 0008）：
///  - `漫画数据位置`：Content root，可更改；更改只在新位置创建三个空文件夹，
///    不搬移/复制旧文件、不重基库内路径，成功后重启应用生效；
///  - `程序数据位置`：Program state root，只读，使用回退位置时在副标题标注；
///  - `downloads` / `localcomic` / `autobackup` 三个文件夹的打开入口。
///
/// 旧版整目录迁移与「迁移后请重建」提示不在此接入。
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
      ),
      SettingsStatusItem(
        id: 'storage.program_state_root',
        title: t.data_storage_program_state_root_title,
        icon: FushiIcons.folder,
        // 只读：没有 actionLabel / onAction。
        subtitleBuilder: _programStateRootSubtitle,
      ),
      for (final ContentRootFolder folder in ContentRootFolder.values)
        SettingsStatusItem(
          id: _folderItemId(folder),
          title: _folderTitle(folder),
          icon: FushiIcons.folderOpen,
          subtitleBuilder: (SettingsContext ctx) =>
              _folderSubtitle(ctx, folder),
          actionLabel: t.data_storage_open_button,
          onAction: (SettingsContext ctx) => _openFolder(ctx, folder),
        ),
    ],
  );
}

/// Content root（用户可见的漫画内容根）下的三个可打开文件夹。
enum ContentRootFolder { downloads, localComic, autobackup }

/// 测试缝：替换「在文件管理器里打开目录」；null = 生产实现。
@visibleForTesting
Future<bool> Function(String path)? debugOpenContentRootDirectory;

String _folderItemId(ContentRootFolder folder) => switch (folder) {
  ContentRootFolder.downloads => 'storage.open_downloads',
  ContentRootFolder.localComic => 'storage.open_local_comic',
  ContentRootFolder.autobackup => 'storage.open_autobackup',
};

String _folderTitle(ContentRootFolder folder) => switch (folder) {
  ContentRootFolder.downloads => t.data_storage_open_downloads_title,
  ContentRootFolder.localComic => t.data_storage_open_local_comic_title,
  ContentRootFolder.autobackup => t.data_storage_open_autobackup_title,
};

/// 当前运行中的 [AppPaths]；设置页最早也只在初始化之后可达，但测试 / 极端早期
/// 可能尚未注入，读不到时返回 null（副标题留空，不崩）。
AppPaths? _pathsOrNull(SettingsContext ctx) {
  try {
    return ctx.appModel.appPaths;
  } on Error {
    return null;
  }
}

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

String? _folderSubtitle(SettingsContext ctx, ContentRootFolder folder) {
  final AppPaths? paths = _pathsOrNull(ctx);
  if (paths == null) return null;
  return switch (folder) {
    ContentRootFolder.downloads => paths.downloadsRoot.path,
    ContentRootFolder.localComic => paths.localComicRoot.path,
    ContentRootFolder.autobackup => paths.autobackupRoot.path,
  };
}

Future<Directory> _folderDirectory(
  SettingsContext ctx,
  ContentRootFolder folder,
) async {
  final AppPaths? paths = _pathsOrNull(ctx);
  if (paths != null) {
    return switch (folder) {
      ContentRootFolder.downloads => paths.downloadsRoot,
      ContentRootFolder.localComic => paths.localComicRoot,
      ContentRootFolder.autobackup => paths.autobackupRoot,
    };
  }
  return switch (folder) {
    ContentRootFolder.downloads => AppPaths.downloadsRootDirectory(),
    ContentRootFolder.localComic => AppPaths.localComicRootDirectory(),
    ContentRootFolder.autobackup => AppPaths.autobackupRootDirectory(),
  };
}

Future<bool> _openContentRootFolder(
  SettingsContext ctx,
  ContentRootFolder folder,
) async {
  final Directory directory = await _folderDirectory(ctx, folder);
  final Future<bool> Function(String path) opener =
      debugOpenContentRootDirectory ?? openDirectoryInFileManager;
  return opener(directory.path);
}

Future<void> _openFolder(SettingsContext ctx, ContentRootFolder folder) async {
  final bool opened = await _openContentRootFolder(ctx, folder);
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
  final Directory currentContentRoot =
      paths?.contentRoot ?? await AppPaths.contentRootDirectory();
  final Directory programStateRoot =
      paths?.programStateRoot ?? await AppPaths.programStateRootDirectory();
  final Directory defaultContentRoot =
      await AppPaths.defaultContentRootDirectory();
  return ContentRootSwitch(
    currentContentRoot: currentContentRoot,
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
