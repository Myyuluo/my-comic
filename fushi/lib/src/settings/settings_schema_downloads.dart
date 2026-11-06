
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/module_registry.dart';

import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:fushi/utils.dart';

/// my-comic：设置里的「下载」只保留漫画下载相关的设备级配置（数据存储位置）。
/// torrent / 磁力 / qBittorrent / 路径映射 / 在线服务等 BT 与视频下载配置已随
/// 非漫画域移除；章节下载本身在「浏览 › 下载」页里。
SettingsDestination buildDownloadsDestination() => SettingsDestination(
  id: SettingsDestinationId.downloads,
  visible: (SettingsContext context) => isSettingsDestinationVisible(
    SettingsDestinationId.downloads,
    context.appModel.moduleVisibility,
  ),
  title: t.nav_downloads,
  summary: t.download_settings,
  icon: FushiIcons.download,
  sections: <SettingsSection>[buildDataStorageLocationSection()],
);
