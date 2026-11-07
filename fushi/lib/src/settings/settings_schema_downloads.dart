import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/module_registry.dart';

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_rebuild_index.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/utils.dart';

/// my-comic：设置里的「存储与下载」只保留漫画下载相关的设备级配置。
///
/// Ticket 08 起本页显示 `漫画数据位置`（Content root，可切换）与 `程序数据位置`
/// （Program state root，只读），并提供 `downloads` / `localcomic` / `autobackup`
/// 三个文件夹的打开入口；切换 Content root 只创建空文件夹，不搬移文件、不弹
/// 迁移/重建提示。Ticket 09 追加「重建下载索引」小节（确认 → 进度/取消 → 摘要）。
/// 章节下载本身在「下载」页里。
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
    buildRebuildDownloadIndexSection(),
  ],
);
