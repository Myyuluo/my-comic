import 'package:fushi/src/utils/fushi_icons.dart';

import 'package:fushi/src/pages/implementations/storage_usage_view.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/src/storage/storage_usage_actions.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/utils.dart';

/// 「存储」一级设置分类：存储位置（Content root / Program state root 与三个
/// 文件夹入口）+ 磁盘占用总览（每个类目都可展开明细，书/词典可单条删除）+
/// 随包组件展示。模型的选择与下载在「设置 › 模型」（2026-10-13 从这里迁出）。
///
/// my-comic 的设置主页不再列出该分类，但 SRS 备份页仍复用本 destination；
/// 位置小节与「存储与下载」页共用 [buildContentRootsSection]。
///
/// 正文经 [SettingsDestination.body] 逃生口渲染 [StorageUsageView]；取数与所有
/// 删除接线在 [StorageUsageActions]（书 `ReaderFushiSource.deleteBook`、词典
/// `AppModel.deleteDictionary`…，控制通道 `storage.cli.*` 共用同一份），widget
/// 自身零裸磁盘删除。
SettingsDestination buildStorageDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.storage,
    title: t.settings_destination_storage,
    summary: t.settings_destination_storage_summary,
    icon: FushiIcons.sdStorage,
    sections: <SettingsSection>[buildContentRootsSection()],
    // 原语逐个透传收口在 [StorageUsageView.fromActions]，这里不再手写逐参转发
    // （曾漏传 videosProvider / deleteVideo，视频明细在设置页里退回空列表）。
    body: (SettingsContext c) => StorageUsageView.fromActions(
      service: StorageUsageService(),
      actions: StorageUsageActions.of(c),
    ),
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'storage.overview',
        title: t.storage_overview_section,
        subtitle: t.storage_overview_total,
      ),
      SettingsBodySearchEntry(
        id: 'storage.shaders',
        title: t.storage_category_shaders,
        subtitle:
            '${t.storage_modules_anime4k_title} · '
            '${t.storage_shaders_delete_anime4k}',
      ),
      SettingsBodySearchEntry(
        id: 'storage.bundled',
        title: t.storage_bundled_section,
        subtitle: t.storage_bundled_hint,
      ),
    ],
  );
}
