import 'package:my_comic/src/backup_import/mihon_backup_import_flow.dart';
import 'package:my_comic/src/pages/implementations/create_backup_page.dart';
import 'package:my_comic/src/settings/settings_actions.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/src/models/module_registry.dart';

import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/settings/settings_destination.dart';
import 'package:my_comic/src/settings/settings_schema_rebuild_index.dart';
import 'package:my_comic/src/settings/settings_schema_storage_locations.dart';
import 'package:my_comic/utils.dart';

/// my-comic：设置里的「存储与下载」只保留漫画下载相关的设备级配置。
///
/// 分组顺序（ticket 06）：数据存储位置 → 备份索引 → 下载。`存储位置`
/// （Content root，行尾「变更文件夹」/「打开文件夹」）与 `程序数据位置`
/// （Program state root，只读）来自共享的 [buildContentRootsSection]；「备份索引」
/// 把原独立的备份与下载索引两个分组合并为一组（导入、创建、重建、检索），
/// 备份行在所有平台可见，重建/检索仍只在桌面显示；「下载」是保存为CBZ压缩包
/// 开关（ticket 08），移到备份索引之后。切换 Content root 只创建空文件夹，
/// 不搬移文件、不弹迁移/重建提示。
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
  icon: MyComicIcons.download,
  sections: <SettingsSection>[
    buildContentRootsSection(),
    buildBackupIndexSection(),
    buildDownloadBehaviorSection(),
  ],
);

/// 「下载」分组（ticket 08 / 06）：下载行为开关，位于备份索引之后。
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
        icon: MyComicIcons.download,
        value: (SettingsContext context) => context.appModel.downloadSaveAsCbz,
        onChanged: (SettingsContext context, bool value) =>
            context.appModel.setDownloadSaveAsCbz(value),
        defaultValue: true,
      ),
    ],
  );
}

/// 备份索引分组（ticket 03 / ticket 06）：备份与下载索引合并为一个分组。
///
/// 保留稳定 section id `system.section.backup`（设置搜索锚点与控制通道身份
/// 不随展示位置改变），标题改用「备份索引」；组内顺序固定为导入备份、创建备份、
/// 重建下载索引、检索已下载。备份行在移动端仍可见，重建/检索的桌面可见性挂在
/// 各自的 item 上（见 [buildDownloadIndexItems]），不把整组变成桌面专属。
///
/// ticket 06：导入行的标题与副标题使用「导入备份」文案（文件选择框标题复用
/// 同一字符串）。ticket 07：「导出 Mihon 备份」更名为「创建备份」并启用，点击
/// 进入独立创建备份页；导入文件选择器的默认目录（Backup directory，见
/// [mihonBackupPickerInitialDirectory]）不变。item / section id 沿用
/// `system.*`：它们是设置搜索锚点与控制通道键的稳定身份，不随展示位置改变。
///
/// my-comic：Mihon v0.21.3 `.tachibk` Import。MyComic 自己的 `.mycomic.zip` 同步与
/// 备份链路随非漫画域一起移除，这里只保留把已有 Mihon Library 带过来的最小入口；
/// 文件只在本机解析与落库，不上传。
SettingsSection buildBackupIndexSection() {
  return SettingsSection(
    id: 'system.section.backup',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.backup_index_section,
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'system.import_mihon_backup',
        title: t.backup_import_mihon_title,
        subtitle: t.backup_import_mihon_subtitle,
        icon: MyComicIcons.restoreBackup,
        cli: const SettingsCliAction.unsupported(
          'The backup file is chosen from the app window: '
          'Settings → Storage & downloads → Backup index → Import backup.',
        ),
        onTap: runMihonBackupImport,
      ),
      // 「创建备份」：进入独立页面，把书架数据导出为 Mihon v0.21.3 可导入
      // 的 `.tachibk`（ADR 0005 的导出交付）。
      SettingsActionItem(
        id: 'system.export_mihon_backup',
        title: t.backup_export_mihon_title,
        subtitle: t.backup_export_mihon_subtitle,
        icon: MyComicIcons.upload,
        cli: const SettingsCliAction.unsupported(
          'Creating a .tachibk backup saves a file chosen from the app '
          'window: Settings → Storage & downloads → Backup index → '
          'Create backup.',
        ),
        onTap: (SettingsContext context) =>
            pushSettingsPage(context, (_) => const CreateBackupPage()),
      ),
      ...buildDownloadIndexItems(),
    ],
  );
}
