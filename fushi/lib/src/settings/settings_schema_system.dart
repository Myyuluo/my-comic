import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_common.dart'
    show openFeedbackCenter;
import 'package:fushi/src/pages/implementations/leaderboard/leaderboard_tab.dart'
    show LeaderboardPage;
import 'package:fushi/src/pages/implementations/updates_center_open.dart'
    show openUpdatesCenter;
import 'package:fushi/src/onboarding/recommended_pack_discard.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_row.dart';
import 'package:fushi/src/onboarding/recommended_pack_import.dart';
import 'package:fushi/src/backup_import/mihon_backup_import_flow.dart';
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/stats/study_diag_export.dart';
import 'package:fushi/src/sync/sync_http.dart';
import 'package:fushi/src/updates/app_update_check.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/crash_dump_locator.dart';
import 'package:fushi/src/utils/misc/log_exporter.dart';
import 'package:fushi/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// 「首页入口」：首页模块关掉后，首页浮动工具栏上那四个入口的落脚处。
///
/// 首页工具栏（`home_dashboard_page.dart` 的 `_buildFloatingToolbar`）是更新中心、
/// 统计中心、排行榜、反馈四个页面的常驻入口，其中统计中心与排行榜**只有**这一处
/// 入口。2026-10-09 首页可关（[ModuleId.home]）之后，关掉首页不能把它们一起关成
/// 不可达——所以首页关着时这里出现同样四行，打开的是同一个页面、同一个函数。
/// 首页开着时整段隐藏（不在设置里多一份重复入口，也不进搜索）。
SettingsSection _homeShortcutsSection() {
  return SettingsSection(
    id: 'system.section.home_shortcuts',
    presentation: SettingsSectionPresentation.alwaysExpanded,
    title: t.settings_section_home_shortcuts,
    visible: (SettingsContext c) =>
        !c.appModel.moduleVisibility.isEnabled(ModuleId.home),
    items: <SettingsItem>[
      SettingsNavigationItem(
        id: 'system.home_shortcut_updates',
        title: t.updates_center_title,
        icon: FushiIcons.notifications,
        onTap: (SettingsContext c) =>
            openUpdatesCenter(c.context, c.appModel.updateFeedService),
      ),
      SettingsNavigationItem(
        id: 'system.home_shortcut_statistics',
        title: t.stat_center_title,
        icon: FushiIcons.barChart,
        onTap: (SettingsContext c) =>
            pushSettingsPage(c, (_) => const StatisticsCenterPage()),
      ),
      SettingsNavigationItem(
        id: 'system.home_shortcut_leaderboard',
        title: t.leaderboard_title,
        icon: FushiIcons.trophy,
        onTap: (SettingsContext c) =>
            pushSettingsPage(c, (_) => const LeaderboardPage()),
      ),
      SettingsNavigationItem(
        id: 'system.home_shortcut_feedback',
        title: t.feedback_title,
        icon: FushiIcons.forum,
        // 从设置里点开时截到的是设置页，没有意义；不预截图。
        onTap: (SettingsContext c) =>
            openFeedbackCenter(c.context, captureScreen: false),
      ),
    ],
  );
}

/// 启动页下拉的「默认」项 token（底栏第一个可见页）。其余项的 token 是
/// [ModuleId.name]——只是设置行 / ctl 的取值，持久化走 [ModuleId.prefKey]
/// （见 `PreferencesRepository.setStartupModule`）。
const String _kStartupModuleDefault = 'default';

/// 启动页可选项：默认 + 有底栏 tab 的模块，按用户排的底栏顺序。[visibility] 为
/// null 时给静态全集（仅供恢复默认的标签格式化），否则只列此刻可见的模块——
/// 被关掉 / 本平台不存在的模块选不了（反馈 #PwEC1evz1E）。
List<SettingsSegmentOption<String>> _startupModuleOptions(
  ModuleVisibility? visibility,
) => <SettingsSegmentOption<String>>[
  SettingsSegmentOption<String>(
    value: _kStartupModuleDefault,
    label: t.startup_module_default,
  ),
  for (final ModuleId module in visibility?.ordered ?? ModuleId.values)
    if (homeTabOfModule(module) case final HomeTab tab
        when visibility == null || visibility.isEnabled(module))
      SettingsSegmentOption<String>(
        value: module.name,
        label: homeNavItemFor(tab).label,
      ),
];

/// 当前生效的启动页 token：所选模块此刻不可见时显示默认，与启动时的实际落点
/// （`homeInitialTab` 回退到第一个可见页）一致。
String _startupModuleToken(AppModel appModel) {
  final ModuleId? module = appModel.startupModule;
  if (module == null ||
      homeTabOfModule(module) == null ||
      !appModel.moduleVisibility.isEnabled(module)) {
    return _kStartupModuleDefault;
  }
  return module.name;
}

ModuleId? _startupModuleOfToken(String token) {
  for (final ModuleId module in ModuleId.values) {
    if (module.name == token) return module;
  }
  return null;
}

SettingsDestination buildSystemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.settings_destination_system_about,
    summary: t.settings_destination_system_summary,
    icon: FushiIcons.system,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'system.section.general',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        // 文案统一（阶段 F/G）：本 section 原标题与 destination 标题同为「系统」，
        // 搜索面包屑显示「系统 › 系统」语义重复。改为「通用」——本区聚的是版本 /
        // 内存 / 手柄导航 / 快捷键 / GitHub 这类通用应用项。框架层另有面包屑去重
        // （settingsSearchBreadcrumb），双保险消灭整类重复。
        title: t.settings_section_general,
        // 「推荐包下载」行随 controller 的阶段实时显隐：本分组自己订阅 stage
        // （SettingsSection.liveListenable），不再靠宿主页整页重建。
        liveListenable: (SettingsContext settingsContext) =>
            settingsContext.appModel.recommendedPackDownloadController.stage,
        items: <SettingsItem>[
          // 「界面语言」（id 'appearance.language'）已归位到「外观 · 界面」分区
          //（与主题/明暗/缩放并列）；id 前缀本就是 appearance，此前放系统分类
          // 是历史错配。
          SettingsSwitchItem(
            id: 'system.focus_navigation',
            title: t.focus_navigation_enabled,
            subtitle: t.focus_navigation_enabled_hint,
            icon: Icons.gamepad_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.experimentalFocusNavigationEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setExperimentalFocusNavigationEnabled(value);
              settingsContext.refresh();
            },
          ),
          // 启动页（反馈 #PwEC1evz1E）：取代旧开关「启动时打开查词」，可选任一此刻
          // 可见、有底栏 tab 的模块（选项随功能模块开关与排序实时变化）。所选模块
          // 被关掉时这里显示「底栏第一个页面」，与启动时的实际落点（homeInitialTab）
          // 一致；重新打开该模块后用户原先的选择照旧生效。
          // item id 沿用旧开关的 'appearance.startup_default_dictionary_tab'（设置
          // 搜索锚点，历史命名，非持久化 key）；持久化见 ModuleId.startupPrefKey。
          SettingsSegmentedItem<String>(
            id: 'appearance.startup_default_dictionary_tab',
            title: t.startup_module,
            subtitle: t.startup_module_hint,
            icon: FushiIcons.home,
            dropdown: true,
            defaultValue: _kStartupModuleDefault,
            options: _startupModuleOptions(null),
            optionsBuilder: (SettingsContext settingsContext) =>
                _startupModuleOptions(
                  settingsContext.appModel.moduleVisibility,
                ),
            selected: (SettingsContext settingsContext) =>
                _startupModuleToken(settingsContext.appModel),
            onChanged: (SettingsContext settingsContext, String token) async {
              await settingsContext.appModel.setStartupModule(
                _startupModuleOfToken(token),
              );
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.low_memory_mode',
            title: t.low_memory_mode,
            subtitle: t.low_memory_mode_hint,
            icon: Icons.memory_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.lowMemoryMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setLowMemoryMode(value);
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'system.app_version',
            icon: FushiIcons.info,
            builder: _buildRuntimeAppVersionRow,
          ),
          // 官网。与宽屏侧栏左上角的 app 图标是同一个入口（openOfficialWebsite），
          // URL 只存在 official_links.dart 一处。
          SettingsActionItem(
            id: 'system.website',
            title: t.options_website,
            icon: Icons.language_outlined,
            cli: const SettingsCliAction.tap(),
            onTap: (_) async {
              await openOfficialWebsite();
            },
          ),
          SettingsActionItem(
            id: 'system.github',
            title: t.options_github,
            icon: Icons.public_outlined,
            cli: const SettingsCliAction.tap(),
            onTap: (_) async {
              await launchUrl(
                Uri.parse('https://github.com/hajisensai/fushi'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
          SettingsActionItem(
            id: 'system.github_sponsors',
            title: t.options_github_sponsors,
            icon: FushiIcons.favorite,
            cli: const SettingsCliAction.tap(),
            onTap: (_) async {
              await launchUrl(
                Uri.parse(kGitHubSponsorsUrl),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
        ],
      ),
      // my-comic：Mihon v0.21.3 `.tachibk` Import。Fushi 自己的
      // `.fushi.zip` 同步与备份链路随非漫画域一起移除，这里只保留把已有
      // Mihon Library 带过来的最小入口；文件只在本机解析与落库，不上传。
      SettingsSection(
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
              'Settings → System → Backup → Import Mihon backup.',
            ),
            onTap: runMihonBackupImport,
          ),
        ],
      ),
      SettingsSection(
        id: 'system.section.network',
        presentation: SettingsSectionPresentation.collapsed,
        title: t.section_network,
        items: <SettingsItem>[
          // 全应用唯一的代理项：自动 = env > 系统代理 > 直连；直连 = 明确禁用；
          // 手动 = 下方地址与可选认证。持久化地址键 `update_custom_proxy` 是历史遗留，
          // 冻结不改；旧安装若已有地址且还没有模式键，会自动投影成手动模式。
          SettingsSegmentedItem<String>(
            id: 'system.network_proxy_mode',
            title: t.network_proxy_mode_label,
            icon: FushiIcons.server,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: kProxyModeAuto,
                label: t.network_proxy_mode_auto,
                icon: Icons.sync_outlined,
                tooltip: t.network_proxy_mode_auto_hint,
              ),
              SettingsSegmentOption<String>(
                value: kProxyModeDirect,
                label: t.network_proxy_mode_direct,
                icon: Icons.link_off_outlined,
                tooltip: t.network_proxy_mode_direct_hint,
              ),
              SettingsSegmentOption<String>(
                value: kProxyModeManual,
                label: t.network_proxy_mode_manual,
                icon: FushiIcons.settings,
                tooltip: t.network_proxy_mode_manual_hint,
              ),
            ],
            selected: (SettingsContext c) => c.appModel.networkProxyMode,
            onChanged: (SettingsContext c, String value) async {
              await c.appModel.setNetworkProxyMode(value);
              resetSyncHttpClient();
              c.refresh();
            },
          ),
          SettingsTextItem(
            id: 'system.network_proxy',
            title: t.network_proxy_label,
            subtitle: t.network_proxy_address_hint,
            icon: FushiIcons.server,
            placeholder: t.network_proxy_hint,
            keyboardType: TextInputType.url,
            visible: (SettingsContext c) =>
                c.appModel.networkProxyMode == kProxyModeManual,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateCustomProxy,
            onChanged: (SettingsContext settingsContext, String value) async {
              final String trimmed = value.trim();
              await settingsContext.appModel.setUpdateCustomProxy(trimmed);
              // 云同步的共享 client 在首次使用时就把代理解析结果固化进 findProxy 了，
              // 不丢弃它，用户改完代理仍走旧出口——那等于这条设置对同步不生效
              // （BUG-1348）。更新检查每次新建 client，不受影响。
              resetSyncHttpClient();
              // 非空且无法归一成合法 host:port → 提示（仍保存原串，运行时忽略）。
              if (trimmed.isNotEmpty &&
                  normalizeUserProxyHostPort(trimmed) == null) {
                final BuildContext ctx = settingsContext.context;
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  FushiSnackBar(content: Text(t.network_proxy_invalid)),
                );
              }
            },
          ),
          SettingsTextItem(
            id: 'system.network_proxy_username',
            title: t.network_proxy_username,
            // 认证的作用面必须说清：凭据是 dart:io `HttpClient.authenticateProxy`
            // 的 407 应答，只覆盖 app 自己发的 HTTP 出站。内置 torrent 引擎的 C ABI
            // （`ht_apply_proxy`）只接 type/host/port，libtorrent 的
            // `settings_pack::proxy_username/password` 根本没被导出，凭据到不了
            // P2P 那一侧；不写出来用户会以为「开了 P2P 走代理」就连上了。
            subtitle: t.network_proxy_credentials_scope_hint,
            icon: FushiIcons.person,
            visible: (SettingsContext c) =>
                c.appModel.networkProxyMode == kProxyModeManual,
            value: (SettingsContext c) => c.appModel.networkProxyUsername,
            onChanged: (SettingsContext c, String value) async {
              await c.appModel.setNetworkProxyUsername(value.trim());
              resetSyncHttpClient();
            },
          ),
          SettingsTextItem(
            id: 'system.network_proxy_password',
            title: t.network_proxy_password,
            icon: Icons.password_outlined,
            secret: true,
            visible: (SettingsContext c) =>
                c.appModel.networkProxyMode == kProxyModeManual,
            value: (SettingsContext c) => c.appModel.networkProxyPassword,
            onChanged: (SettingsContext c, String value) async {
              await c.appModel.setNetworkProxyPassword(value);
              resetSyncHttpClient();
            },
          ),
        ],
      ),
      // v101 统一更新提醒。四个域各一个开关 + 系统通知总开关。
      //
      // 四个域开关**不经 `AppModel.updateFeedService`**，直接读写 pref 键：
      // service 本身也只是这些键的读写者，走它等于给纯偏好项挂上整条 DB 依赖。
      // **例外是「系统通知」总开关**：它的显示值要合并系统权限状态、打开时要
      // 申请权限，这两件事只有 service 知道（BUG-2498）。所以渲染系统页的
      // widget 测试必须 `wireDatabaseForTesting`——`updateFeedService` 首次访问
      // 会解引用数据库。
      SettingsSection(
        id: 'system.section.update_notifications',
        title: t.updates_notify_section,
        items: <SettingsItem>[
          for (final (
                UpdateFeedKind kind,
                String title,
                String hint,
                IconData icon,
              )
              in <(UpdateFeedKind, String, String, IconData)>[
                (
                  UpdateFeedKind.mangaChapter,
                  t.updates_notify_manga_chapter,
                  t.updates_notify_manga_chapter_hint,
                  FushiIcons.manga,
                ),
                (
                  UpdateFeedKind.mangaExtension,
                  t.updates_notify_manga_extension,
                  t.updates_notify_manga_extension_hint,
                  FushiIcons.browserExtension,
                ),
              ])
            SettingsSwitchItem(
              id: 'system.updates.${kind.dbValue}',
              title: title,
              subtitle: hint,
              icon: icon,
              value: (SettingsContext settingsContext) =>
                  settingsContext.appModel.prefsRepo.getPref(
                        kind.enabledPrefKey,
                        defaultValue: true,
                      )
                      as bool,
              onChanged: (SettingsContext settingsContext, bool value) async {
                await settingsContext.appModel.prefsRepo.setPref(
                  kind.enabledPrefKey,
                  value,
                );
                settingsContext.refresh();
              },
            ),
          // 扩展后台自动更新（默认关）：启动时把签名未变的漫画 / 视频扩展装成
          // 仓库新版；碰过在线源的进程里推迟到下次启动。只在有 Mihon 宿主且
          // 合规允许在线源的平台出现。
          SettingsSwitchItem(
            id: 'system.updates.extension_auto_update',
            title: t.updates_extension_auto_update,
            subtitle: t.updates_extension_auto_update_hint,
            icon: FushiIcons.sync,
            defaultValue: false,
            visible: (_) =>
                MihonRuntimeFactory.isSupported &&
                StoreRestrictedCapability.onlineMangaSource.isAvailable,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.mihonExtensionAutoUpdate,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setMihonExtensionAutoUpdate(value);
              settingsContext.refresh();
            },
          ),
          // 显示值 = 偏好开 && 系统已授权；打开 = 唯一会弹系统权限框的地方
          // （BUG-2498：启动期不再申请，申请只跟着用户这一下）。
          SettingsSwitchItem(
            id: 'system.updates.system_notifications',
            title: t.updates_system_notifications,
            subtitle: t.updates_system_notifications_hint,
            icon: Icons.notifications_active_outlined,
            value: (SettingsContext settingsContext) => settingsContext
                .appModel
                .updateFeedService
                .systemNotificationsActive,
            onChanged: (SettingsContext settingsContext, bool value) async {
              final UpdateFeedService feed =
                  settingsContext.appModel.updateFeedService;
              if (value) {
                await feed.enableSystemNotifications();
              } else {
                await feed.disableSystemNotifications();
              }
              settingsContext.refresh();
            },
          ),
        ],
      ),
      SettingsSection(
        id: 'system.section.diagnostics',
        presentation: SettingsSectionPresentation.collapsed,
        title: t.settings_destination_diagnostics,
        // 错误 / 调试日志的实时条数与「调试日志」行的显隐：本分组自己订阅两个日志
        // 服务。此前由宿主页整页 setState，调试日志开着时每条 debugPrint 都把整页
        // 设置行重建一遍。
        liveListenable: (_) => Listenable.merge(<Listenable>[
          ErrorLogService.instance,
          DebugLogService.instance,
        ]),
        items: <SettingsItem>[
          // 标题里的实时条数走 titleBuilder（渲染时求值）。写成构造期插值会把整棵
          // schema 变成「每次 setState 都得重建才能刷新计数」的状态载体——那正是
          // 全量重建的成因之一（见 settings_destination.dart 的 titleBuilder 注释）。
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title: t.error_log_label(n: 0),
            titleBuilder: (_) =>
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.report_problem_outlined,
            builder: (_) => const ErrorLogPage(),
          ),
          // TODO-607 P0-3：崩溃转储（native minidump）。仅 Windows 显示——native
          // 端只在 Windows runner 经 SetUnhandledExceptionFilter 写 .dmp，移动端无此
          // 机制（仿 wgc_capture_log 的 isWindows 门控）。让纯 native 闪退（嵌套查词
          // 把进程带崩等，错误日志里看不到）有可上传的二进制证据。
          SettingsNavigationItem(
            id: 'diagnostics.crash_dumps',
            // 同上走 titleBuilder——这一行的计数还要同步扫目录，构造期算等于每次
            // setState 都做一次磁盘 IO。
            title: t.crash_dump_label(n: 0),
            titleBuilder: (_) => t.crash_dump_label(
              n: CrashDumpLocator.listCurrentPlatformDumps().length,
            ),
            icon: Icons.bug_report_outlined,
            visible: (_) => Platform.isWindows,
            builder: (_) => const CrashDumpPage(),
          ),
          SettingsSwitchItem(
            id: 'diagnostics.debug_log_enabled',
            title: t.debug_log_toggle,
            icon: Icons.rule_outlined,
            value: (_) => DebugLogService.instance.enabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await DebugLogService.instance.setEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'diagnostics.debug_log',
            title: t.debug_log_title(count: 0),
            titleBuilder: (_) => t.debug_log_title(
              count: DebugLogService.instance.entries.length,
            ),
            icon: Icons.terminal_outlined,
            visible: (_) =>
                DebugLogService.instance.enabled ||
                DebugLogService.instance.entries.isNotEmpty,
            builder: (_) => const DebugLogPage(),
          ),
        ],
      ),
    ],
  );
}

/// 诊断导出在控制通道上的参数：CLI 给目标文件（代替保存对话框 / 系统分享）。
const List<SettingsCliParam> _kDiagExportParams = <SettingsCliParam>[
  SettingsCliParam('value', help: '导出到的文件（绝对路径）', path: true),
  SettingsCliParam('overwrite', help: 'true = 目标已存在时覆盖', required: false),
];

/// 控制通道导出：写到给定路径；已存在且没要求覆盖时拒绝。
Future<Object?> _writeDiagExport(Map<String, String> args, String log) async {
  final File file = File(args['value']!);
  if (file.existsSync() && args['overwrite'] != 'true') {
    throw ArgumentError('${file.path} 已存在；覆盖请加 --arg overwrite=true');
  }
  await file.parent.create(recursive: true);
  await file.writeAsString(log);
  return <String, Object?>{'path': file.path, 'bytes': await file.length()};
}

Future<String> _buildStudyDiagLog(AppModel appModel) => buildStudyDiagExport(
  appModel.database,
  appVersion: resolveCurrentAppVersion(appModel.packageInfo.version),
  readingIdleTimeoutMinutes: appModel.readingIdleTimeoutMinutes,
  statDayResetHour: appModel.statDayResetHour,
);

/// 设置 › 诊断 › 导出统计诊断日志（正文见 [buildStudyDiagExport]）。
Future<void> _exportStudyDiagLog(SettingsContext settingsContext) async {
  final String log = await _buildStudyDiagLog(settingsContext.appModel);
  if (!settingsContext.context.mounted) return;
  await saveLogToFile(
    context: settingsContext.context,
    log: log,
    fileName: 'fushi_study_diag_log.txt',
    subject: t.study_diag_share_subject,
  );
}

/// 手动「立即检查更新」：编排在 [checkAppUpdateNow]（与更新中心的 app 新版本
/// 条目共用同一条应用内下载安装链路）。
Future<void> _checkUpdateNow(SettingsContext settingsContext) =>
    checkAppUpdateNow(settingsContext.context, settingsContext.appModel);

String _selectedUpdateChannel(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return 'debug';
  if (settingsContext.appModel.updateBetaChannel) return 'beta';
  return 'stable';
}

/// TMDB 官方标识（`Primary short (blue)`）在包内的路径。
///
/// 这张 PNG 由 themoviedb.org/about/logos-attribution 下发的**矢量原图**栅格化而来；
/// 原图 `assets/attribution/tmdb/blue_square_1.svg` 逐字节入库存证（sha256 即 TMDB
/// 直链文件名里那串摘要）。之所以不直接渲染 SVG：Flutter 唯一现实的 SVG 方案
/// `flutter_svg` 不支持 CSS，而 TMDB 原图把唯一填充写在 `<style>` 类里，解析后渐变
/// 全丢、整个标识渲染成纯黑——那本身就是「改色」。栅格化只做尺寸映射，未改色 /
/// 改比例 / 翻转 / 旋转 / 裁剪。来源、哈希、配方与守卫见同目录 README.md 与
/// `test/settings/tmdb_attribution_test.dart`。
@visibleForTesting
const String kTmdbLogoAsset = 'assets/attribution/tmdb/logo_tmdb.png';

/// logo 展示高度（dp）；宽度见 [_kTmdbLogoWidth]（24 × 190.24/81.52 ≈ 56.0）。
///
/// 条款要求展示 TMDB 标识，但它**不得比本应用自己的标识更显眼**。这条义务的实测
/// 依据（数字均可按下列位置复核）：
///
/// - 同一行左侧的图标徽标是 30dp：`_SettingsIcon` 在 Material 下走
///   `FushiBadge(size: 18, padding: EdgeInsets.all(6))`，18+6*2 = 30
///   （`utils/components/settings_shared.dart`）。24dp 与之同量级。
/// - 应用自身图标在 Flutter widget 树里有两个真渲染点。设置 › 外观 › 应用图标的
///   预设瓦片（`miscellaneous_settings_page.dart` 的 `_AppIconTile`）中，
///   `SizedBox.square(72)` 扣掉 `FushiCard` 描边的 1dp 内缩与 `gap/2 = 4` 的
///   双侧 padding，图片实得 62×62dp；宽屏主导航 rail 的品牌位直接显示经过圆角
///   裁切的 64×64dp 图片。取较大的 64dp 作比较，TMDB 标识 24dp 高 = 其 37.5%；
///   面积 24×56.0 ≈ 1344dp²，是其 4096dp² 的 32.8%——
///   两个维度都更小，满足条款的 "less prominent"。
/// - 除上述预设瓦片和宽屏 rail 外应用图标不再重复绘制：首页 dashboard、
///   loading/splash 都不传图；窄屏底栏也没有品牌位。
///
/// 所以旧注释那句「远小于应用自身 logo 的**任何**展示尺寸」结论对、依据错：可比
/// 的最大展示尺寸现在是 64×64dp。调整本值前请重跑上述核对——这段是「不得更显眼」
/// 的唯一书面依据，守卫只能钉住上限（≤32dp），钉不住依据本身。
const double _kTmdbLogoHeight = 24;

/// 原图 viewBox 是 `0 0 190.24 81.52`；宽度按该比例算死，配合 [BoxFit.contain]
/// 保证任何主题/文字缩放下都不会被拉伸变形（改比例同样是条款禁止项）。
const double _kTmdbLogoWidth = _kTmdbLogoHeight * 190.24 / 81.52;

/// TMDB 署名行：官方标识 + 条款原句免责声明，点击跳官网。
///
/// 用 [SettingsCustomItem] 而不是 [SettingsActionItem]，只因为 schema 的 `icon`
/// 槽是 `IconData`、放不下一张图；行本体仍是共享的 [AdaptiveSettingsRow]，
/// 焦点/密度/折叠行为与其它设置行完全一致。
Widget _buildTmdbAttributionRow(SettingsContext settingsContext) {
  return AdaptiveSettingsRow(
    title: 'TMDB',
    subtitle: t.about_tmdb_attribution,
    icon: FushiIcons.video,
    showIcon: true,
    trailing: SizedBox(
      height: _kTmdbLogoHeight,
      width: _kTmdbLogoWidth,
      child: Image.asset(
        kTmdbLogoAsset,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'TMDB',
      ),
    ),
    onTap: () async => launchUrl(
      Uri.parse('https://www.themoviedb.org/'),
      mode: LaunchMode.externalApplication,
    ),
  );
}

Widget _buildRecommendedPackDownloadRow(SettingsContext settingsContext) {
  final AppModel appModel = settingsContext.appModel;
  return RecommendedPackDownloadRow(
    controller: appModel.recommendedPackDownloadController,
    // 导入编排是库级共享的（[importDownloadedRecommendedPack]）：设置这一行、
    // 新手引导那一步、首页迷你条三个发起点同一个真相源。
    onImport: () => unawaited(importDownloadedRecommendedPack(appModel)),
    // 放弃编排同样库级共享（[confirmAndDiscardRecommendedPack]）：确认框漏在任何
    // 一个发起点上，那一处就成了不带确认直接删几 GB 的按钮。
    onDiscard: () => unawaited(
      confirmAndDiscardRecommendedPack(
        settingsContext.context,
        appModel.recommendedPackDownloadController,
      ),
    ),
  );
}

Widget _buildRuntimeAppVersionRow(SettingsContext settingsContext) {
  final packageInfo = settingsContext.appModel.packageInfo;
  return AdaptiveSettingsRow(
    title: t.app_version,
    subtitle: formatAppVersionDisplay(
      packageInfo,
      runningCodeVersion: fushiRunningCodeVersion,
    ),
    icon: FushiIcons.info,
    showIcon: true,
  );
}

/// 版本展示文案。versionName 是 semver（含 `-debug.5613` 等预发布段），
/// buildNumber 是 Android versionCode（如 `1000561300`），两者语义不同：
/// 绝不能用 semver 的 `+` build-metadata 把 versionCode 拼进 versionName，
/// 否则会渲染出畸形的 `0.11.1-debug.5613+1000561300`。用括号并列展示。
///
/// [runningCodeVersion] 是编译进 `app.so` 的构建版本（见 `build_version.dart`），
/// [PackageInfo.version] 则来自 exe / Info.plist / manifest 的版本资源。两者是
/// **两个文件**：Inno 的回滚保留被覆盖的文件、只删本次新建的文件，所以「新 exe +
/// 旧 app.so」这种半更新态完全可能落地（BUG-1786 现场），而版本资源照样报新版本。
///
/// 不一致时并排显示 exe 那个值——关于页是用户唯一能自查这件事的地方。
@visibleForTesting
String formatAppVersionDisplay(
  PackageInfo packageInfo, {
  String? runningCodeVersion,
}) {
  final String executableVersion = packageInfo.version;
  final String shown = runningCodeVersion ?? executableVersion;
  final String display = '$shown (${packageInfo.buildNumber})';
  if (runningCodeVersion == null) return display;
  if (_isSameBuildVersion(runningCodeVersion, executableVersion)) {
    return display;
  }
  return '$display ≠ exe $executableVersion';
}

/// [codeVersion]（`app.so` 里的构建版本）与 [executableVersion]（exe / Info.plist /
/// manifest 的版本资源）是否来自同一次构建。
///
/// **不对称**：原生版本资源是代码版本的一种**有损渲染**——在版本字段只收数字段的
/// 平台上（Apple：`CFBundleShortVersionString` 至多三段非负整数），`release-desktop.yml`
/// 给 `--build-name` 传的是剥掉预发布段的 `apple_build_version_name`，而
/// `--dart-define=FUSHI_BUILD_VERSION` 注入的仍是完整版本名（守卫
/// `test/build/build_version_define_guard_test.dart` 同时钉死这两条）。所以两侧
/// **故意解耦**：iOS 上同一次构建就是 `2.2.1-beta.30` 的代码配 `2.2.1` 的 Info.plist。
///
/// 判据因此是「逐字相等 **或** 版本资源等于代码版本剥掉预发布段后的值」：
///
/// - Windows 半更新态 exe `2.2.1-debug.12216` / 代码 `2.2.1-debug.12215`：剥段得
///   `2.2.1` ≠ exe ⇒ 照常告警（BUG-1786 现场，基版本相同、只差序号一位，只比基
///   版本的实现会对唯一需要它的输入闭眼）。
/// - Apple 预发布包 exe `2.2.1` / 代码 `2.2.1-beta.30`：剥段后相等 ⇒ 静默。
///
/// **已知残留假阴性**：Windows「正式版 exe `2.2.1` + 同 base 预发布 app.so」的跨通道
/// 半更新态会被这条判据静默。这是有意的取舍——它与 Apple 的正常态在字符串层面完全
/// 同形，分开只能靠平台特例分支；换来的是 Apple 端不再常驻一个恒为真的「你的安装
/// 坏了」告警。真出这种跨通道半更新态时，更新检查侧（[resolveCurrentAppVersion] 吃
/// 代码版本）仍会照常提示新版本，用户不会被困住。
bool _isSameBuildVersion(String codeVersion, String executableVersion) {
  final String code = _normalizedVersion(codeVersion);
  final String executable = _normalizedVersion(executableVersion);
  if (code == executable) return true;
  return executable == _withoutPrerelease(code);
}

String _normalizedVersion(String version) =>
    version.trim().replaceFirst(RegExp('^[vV]'), '').split('+').first;

/// 剥掉 semver 预发布段（`2.2.1-beta.30` → `2.2.1`）——原生版本字段只收数字段的
/// 平台上，版本资源里落地的就是这个值。
String _withoutPrerelease(String normalizedVersion) =>
    normalizedVersion.split('-').first;
