import 'package:fushi/src/backup_import/mihon_backup_import_flow.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/module_registry.dart';

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_rebuild_index.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/utils.dart';

/// my-comic：设置里的「存储与下载」只保留漫画下载相关的设备级配置。
///
/// 分组顺序（ticket 03/08）：数据存储位置 → 下载 → 备份 → 下载索引。`存储位置`
/// （Content root，行尾「变更文件夹」/「打开文件夹」）与 `程序数据位置`
/// （Program state root，只读）来自共享的 [buildContentRootsSection]；「下载」是
/// 保存为CBZ压缩包开关（ticket 08）；备份分组整组从「系统与关于」搬入；切换
/// Content root 只创建空文件夹，不搬移文件、不弹迁移/重建提示。Ticket 09 追加
/// 「重建下载索引」小节（确认 → 进度/取消 → 摘要）。
///
/// 2026-11-08：「导入本地漫画」小节随批量导入退役删除——本地漫画改由图源列表里的
/// 「本地图源」按部登记（ADR 0013 的原地读取约束不变）。章节下载本身在「下载」页里。
///
/// 分类标题、副标题均取自字符串资源；它与浏览模块的显隐无关（见
/// `module_registry.dart` 的归属表），始终可见。
SettingsDestination buildDownloadsDestination() => SettingsDestination(
  id: SettingsDestinationId.downloads,
  visible: (SettingsContext context) => isSettingsDestinationVisible(
    SettingsDestinationId.downloads,
    context.appModel.moduleVisibility,
  ),
  title: t.settings_destination_downloads,
  summary: t.download_settings,
  icon: FushiIcons.download,
  sections: <SettingsSection>[
    buildContentRootsSection(),
    buildDownloadBehaviorSection(),
    buildMihonBackupSection(),
    buildRebuildDownloadIndexSection(),
  ],
);

/// 「下载」分组（ticket 08）：下载行为开关，位于数据存储位置与备份之间。
///
/// 只放「保存为CBZ压缩包」：开启时新开始的在线章节下载写成
/// `downloads/{source}/{manga}/{chapter}.cbz`，关闭沿用文件夹。开关只影响任务
/// **开始运行时**读取的值——运行中的任务保持其格式，已有章节不转换。
SettingsSection buildDownloadBehaviorSection() {
  return SettingsSection(
    id: 'downloads.section.download',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.settings_section_download,
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'downloads.save_as_cbz',
        title: t.download_save_as_cbz_title,
        subtitle: t.download_save_as_cbz_subtitle,
        icon: FushiIcons.download,
        value: (SettingsContext context) => context.appModel.downloadSaveAsCbz,
        onChanged: (SettingsContext context, bool value) =>
            context.appModel.setDownloadSaveAsCbz(value),
        defaultValue: true,
      ),
    ],
  );
}

/// 备份分组（ticket 03）：整组从「系统与关于」搬入「存储与下载」。
///
/// 条目文案、启用/置灰状态、导入文件选择器的默认目录（Backup directory，
/// 见 [mihonBackupPickerInitialDirectory]）均不变。item / section id 沿用
/// `system.*`：它们是设置搜索锚点与控制通道键的稳定身份，不随展示位置改变。
///
/// my-comic：Mihon v0.21.3 `.tachibk` Import。Fushi 自己的 `.fushi.zip` 同步与
/// 备份链路随非漫画域一起移除，这里只保留把已有 Mihon Library 带过来的最小入口；
/// 文件只在本机解析与落库，不上传。
SettingsSection buildMihonBackupSection() {
  return SettingsSection(
    id: 'system.section.backup',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.backup_import_mihon_section,
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'system.import_mihon_backup',
        title: t.backup_import_mihon_title,
        subtitle: t.backup_import_mihon_subtitle,
        icon: FushiIcons.restoreBackup,
        cli: const SettingsCliAction.unsupported(
          'The backup file is chosen from the app window: '
          'Settings → Storage & downloads → Backup → Import Mihon backup.',
        ),
        onTap: runMihonBackupImport,
      ),
      // `.tachibk` 导出在 v1.5 交付（ADR 0005）；入口先展示但置灰，
      // 让用户知道 Backup 会从这里走，同时不给出半成品动作。
      SettingsActionItem(
        id: 'system.export_mihon_backup',
        title: t.backup_export_mihon_title,
        subtitle: t.backup_export_mihon_subtitle,
        icon: FushiIcons.upload,
        enabled: (SettingsContext _) => false,
        cli: const SettingsCliAction.unsupported(
          'Exporting .tachibk backups is not implemented yet '
          '(planned for v1.5).',
        ),
        onTap: (SettingsContext _) {},
      ),
    ],
  );
}
