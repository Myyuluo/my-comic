import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_exit_app/flutter_exit_app.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_registry.dart';

import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_actions.dart' show pushSettingsPage;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart'
    show buildLookupDestination;
import 'package:fushi/src/settings/settings_search.dart'
    show SettingsSearchReveal;
import 'package:fushi/src/startup/media_handle_registry.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi/src/storage/macos_data_root_access.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart'
    show BackupMergePreview;
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/backup_validating_overlay_route.dart';
import 'package:fushi/src/sync/desktop_oauth.dart'
    show DesktopOAuthLaunch, DesktopOAuthLaunchObserver;
import 'package:fushi/src/sync/desktop_oauth_wait_dialog.dart';
import 'package:fushi/src/sync/dropbox_sync_backend.dart';
import 'package:fushi/src/sync/ftp_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_host_update_tile.dart';
import 'package:fushi/src/updates/host_self_update_service.dart'
    show hostRemoteUpdatePlatformSupported;
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/remote_book_client.dart' show RemoteBookClient;
import 'package:fushi/src/sync/hidden_remote_books.dart'
    show remoteBookSourceHost, resolveShelfRemoteBookClient;
import 'package:fushi/src/pages/implementations/hidden_remote_books_page.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/sync/interconnect_device_name.dart';
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/interconnect_p2p.dart'
    show InterconnectP2pRuntime, parseInterconnectP2pUrl;
import 'package:fushi/src/sync/interconnect_p2p_path_badge.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/onedrive_sync_backend.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/src/sync/lan_discovery_service.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_v2_client.dart';
import 'package:fushi_engine/sync/pairing/fushi_ping_client.dart';
import 'package:fushi_engine/sync/pairing/discovered_pairing_probe.dart';
import 'package:fushi/src/sync/sftp_sync_backend.dart';
import 'package:fushi_engine/sync/tls/fushi_pinning_http.dart'
    show fingerprintEquals;
import 'package:fushi_engine/sync/tls/fushi_tofu_probe.dart';
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';
import 'package:fushi/src/sync/sync_error_messages.dart';
import 'package:fushi/src/sync/sync_progress.dart';
import 'package:fushi/src/sync/sync_message_dialog.dart';
import 'package:fushi/src/sync/sync_orchestrator.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi/src/sync/webdav_sync_backend.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_platform/fushi_platform.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:fushi_engine/utils/net/url_input_normalizer.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// [summarizeSyncReport] 的实现搬去了 manual_sync_ui.dart（媒体页下拉同步共用），
/// 这里再导出一次以保持既有导入点（test/sync/sync_summary_test.dart）不变。
export 'package:fushi/src/sync/manual_sync_ui.dart' show summarizeSyncReport;

part 'sync_settings_schema/account.part.dart';
part 'sync_settings_schema/backend_config.part.dart';
part 'sync_settings_schema/interconnect.part.dart';
part 'sync_settings_schema/interconnect_link.part.dart';
part 'sync_settings_schema/actions.part.dart';
part 'sync_settings_schema/backup.part.dart';
part 'sync_settings_schema/data_root.part.dart';

SettingsDestination buildSyncBackupDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.syncBackup,
    // my-comic 保留本地备份导入/导出；云同步、Fushi Server 与互联已移除，
    // 因此本分类不再受 sync 模块门控。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.syncBackup,
      c.appModel.moduleVisibility,
    ),
    title: t.settings_destination_sync_backup,
    summary: t.sync_summary,
    icon: FushiIcons.sync,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'sync.backup.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.sync_section_backup,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.backup_export',
            icon: FushiIcons.upload,
            builder: (SettingsContext ctx) =>
                _BackupExportWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.backup_import',
            icon: FushiIcons.download,
            builder: (SettingsContext ctx) =>
                _BackupImportWidget(settingsContext: ctx),
          ),
        ],
      ),
    ],
  );
}

/// 凭据式后端（WebDAV / FTP / SFTP）才有「服务器设置」子页；OAuth 后端在浏览器
/// 里登录（账号行），互联的连接配置在自己的分类里。
@visibleForTesting
bool hasServerSettings(SyncBackendType type) =>
    type == SyncBackendType.webDav ||
    type == SyncBackendType.ftp ||
    type == SyncBackendType.sftp;

/// 「服务器设置」子页（C1）：所选后端的凭据表单 + 连接测试。三套表单及其可见性
/// 谓词与原先在主页「同步方式」节里时逐字相同，只是搬了个地方。子页共用父分类的
/// id、靠闭包取新鲜树（见 [SettingsNavigationItem.child]）；零参、构造期只读
/// i18n 常量，与顶层分类同一条 schema 缓存纪律。
SettingsDestination _buildSyncServerSettingsPage() {
  return SettingsDestination(
    id: SettingsDestinationId.syncBackup,
    title: t.sync_server_settings,
    icon: FushiIcons.server,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'sync.webdav.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.webdav_config',
            icon: FushiIcons.server,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.webDav,
            builder: (SettingsContext ctx) =>
                _WebDavConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.ftp_config',
            icon: FushiIcons.server,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.ftp,
            builder: (SettingsContext ctx) =>
                _FtpConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.sftp_config',
            icon: FushiIcons.server,
            visible: (SettingsContext ctx) =>
                _syncSettings(ctx).backendType == SyncBackendType.sftp,
            builder: (SettingsContext ctx) =>
                _SftpConfigWidget(settingsContext: ctx),
          ),
        ],
      ),
    ],
  );
}

/// Fushi 互联独立一级分类：设备直连（client 连接配置 + LAN 发现）与本机作为
/// 服务器（host 模式）。与 [buildSyncBackupDestination] 同库定义，共享
/// `_syncSettings` 私有状态与全部互联 widget；配置区可见性仍以「互联被选为
/// 同步方式」门控（与拆分前在同步分类内的行为一致，零行为变化），未启用时
/// 只显示一行指引说明去哪里启用。
SettingsDestination buildInterconnectDestination() {
  bool interconnectActive(SettingsContext ctx) =>
      _syncSettings(ctx).interconnectEnabled;
  return SettingsDestination(
    id: SettingsDestinationId.interconnect,
    // 「功能模块」门控：关掉本模块 = 整条分类不渲染 / 不进搜索索引 / 主从详情不可选
    // （三条渲染路径共用 isVisible）。归属表见 module_registry.dart，别在此另写判据。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.interconnect,
      c.appModel.moduleVisibility,
    ),
    title: t.settings_destination_interconnect,
    summary: t.interconnect_summary,
    icon: FushiIcons.devices,
    sections: <SettingsSection>[
      // 互联总开关（独立于云备份后端，二者可并存）。开关常显；关闭时下方配置区隐藏，
      // 副标题说明互联与云同步互不排斥。footer 用一句话讲清角色模型（哪台开服务器、
      // 哪台连接、角色互斥）——此前整页没有任何地方交代这一点，用户面对平铺的
      // client/host 两大区不知道该在哪台设备上动哪个开关。
      SettingsSection(
        id: 'interconnect.enabled.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        footer: t.interconnect_enable_footer,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.enabled',
            title: t.interconnect_enable,
            subtitle: t.interconnect_enable_hint,
            icon: FushiIcons.hub,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectEnabled,
            onChanged: (SettingsContext ctx, bool value) =>
                _syncSettings(ctx).setInterconnectEnabled(value),
          ),
        ],
      ),
      // 连接到其他设备：client 连接配置（URL/token/配对）+ LAN 自动发现，整块挪进
      // 子页「配对与设备」（C2）——对端列表与 LAN 发现是整页最高的两个 widget，正是
      // BUG-037 说的高度悬殊来源；主页只留一行带实时摘要的入口。
      SettingsSection(
        id: 'interconnect.client.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.interconnect_section_client,
        visible: interconnectActive,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'interconnect.devices',
            title: t.interconnect_devices_page,
            subtitle: t.interconnect_devices_hint,
            // 有对端就报数量，没有就留提示（告诉用户子页里能做什么）。
            subtitleBuilder: (SettingsContext ctx) {
              final int n = _syncSettings(ctx).peerCount;
              return n == 0 ? null : t.interconnect_devices_paired_count(n: n);
            },
            icon: FushiIcons.devices,
            child: _buildInterconnectDevicesPage,
          ),
        ],
      ),
      // BUG-988：上传到互联对端——互联通道专属的「本设备内容要不要上传给对端」分项开关，
      // 独立于云备份的同名开关（那套只管云通道），也独立于上面的「启用互联」连接开关。
      // 默认全关：用户开互联只为远端看/读时不会被自动上传裹挟，想传哪类自己勾。与云备份
      // 上传开关同为 OUTBOUND，host 模式（本机做服务端，client 往它推）无 outbound → 隐藏。
      SettingsSection(
        id: 'interconnect.upload.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.interconnect_upload_section,
        footer: t.interconnect_upload_section_footer,
        visible: (SettingsContext ctx) =>
            interconnectActive(ctx) && !_isHostingInterconnect(ctx),
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.upload_content',
            title: t.interconnect_upload_content,
            subtitle: t.interconnect_upload_content_hint,
            icon: FushiIcons.books,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncContent,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncContent = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectSyncContentEnabled(value);
            },
          ),
          // BUG-2494：互联通道自己一行显式的上传/下载动作，跑在
          // SyncAssetChannelScope.interconnect 上，只碰互联对端、不碰云盘。
          // BUG-2762：这一行是互联页词典的**唯一**入口。以前上面还有一个「上传词典」
          // 自动同步开关，与本行在同一组里并排成两个「词典」，且开关实际驱动的是双向
          // union、文案却是「上传」；现在与云备份页同形——词典只由显式动作搬。
          SettingsCustomItem(
            id: 'interconnect.dictionary_transfer',
            searchTitle: t.sync_asset_dictionary,
            icon: FushiIcons.readingMode,
            builder: (SettingsContext ctx) => _AssetTransferMenuRow(
              settingsContext: ctx,
              kind: SyncAssetKind.dictionary,
              title: t.sync_asset_dictionary,
              icon: FushiIcons.readingMode,
              scope: SyncAssetChannelScope.interconnect,
            ),
          ),
          // 反馈 #5mB56tqXHa：本地音频数据库与词典同属显式搬运——互联协议（live 端点）
          // 早已支持（_syncLocalAudioLive），只是互联页缺这一行入口。
          SettingsCustomItem(
            id: 'interconnect.local_audio_transfer',
            searchTitle: t.sync_asset_local_audio,
            icon: FushiIcons.audio,
            builder: (SettingsContext ctx) => _AssetTransferMenuRow(
              settingsContext: ctx,
              kind: SyncAssetKind.localAudio,
              title: t.sync_asset_local_audio,
              icon: FushiIcons.audio,
              scope: SyncAssetChannelScope.interconnect,
            ),
          ),
          SettingsCustomItem(
            id: 'interconnect.fonts_transfer',
            searchTitle: t.sync_asset_fonts,
            icon: FushiIcons.font,
            builder: (SettingsContext ctx) => _AssetTransferMenuRow(
              settingsContext: ctx,
              kind: SyncAssetKind.fonts,
              title: t.sync_asset_fonts,
              icon: FushiIcons.font,
              scope: SyncAssetChannelScope.interconnect,
            ),
          ),
          SettingsSwitchItem(
            id: 'interconnect.upload_audiobook_files',
            title: t.interconnect_upload_audiobook_files,
            subtitle: t.interconnect_upload_audiobook_files_hint,
            icon: FushiIcons.audiobook,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncAudioBookFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncAudioBookFiles = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectSyncAudioBookFilesEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'interconnect.upload_video_files',
            title: t.interconnect_upload_video_files,
            subtitle: t.interconnect_upload_video_files_hint,
            icon: FushiIcons.video,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncVideoFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncVideoFiles = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectSyncVideoFilesEnabled(value);
            },
          ),
        ],
      ),
      // 与已配对设备共享：统计 + 收藏夹的双向合并开关。刻意**不并进上面的「上传到
      // 互联对端」区块**——那一区是纯 OUTBOUND 的重内容文件、脚注向用户承诺「默认
      // 全部关闭」；这两项是轻量个人数据、双向合并、且默认开启（拆开关前它们本来就
      // 在跟着云备份的「同步统计」无条件流动，只是用户看不见也关不掉）。混在一起会
      // 让那句脚注当场变成假话。
      SettingsSection(
        id: 'interconnect.share.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.interconnect_share_section,
        footer: t.interconnect_share_section_footer,
        visible: (SettingsContext ctx) =>
            interconnectActive(ctx) && !_isHostingInterconnect(ctx),
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.share_statistics',
            title: t.interconnect_share_statistics,
            subtitle: t.interconnect_share_statistics_hint,
            icon: FushiIcons.barChart,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncStats,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncStats = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectSyncStatsEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'interconnect.share_favorites',
            title: t.interconnect_share_favorites,
            subtitle: t.interconnect_share_favorites_hint,
            icon: FushiIcons.star,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectSyncFavorites,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectSyncFavorites = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectSyncFavoritesEnabled(value);
            },
          ),
        ],
      ),
      // 交给已配对设备：本机把某类工作整个甩给对端主机去做。两项都只有 client 角色
      // 讲得通（host 没有「对端」可交），故与上面的上传区同门控——互联启用且本机不在
      // host 模式。
      //   · 制卡到已配对设备：制卡改由主机的 Anki 落卡（原在「制卡」分类，但它的前置
      //     条件、目标设备、失效条件全由互联决定，互联关掉时在制卡页是个纯死开关）。
      //   · 用互联做备份后端：把云备份通道也指向对端（详见 _InterconnectBackupBackendWidget）。
      SettingsSection(
        id: 'interconnect.delegate.section',
        presentation: SettingsSectionPresentation.collapsed,
        title: t.interconnect_section_delegate,
        visible: (SettingsContext ctx) =>
            interconnectActive(ctx) && !_isHostingInterconnect(ctx),
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'interconnect.mine_to_server',
            title: t.anki_mine_to_server,
            subtitle: t.anki_mine_to_server_hint,
            icon: FushiIcons.ankiCard,
            value: (SettingsContext ctx) => ctx.appModel.mineToServerEnabled,
            onChanged: (SettingsContext ctx, bool value) =>
                ctx.appModel.setMineToServer(value),
          ),
          SettingsCustomItem(
            id: 'interconnect.backup_backend',
            icon: FushiIcons.backup,
            builder: (SettingsContext ctx) =>
                _InterconnectBackupBackendWidget(settingsContext: ctx),
          ),
          // apikey 同步设定重设计（2026-08-17）：service-config 接收开关。此前
          // host 的外部服务 API key（Jimaku/TMDB/Torznab/OpenSubtitles/追番）经
          // 互联单向下发是一条**无 UI 无开关**的隐形通道——用户既不知道配对后
          // key 会同步过来，也关不掉。开关落设备本地（信任决策不跨设备跟随），
          // 默认开 = 既有行为不变；关掉只是不再请求，已导入的值不回滚。
          SettingsSwitchItem(
            id: 'interconnect.service_config_sync',
            title: t.sync_interconnect_service_config_toggle,
            subtitle: t.sync_interconnect_service_config_toggle_desc,
            icon: FushiIcons.key,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectServiceConfigSync,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectServiceConfigSync = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectServiceConfigSyncEnabled(value);
            },
          ),
          // 跟随已配对设备自动登录 Fushi 账户（所有者 2026-10-16 拍板：默认开、无按钮无
          // 确认）。仅对把本机标记为「我的设备」的已配对 host 生效（host 侧另有一道门）；
          // 只在本机这个 Profile 从没登录过账户时生效，主动退出过就不再自动登回去。本机
          // 只交出自己新生成的公钥，私钥不经互联。
          SettingsSwitchItem(
            id: 'interconnect.leaderboard_follow_login',
            title: t.interconnect_leaderboard_follow_login_toggle,
            subtitle: t.interconnect_leaderboard_follow_login_toggle_desc,
            icon: FushiIcons.profiles,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).leaderboardFollowPairedLogin,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).leaderboardFollowPairedLogin = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setLeaderboardFollowPairedLoginEnabled(value);
            },
          ),
          // 「配置文件」（Profile）双向搬运：用户诉求是把一台设备调好的配置搬到另一
          // 台，而不是每台重配一遍。做成**一次性动作**而不是自动跟随开关——整份配置
          // 会在对端落一份新 Profile，什么时候搬该由用户在点的那一刻决定（与云通道
          // 那四个资产上传/下载行同一取舍，见 sync.dictionary_upload 附近的说明）。
          // 备份包不走这里：它已有「用互联做备份后端」的既有通道。
          SettingsCustomItem(
            id: 'interconnect.profile_upload',
            searchTitle: t.interconnect_profile_upload,
            icon: FushiIcons.restoreBackup,
            builder: (SettingsContext ctx) =>
                _InterconnectProfileTransferWidget(
                  settingsContext: ctx,
                  direction: _ProfileTransferDirection.upload,
                ),
          ),
          SettingsCustomItem(
            id: 'interconnect.profile_download',
            searchTitle: t.interconnect_profile_download,
            icon: FushiIcons.restoreBackup,
            builder: (SettingsContext ctx) =>
                _InterconnectProfileTransferWidget(
                  settingsContext: ctx,
                  direction: _ProfileTransferDirection.download,
                ),
          ),
          // 主机版本 / 更新主机（反馈 Pp8XPyve0N）：在 client 上就能看到 host 跑的
          // 版本、让它自己下载安装新版。门（host 开关 / 平台 / 局域网 / nonce）全在
          // host 端，这一行只展示状态与 host 给的拒绝原因。
          SettingsCustomItem(
            id: 'interconnect.host_update',
            searchTitle: t.interconnect_host_update_title,
            icon: FushiIcons.server,
            builder: (SettingsContext ctx) => InterconnectHostUpdateTile(
              remote: InterconnectHostUpdateRemote(
                SyncRepository(ctx.appModel.database),
              ),
            ),
          ),
        ],
      ),
      // 本机作为服务器：host 模式（开关 + 端口 + TLS + token + 已配对列表）整块挪进
      // 子页「主机服务」（C2）；主页只留一行带运行状态的入口。角色互斥见
      // _SyncSettingsState 的 roleRevision。
      SettingsSection(
        id: 'interconnect.host.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.sync_section_host_server,
        footer: t.sync_section_host_server_footer,
        visible: interconnectActive,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'interconnect.host',
            title: t.interconnect_host_page,
            subtitle: t.interconnect_host_hint,
            subtitleBuilder: (SettingsContext ctx) {
              final _SyncSettingsState s = _syncSettings(ctx);
              return s.serverEnabled
                  ? t.interconnect_host_running(port: s.serverPort)
                  : t.interconnect_host_off;
            },
            icon: FushiIcons.server,
            child: _buildInterconnectHostPage,
          ),
        ],
      ),
      // 互联相关配置（远端词典查询 / 音频来源 / 远端占位卡）散落在查词、同步分类，
      // 逻辑上都作用于互联对端。此前在这里镜像三行同一 builder；用户拍板（2026-09-06）
      // 改成一行指路——不再重复渲染开关，点进去落到查词分类并定位到远端查词那一行。
      SettingsSection(
        id: 'interconnect.related.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.interconnect_section_related,
        visible: interconnectActive,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'interconnect.related_settings',
            title: t.interconnect_related_entry,
            subtitle: t.interconnect_related_entry_hint,
            icon: FushiIcons.travelExplore,
            onTap: (SettingsContext ctx) async {
              SettingsSearchReveal.pendingItemId = 'lookup.remote_lookup';
              await pushSettingsPage(
                ctx,
                (_) =>
                    SettingsDetailPage(destination: buildLookupDestination()),
              );
            },
          ),
        ],
      ),
    ],
  );
}

/// 「配对与设备」子页（C2）：client 连接配置（URL/token/配对）+ LAN 自动发现，
/// 两个 widget 原样搬入。item id 沿用 'sync.' 前缀（历史命名，非持久化 key，
/// 保持稳定便于排查）。
SettingsDestination _buildInterconnectDevicesPage() {
  return SettingsDestination(
    id: SettingsDestinationId.interconnect,
    title: t.interconnect_devices_page,
    icon: FushiIcons.devices,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'interconnect.server_config.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.fushi_server_config',
            icon: FushiIcons.devices,
            builder: (SettingsContext ctx) =>
                _FushiServerConfigWidget(settingsContext: ctx),
          ),
          SettingsCustomItem(
            id: 'sync.lan_devices',
            icon: FushiIcons.wifi,
            builder: (SettingsContext ctx) =>
                _LanDiscoveryWidget(settingsContext: ctx),
          ),
        ],
      ),
    ],
  );
}

/// 「主机服务」子页（C2）：host 模式开关 + 端口 + TLS + token + 已配对列表，以及
/// host 侧「配置文件」读写许可，原样搬入。
SettingsDestination _buildInterconnectHostPage() {
  return SettingsDestination(
    id: SettingsDestinationId.interconnect,
    title: t.interconnect_host_page,
    icon: FushiIcons.server,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'interconnect.server_mode.section',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        items: <SettingsItem>[
          SettingsCustomItem(
            id: 'sync.server_mode',
            icon: FushiIcons.server,
            builder: (SettingsContext ctx) =>
                _ServerModeWidget(settingsContext: ctx),
          ),
          // host 侧「配置文件」读写许可。默认关：入站写没有显式开关就是一条无 UI 的
          // 隐形通道（BUG-988 立过的规矩），出站同理——整份 Profile 比四个内容上传
          // 开关更敏感。端点另有 TLS + 已配对 peer token 两道门，本开关是用户意图那道。
          SettingsSwitchItem(
            id: 'interconnect.profile_transfer_host',
            title: t.interconnect_profile_host_toggle,
            subtitle: t.interconnect_profile_host_toggle_desc,
            icon: FushiIcons.profiles,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectProfileTransfer,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectProfileTransfer = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectProfileTransferEnabled(value);
            },
          ),
          // 允许已配对设备跟随本机 Fushi 账户自动登录（总闸，默认开，所有者 2026-10-16
          // 拍板）。仅对标记为「我的设备」的已配对设备生效（配对审批选「允许 · 这是我的
          // 设备」或在已配对设备列表里手动标记；升级前配对的设备默认「仅互联」，不追溯
          // 授权）。对端只交来它自己的公钥，由本机账户代绑；本机私钥 / 恢复码从不外传。
          // 端点另有 HTTPS + 已配对 peer token 两道门；本开关关掉 = 403 disabled。
          SettingsSwitchItem(
            id: 'interconnect.leaderboard_link_host',
            title: t.interconnect_leaderboard_link_host_toggle,
            subtitle: t.interconnect_leaderboard_link_host_toggle_desc,
            icon: FushiIcons.profiles,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectLeaderboardLinkHost,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectLeaderboardLinkHost = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectLeaderboardLinkHostEnabled(value);
            },
          ),
          // 远程更新本机许可（反馈 Pp8XPyve0N）。默认关：让别的设备在本机下载安装
          // 可执行文件必须是主人的显式意愿。端点另有已配对 peer token + 局域网信任区
          // + 一次性 nonce 几道门。只在本机能应用内自更新的平台出现（平台门 =
          // PlatformUpdater.supportsInAppInstall，与 host 端点同一个判据）。
          SettingsSwitchItem(
            id: 'interconnect.remote_update_host',
            title: t.interconnect_host_update_host_toggle,
            subtitle: t.interconnect_host_update_host_toggle_desc,
            icon: FushiIcons.server,
            visible: (SettingsContext ctx) =>
                hostRemoteUpdatePlatformSupported(),
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).interconnectRemoteUpdate,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).interconnectRemoteUpdate = value;
              await SyncRepository(
                ctx.appModel.database,
              ).setInterconnectRemoteUpdateEnabled(value);
            },
          ),
        ],
      ),
    ],
  );
}

/// 远端占位卡开关。同步内容分类与 Fushi 互联分类共享同一份定义（单一真相源）：
/// 多端库联合视图（spec 2026-07-12 §2.1/§2.4），书架/视频页主网格是否把「远端有、
/// 本地无」的条目渲染成占位卡（云角标 + 远端封面，点击下载/流播）。纯显示偏好
/// （PreferencesRepository），默认开；关闭时占位卡全部不渲染。离线/未配对/后端不可达
/// 时占位卡本就不出现，与本开关正交。id 沿用 `sync.` 前缀（非持久化 key）。
SettingsItem buildShowRemoteEntriesItem() {
  return SettingsSwitchItem(
    id: 'sync.show_remote_entries',
    title: t.sync_show_remote_entries,
    subtitle: t.sync_show_remote_entries_warning,
    icon: FushiIcons.devices,
    value: (SettingsContext ctx) => ctx.appModel.prefsRepo.showRemoteEntries,
    onChanged: (SettingsContext ctx, bool value) async {
      await ctx.appModel.prefsRepo.setShowRemoteEntries(value);
    },
  );
}

/// 「已从本机移除的远端书」入口的副标题：有记录时带条数。条数与说明的拼法交给各语言
/// 的文案（BUG-3244：以前硬拼 `'$n · 说明'`，数字没有量词、语序也不能按语言调整）。
String hiddenRemoteBooksSubtitle(int n) => n == 0
    ? t.remote_hidden_books_hint
    : t.remote_hidden_books_hint_count(n: n);

/// 「已从本机移除的远端书」找回列表入口，副标题报条数。
SettingsItem buildHiddenRemoteBooksItem() {
  return SettingsNavigationItem(
    id: 'sync.hidden_remote_books',
    title: t.remote_hidden_books_title,
    subtitleBuilder: (SettingsContext ctx) => hiddenRemoteBooksSubtitle(
      ctx.appModel.prefsRepo.hiddenRemoteBooks.length,
    ),
    icon: FushiIcons.visibilityOff,
    onTap: (SettingsContext ctx) => pushSettingsPage(
      ctx,
      (_) => HiddenRemoteBooksPage(
        prefs: ctx.appModel.prefsRepo,
        // 只读核对：不在远端建同步根（BUG-3245）。
        remoteClientLoader: () => resolveShelfRemoteBookClient(
          ctx.appModel.database,
          createRootFolder: false,
        ),
        sourceHostResolver: (RemoteBookClient client) =>
            remoteBookSourceHost(ctx.appModel.database, client),
      ),
    ),
  );
}

// HBK-AUDIT-044: 同步设置的内存态由所有者 AppModel（持有 database）拥有，
// 而不是某个 widget。之前 _activeSyncState 的生命周期挂在 _BackendSelectorWidget
// 上（initState 创建、dispose 置 null），其它开关和 _LanDiscoveryWidget 却共享同一
// 全局；当选择器在 master-detail 宽布局或任意 rebuild 中被 dispose 后重建时，全局被
// 置 null 再用硬编码默认值（googleDrive/autoSync=false/syncStats=true/...）懒重建，
// 在异步 load() 落地前，开关会短暂读到默认值而非持久化值。
//
// 改为按 AppModel 身份缓存：只要数据库实例不变就复用已加载的状态，不再随 widget
// dispose 而失效，从根本上消除 "重建即回退默认值" 的竞态窗口。
_SyncSettingsState? _activeSyncState;
AppModel? _activeSyncOwner;

/// 测试钩子：丢掉按 AppModel 缓存的同步设置内存态，并解除它挂在
/// [SyncRepository.interconnectEnabledRevision] 上的全局监听。每个用例各建一份
/// AppModel + 内存库时，上一份状态的监听会在下一个用例的 setInterconnectEnabled
/// 广播里去读已关闭的库（生产里 AppModel 与库同寿命，不会触发）。
@visibleForTesting
void resetSyncSettingsStateForTest() {
  _activeSyncState?.dispose();
  _activeSyncState = null;
  _activeSyncOwner = null;
}

/// Whether this device is actively HOSTING a Fushi interconnect server — the
/// only role with no outbound "sync now" / "compare" (BUG-084). Requires BOTH
/// the persisted host flag AND interconnect being enabled: a stale serverEnabled
/// left over from a past interconnect session must NOT gate manual sync when
/// interconnect is off (observed in the wild: serverEnabled=true while the user
/// only uses a cloud backend, which would otherwise hide sync-now on the cloud).
bool _isHostingInterconnect(SettingsContext ctx) =>
    _syncSettings(ctx).serverEnabled && _syncSettings(ctx).interconnectEnabled;

/// 云备份通道此刻是否真的没有出站同步（BUG-1088）：仅当「同步方式」本身选的是互联、
/// 且本机正在做互联 host——host 是被动数据源，client 从它拉/往它推，它自己无出站
/// （BUG-084）。云后端（Google Drive/WebDAV/...）的出站与互联 host 身份无关：host
/// 设备照样往云盘备份。旧门控只看 host 身份，把云通道的上传开关、自动同步、立即
/// 同步整排藏掉，是互联还与云备份互斥时代遗留的错误特例。
bool _cloudOutboundUnavailable(SettingsContext ctx) =>
    _syncSettings(ctx).backendType == SyncBackendType.fushiServer &&
    _isHostingInterconnect(ctx);

_SyncSettingsState _syncSettings(SettingsContext ctx) {
  final AppModel owner = ctx.appModel;
  if (_activeSyncState == null || !identical(_activeSyncOwner, owner)) {
    // 换 owner 时先拆掉旧状态挂在 SyncRepository 上的全局监听，否则每换一次
    // AppModel（测试/多 Profile 重建）就永久多一个监听者（BUG-1560）。
    _activeSyncState?.dispose();
    _activeSyncOwner = owner;
    _activeSyncState = _SyncSettingsState(ctx)..load();
  }
  return _activeSyncState!;
}

void _showSnackBar(BuildContext context, String message) {
  showSyncMessage(context, message);
}

class _SyncSettingsState {
  _SyncSettingsState(this._settingsContext)
    : _repo = SyncRepository(_settingsContext.appModel.database) {
    // BUG-1560：互联总开关还有第二个写入口（库页来源视图的互联虚拟来源行）。
    // 本状态按 AppModel 缓存、[load] 一辈子只跑一次，不订阅就永远停在开页那一刻
    // 的值——开关本身和互联各 section 的显隐一起显示旧值，直到重启 app。
    SyncRepository.interconnectEnabledRevision.addListener(
      _onInterconnectEnabledChanged,
    );
  }

  final SettingsContext _settingsContext;
  final SyncRepository _repo;
  SyncBackendType backendType = SyncBackendType.googleDrive;

  /// 「与 Hoshi/ッツ 共享 Google Drive」开关（仅 Google Drive 后端有效）。

  /// 互联总开关（独立于 [backendType] 云备份后端选择）。为 true 时互联作为一条独立
  /// 通道运行，与云备份并存（不再是互斥的 backendType==fushiServer 单选）。
  bool interconnectEnabled = false;
  bool autoSync = false;
  bool syncStats = true;
  bool syncContent = false;
  bool syncAudioBookFiles = false;
  bool syncVideoFiles = false;
  // BUG-988：互联通道专属的「上传内容到对端」开关，独立于上面的云备份 sync* 开关。
  bool interconnectSyncContent = false;
  bool interconnectSyncAudioBookFiles = false;
  bool interconnectSyncVideoFiles = false;
  // 互联专属的「共享统计 / 共享收藏夹」（双向合并，非上传）。默认 true = 拆开关前
  // 由云备份 syncStats 无条件代管时的既有行为。
  bool interconnectSyncStats = true;
  bool interconnectSyncFavorites = true;
  // apikey 同步设定重设计（2026-08-17）：service-config（host 的外部服务 API key）
  // 接收开关。默认 true = 既有行为；此前这条通道无 UI 无开关，用户不可见也关不掉。
  bool interconnectServiceConfigSync = true;

  /// host 侧：是否允许已配对设备读写本机「配置文件」（Profile）。默认 false。
  bool interconnectProfileTransfer = false;

  /// host 侧：是否允许已配对设备跟随本机账户自动登录。默认 true。
  bool interconnectLeaderboardLinkHost = true;

  /// client 侧：本机无账户时是否跟随已配对设备自动登录。默认 true。
  bool leaderboardFollowPairedLogin = true;
  bool interconnectRemoteUpdate = false;
  bool _loaded = false;
  bool _loading = false;

  /// Bumped whenever the persisted Fushi *client* config (URLs / token) is
  /// mutated from outside the client-config widget (e.g. LAN pairing). The
  /// client-config widget listens and reloads — this is the single source of
  /// truth replacing the previous "loaded once in initState" stale state.
  final ValueNotifier<int> clientConfigRevision = ValueNotifier<int>(0);

  /// 主页「配对与设备」入口行的实时摘要（C2）：已配对对端数。随 [load] 读入，
  /// 配对/删除对端后经 [reloadClientConfig] 重读。
  int peerCount = 0;

  /// 主页「主机服务」入口行的实时摘要（C2）：服务端口。随 [load] 读入，改端口
  /// 时由 _ServerModeWidget 就地更新。
  int serverPort = 0;

  void reloadClientConfig() {
    clientConfigRevision.value++;
    unawaited(_reloadPeerCount());
  }

  Future<void> _reloadPeerCount() async {
    final int count = interconnectPeerRepresentatives(
      await _repo.getFushiClientUrls(),
    ).length;
    if (peerCount == count) return;
    peerCount = count;
    _settingsContext.refresh();
  }

  /// Mutual-exclusion role state for the Fushi interconnect: a device may be a
  /// host (server on, others connect to it) OR a client (connected outward to a
  /// peer), never both. The two flags below are the shared truth the server and
  /// client widgets read to gate each other; [roleRevision] notifies on change.
  bool serverEnabled = false;
  bool hasClientConnection = false;
  final ValueNotifier<int> roleRevision = ValueNotifier<int>(0);

  void setServerEnabled(bool value) {
    if (serverEnabled == value) return;
    serverEnabled = value;
    roleRevision.value++;
    // Re-evaluate section/item visibility predicates (the manual-sync actions
    // are gated on serverEnabled, BUG-084) so toggling the host role re-gates
    // them live, not just on the next page open.
    _settingsContext.refresh();
  }

  void setHasClientConnection(bool value) {
    if (hasClientConnection == value) return;
    hasClientConnection = value;
    roleRevision.value++;
  }

  /// 切换互联总开关并持久化，随后刷新可见性谓词（互联各 section 门控于此），让开关
  /// 即时生效而非等下次开页。关闭时不清空已配置的对端/host 设置（用户重新打开即恢复）。
  Future<void> setInterconnectEnabled(bool value) async {
    if (interconnectEnabled == value) return;
    interconnectEnabled = value;
    await _repo.setInterconnectEnabled(value);
    _settingsContext.refresh();
  }

  /// 别处（库页来源视图）改了互联总开关：回 preferences 读真值，不同就更新内存态
  /// 并刷新可见性谓词。**只信真值不信广播载荷**，故本页自己写的那次会在这里读到
  /// 相同值、直接 no-op（BUG-1560）。
  void _onInterconnectEnabledChanged() {
    unawaited(_reloadInterconnectEnabled());
  }

  Future<void> _reloadInterconnectEnabled() async {
    final bool value = await _repo.isInterconnectEnabled();
    if (interconnectEnabled == value) return;
    interconnectEnabled = value;
    _settingsContext.refresh();
  }

  /// 解除全局监听。缓存被换 owner 顶掉时调用；两个 ValueNotifier 仍有 widget 在
  /// 监听（它们各自在 State.dispose 里摘钩），故这里**不**dispose 它们。
  void dispose() {
    SyncRepository.interconnectEnabledRevision.removeListener(
      _onInterconnectEnabledChanged,
    );
  }

  Future<void> load() async {
    if (_loaded || _loading) return;

    _loading = true;
    try {
      backendType = await _repo.getBackendType();
      interconnectEnabled = await _repo.isInterconnectEnabled();
      autoSync = await _repo.isAutoSyncEnabled();
      syncStats = await _repo.isSyncStatsEnabled();
      syncContent = await _repo.isSyncContentEnabled();
      syncAudioBookFiles = await _repo.isSyncAudioBookFilesEnabled();
      syncVideoFiles = await _repo.isSyncVideoFilesEnabled();
      interconnectSyncContent = await _repo.isInterconnectSyncContentEnabled();
      interconnectSyncAudioBookFiles = await _repo
          .isInterconnectSyncAudioBookFilesEnabled();
      interconnectSyncVideoFiles = await _repo
          .isInterconnectSyncVideoFilesEnabled();
      interconnectSyncStats = await _repo.isInterconnectSyncStatsEnabled();
      interconnectSyncFavorites = await _repo
          .isInterconnectSyncFavoritesEnabled();
      interconnectServiceConfigSync = await _repo
          .isInterconnectServiceConfigSyncEnabled();
      interconnectProfileTransfer = await _repo
          .isInterconnectProfileTransferEnabled();
      interconnectLeaderboardLinkHost = await _repo
          .isInterconnectLeaderboardLinkHostEnabled();
      leaderboardFollowPairedLogin = await _repo
          .isLeaderboardFollowPairedLoginEnabled();
      interconnectRemoteUpdate = await _repo
          .isInterconnectRemoteUpdateEnabled();
      serverEnabled = await _repo.isServerEnabled();
      serverPort = await _repo.getServerPort();
      final List<FushiClientUrl> urls = await _repo.getFushiClientUrls();
      hasClientConnection = urls.isNotEmpty;
      peerCount = interconnectPeerRepresentatives(urls).length;
      _loaded = true;
      _settingsContext.refresh();
    } finally {
      _loading = false;
    }
  }
}
