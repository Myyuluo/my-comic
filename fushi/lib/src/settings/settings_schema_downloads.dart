import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:fushi/utils.dart';

QbConnectionConfig _config(SettingsContext context) =>
    effectiveTorrentConfig(context.appModel.qbConnectionConfig);

bool _embedded(SettingsContext context) =>
    _config(context).resolveBackend(
      embeddedSupported: context.appModel.supportsEmbeddedTorrent,
    ) ==
    QbConnectionConfig.backendEmbedded;

SettingsBodySearchEntry _entry(
  String key,
  String title, {
  SettingsVisibility? visible,
}) => SettingsBodySearchEntry(
  id: 'downloads.$key',
  title: title,
  visible: visible,
  hasRevealTarget: true,
);

SettingsDestination _torrentPage(
  TorrentSettingsScope scope,
  String title,
  List<SettingsBodySearchEntry> entries,
) => SettingsDestination(
  id: SettingsDestinationId.downloads,
  title: title,
  icon: FushiIcons.download,
  sections: const <SettingsSection>[],
  bodySearchEntries: entries,
  // 组件自己产出多个真正的设置分组（MD3 分段卡 / Apple inset grouped），
  // 不再整块塞进一个外层分组。
  body: (_) => TorrentSettingsSection(scope: scope),
);

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
