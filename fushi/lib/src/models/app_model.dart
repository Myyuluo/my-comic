import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

// archive/archive_io moved to DictionaryImportManager
// audio_service moved to AudioController
// external_app_launcher moved to AnkiIntegration
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/updates/local_update_notifier.dart';
import 'package:fushi/src/updates/update_check_scheduler.dart';
import 'package:fushi/src/updates/usage_heartbeat.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi/src/updates/update_probes.dart';
import 'package:fushi/src/pages/implementations/updates_center_open.dart';
import 'package:fushi/src/updates/update_notifier.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as path;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:remove_emoji/remove_emoji.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fushi/src/utils/misc/screen_wakelock.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/media.dart';


import 'package:fushi/pages.dart';
import 'package:fushi/utils.dart';

import 'package:fushi/src/media/override_thumbnail_migration.dart';

import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/portable_state_rebase.dart';
import 'package:fushi/src/storage/books_directory.dart';
import 'package:fushi/src/storage/export_directory.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/error_details_dialog.dart';
import 'package:fushi/src/utils/net/app_network_bindings.dart';
import 'package:fushi/src/media/drag_drop/desktop_drop_reinitializer.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/media/floating_dict_channel.dart';
import 'package:fushi/src/models/app_font_loader.dart';
import 'package:fushi/src/models/app_ui_font_chain.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_endpoint.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'package:fushi/src/reader/reader_control_layout.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_engine/models/dictionary_directory.dart';
import 'package:fushi/src/models/media_history_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/manga/cookie/manga_cookie_jar.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';

import 'package:fushi/src/media/manga/download/manga_download_service.dart';




import 'package:fushi/src/media/manga/mihon/mihon_extension_store_client.dart';
import 'package:fushi/src/media/manga/mihon/mihon_manager.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime.dart';
import 'package:fushi/src/media/manga/mihon/mihon_runtime_factory.dart';











import 'package:fushi_engine/utils/net/fake_ip_dns.dart';







import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/direct_link_download.dart';
import 'package:fushi_engine/media/discovery/import/discovery_import_executor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_production.dart';
import 'package:fushi/src/media/downloads/download_keep_alive_bindings.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/media/discovery/media_discovery_source.dart';

import 'package:fushi/src/media/discovery/opds_server_config.dart';



import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';

































import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';

import 'package:fushi_engine/sync/local_library_host_service.dart';
import 'package:fushi_engine/media/audiobook/audiobook_transcribe_import_queue.dart';
import 'package:fushi_engine/media/discovery/import/discovery_engine_importers.dart'
    show
        importDiscoveryAudiobook,
        importDiscoverySubtitleAudiobook,
        importTranscribedAudiobook,
        isDuplicateDiscoveryAudiobookContent;
import 'package:fushi_engine/media/discovery/import/discovery_import_plan.dart';


import 'package:fushi_engine/asr/asr_host_job_runner.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_manager.dart';
import 'package:fushi_engine/sync/host_jobs/host_job_runner.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';


import 'package:fushi_engine/sync/sync_asset_package_service.dart';

import 'package:fushi/src/models/theme_notifier.dart' as theme_notifier;
import 'package:fushi/src/models/theme_notifier.dart'
    show ThemeNotifier, CustomThemeEntry, ThemePreset;
// TODO-930: re-export the multi-theme value type so `fushi/models.dart`
// consumers (theme swatch row, CustomThemePage) can name it.
export 'package:fushi/src/models/theme_notifier.dart'
    show CustomThemeEntry, ThemePreset;
import 'package:fushi/src/models/file_export_manager.dart';
import 'package:fushi_engine/models/local_audio_source_pref.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/immersion_mine_payload.dart';






import 'package:fushi_engine/mining/immersion_mining_request.dart';


import 'package:fushi_engine/sync/manga_sync_package.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/settings/settings_schema.dart'
    show resetSettingsSchemaCache;


import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart'
    show RemotePopupDictionaryCss;
import 'package:fushi/src/shortcuts/gamepad_service.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/platform/platform_providers.dart';


/// A global [Provider] for app-wide configuration and state management.
final appProvider = ChangeNotifierProvider<AppModel>((ref) {
  return AppModel(ref.read(platformServicesProvider));
});

// Theme helper functions moved to theme_notifier.dart.
// Re-export for backward compatibility.
ColorScheme buildFushiColorScheme({
  required Color seedColor,
  required Brightness brightness,
  DynamicSchemeVariant variant = theme_notifier.kFushiDefaultSchemeVariant,
  Color? primary,
  Color? secondary,
  Color? tertiary,
  Color? primaryContainer,
  Color? surface,
  bool neutralDerived = false,
  bool pureBlack = false,
}) =>
    theme_notifier.buildFushiColorScheme(
      seedColor: seedColor,
      brightness: brightness,
      variant: variant,
      primary: primary,
      secondary: secondary,
      tertiary: tertiary,
      primaryContainer: primaryContainer,
      surface: surface,
      neutralDerived: neutralDerived,
      pureBlack: pureBlack,
    );

/// A scoped model for parameters that affect the entire application.
/// RiverPod is used for global state management across multiple layers,
/// especially for preferences that persist across application restarts.
class AppModel with ChangeNotifier {
  /// Platform-specific service implementations, injected at construction.
  final PlatformServices platformServices;

  AppModel(this.platformServices);

  /// 测试 seam：把偏好仓库与数据库目录接进 AppModel（本地音频管理器已删除）。
  @visibleForTesting
  void wireLocalAudioForTesting({
    required PreferencesRepository prefsRepo,
    required Directory databaseDirectory,
  }) {
    _prefsRepo = prefsRepo;
    _databaseDirectory = databaseDirectory;
    _thumbnailsDirectory = databaseDirectory;
  }

  /// 兼容保留：语言表现在只由 [populateLocales] 构建；旧测试仍会调用本方法。
  @visibleForTesting
  void populateLanguages() {}

  /// Test seam: inject an already-open database so widget tests can exercise
  /// schema builders (e.g. the sync/backup destination) that read [database]
  /// without running the full [initialise] path.
  @visibleForTesting
  void wireDatabaseForTesting(FushiDatabase db) {
    _database = db;
    _databaseOpened = true;
  }

  GlobalKey<NavigatorState> get navigatorKey => _navigatorKey;
  late final GlobalKey<NavigatorState> _navigatorKey =
      GlobalKey<NavigatorState>();

  BuildContext? get _ctx => _navigatorKey.currentContext;

  /// Used to get the versioning metadata of the app. See [initialise].
  RouteObserver<PageRoute> get routeObserver => _routeObserver;
  final RouteObserver<PageRoute> _routeObserver = RouteObserver<PageRoute>();

  /// Persistent database (Drift/SQLite).
  late FushiDatabase _database;

  /// True once [_database] has been opened in an init path. Used by
  /// [retryInitialise] to close a stale connection before re-running init
  /// (the late fields are reassigned, so the old DB would otherwise leak).
  bool _databaseOpened = false;

  /// Whether [database] is safe to read. False before any init path has opened
  /// the DB (and while a test seam deliberately leaves [_database] unset), so
  /// callers outside the init flow must gate [database] access on this instead
  /// of risking a LateInitializationError.
  bool get isDatabaseReady => _databaseOpened;

  /// Theme management, extracted from AppModel for testability.
  late ThemeNotifier themeNotifier;
  bool _themeListenerAdded = false;

  /// Preference management, extracted from AppModel for testability.
  PreferencesRepository? _prefsRepo;
  PreferencesRepository get prefsRepo => _prefsRepo!;
  bool get isPreferencesReady => _prefsRepo != null;

  /// v101 统一更新提醒。懒建：四个投递方（番剧订阅检查、漫画库刷新、扩展检查、
  /// app 版本检查）与更新页共用这一份，进程内单例。
  ///
  /// **不放 `initialise()`**：弹窗词典与悬浮词典是另外两个 entry point，不经
  /// `initialise()`，而它们也可能间接走到会投递的代码路径；懒 getter 让「谁用谁
  /// 建」，用不到的进程一分钱不花（与 `installAsrHostBindings` 那处同类教训）。
  UpdateFeedService? _updateFeedService;
  UpdateFeedService get updateFeedService =>
      _updateFeedService ??= UpdateFeedService(
        database: database,
        prefs: prefsRepo,
        notifier: systemNotifier,
        notificationText: localizedUpdateNotificationText,
      );

  /// 本进程唯一的系统通知后端（更新提醒与反馈回复提醒共用）。
  ///
  /// 必须只有一份：`flutter_local_notifications` 的插件是进程内单例，点击回调只有
  /// 一个槽位，谁最后 `initialize` 谁赢——两个消费方各建一份，先建的那方的通知点了
  /// 就没反应。所以点击统一进 [_onSystemNotificationResponse]，按载荷分派。
  /// 懒建，理由同 [updateFeedService]。
  UpdateNotifier? _systemNotifier;
  UpdateNotifier get systemNotifier =>
      _systemNotifier ??= LocalUpdateNotifier.isSupportedPlatform
          ? LocalUpdateNotifier(
              appName: 'Fushi',
              groupTitle: t.updates_notification_header,
              onResponse: _onSystemNotificationResponse,
            )
          : const NoopUpdateNotifier();

  /// 用户点了系统通知。先把窗口唤到前台——Windows 的 toast 激活只是回调进程，
  /// 不会替我们把主窗拉起来。反馈回复通知 → 那条反馈的详情；其余是更新提醒：
  /// 本体 / 「打开」→ 那条更新的落点（番剧 = 播放该集）；「查看更新」/ 载荷解不出 /
  /// 条目已被清 → 更新中心。
  Future<void> _onSystemNotificationResponse(
    UpdateNotificationResponse response,
  ) async {
    final BuildContext? context = navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    if (!isDatabaseReady) return;
    final UpdateNotificationPayload? payload =
        UpdateNotificationPayload.decode(response.payload);
    final UpdateFeedEntryRow? entry = payload == null ||
            response.actionId == kUpdateNotificationActionViewAll
        ? null
        : await database.getUpdateFeedEntry(payload.entryId);
    if (!context.mounted) return;
    if (entry == null) {
      await openUpdatesCenter(context, updateFeedService);
      return;
    }
    // 与更新中心页同序：先标已读（「点开过」不取决于跳转成败），再跳。
    await updateFeedService.markSeen(<String>[entry.entryId]);
    if (!context.mounted) return;
    await openUpdateFeedEntry(context, entry);
  }

  /// 「打开落点」按钮的文案，按域。
  static String _openActionLabel(UpdateFeedKind kind) => switch (kind) {
        UpdateFeedKind.videoEpisode =>
          t.updates_notification_open_video_episode,
        UpdateFeedKind.mangaChapter =>
          t.updates_notification_open_manga_chapter,
        UpdateFeedKind.mangaExtension ||
        UpdateFeedKind.animeExtension =>
          t.updates_notification_open_manga_extension,
        UpdateFeedKind.appRelease => t.updates_notification_open_app_release,
      };

  /// 通知文案的本地化外壳。服务层默认实现只组装结构（那一层要能在纯 Dart 单测里
  /// 跑，slang 的 `t` 需要 Flutter binding），这里补上句子与按钮。
  ///
  /// 正文 = 副标题 · 发布时刻（`MM-dd HH:mm`，本地化无关——toast 一行放不下
  /// 长格式，17 种语言一致）；多条时「第一条 等 N 项」。时刻只在**单条**时进正文：
  /// 汇总条的时刻属于谁说不清。
  static UpdateNotificationText localizedUpdateNotificationText(
    UpdateFeedKind kind,
    List<UpdateFeedDraft> fresh,
  ) {
    final UpdateFeedDraft first = fresh.first;
    final String openLabel = _openActionLabel(kind);
    final String viewAllLabel = t.updates_notification_view_all;
    if (fresh.length == 1) {
      final int? publishedAt = first.publishedAt;
      final String body = <String>[
        if (first.subtitle case final String subtitle when subtitle.isNotEmpty)
          subtitle,
        if (publishedAt != null)
          _shortMoment(DateTime.fromMillisecondsSinceEpoch(publishedAt)),
      ].join(' · ');
      return UpdateNotificationText(
        title: first.title,
        body: body,
        openLabel: openLabel,
        viewAllLabel: viewAllLabel,
      );
    }
    final String firstLine = first.subtitle == null || first.subtitle!.isEmpty
        ? first.title
        : '${first.title} · ${first.subtitle}';
    return UpdateNotificationText(
      title: first.title,
      body: t.updates_notification_summary(
        first: firstLine,
        count: fresh.length - 1,
      ),
      openLabel: openLabel,
      viewAllLabel: viewAllLabel,
    );
  }

  /// `MM-dd HH:mm`：[FushiTimeFormat.dayKey] 去掉年份 + [FushiTimeFormat.hourMinute]。
  static String _shortMoment(DateTime time) =>
      '${FushiTimeFormat.dayKey(time).substring(5)} '
      '${FushiTimeFormat.hourMinute(time)}';

  UpdateCheckScheduler? _updateCheckScheduler;
  UsageHeartbeat? _usageHeartbeat;

  /// 启动后台更新检查（漫画新章 + 漫画扩展）。幂等，重复调用不再起第二个定时器。
  ///
  /// **番剧不在这里**：订阅服务有自己的相位学习节奏。**app 版本也不在这里**：
  /// 启动期的 `UpdateChecker.scheduleCheck` 已经在查，那条链路顺手把结果投给更新
  /// 中心即可（见 home_page 的 onUpdateAvailable），再排一个定时器只会重复请求。
  ///
  /// 扩展两个 probe（漫画 / 视频）在「后台自动更新扩展」开着时，没建 manager 也会
  /// 为已装扩展建一个（见 [_mihonManagerForAutoUpdate]）；其余情况与下面同理。
  ///
  /// 漫画两个 probe 都**不主动拉起 Mihon runtime**：`mihonManager` 是懒建的，为了
  /// 后台检查而在启动时拉起一个 sidecar 进程，对没用过在线漫画的用户是纯亏。没起
  /// 来就这一轮跳过，等用户用过一次之后的检查自然会覆盖。
  void startUpdateChecks() {
    if (_updateCheckScheduler != null) return;
    final UpdateFeedService feed = updateFeedService;
    // 通知后端在这里（HomePage 已就绪、navigator 已存在）初始化：点击回调与
    // 冷启动回放都要有可跳转的 context。
    // 反馈回复提醒共用同一个通知后端：更新提醒的系统通知关着、反馈回复开着时，
    // 点击回调与冷启动回放也得挂上，否则点反馈通知拉起的 app 不会跳到那条反馈。
    unawaited(feed.warmUpNotifier());
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefsRepo,
      isKindEnabled: feed.isKindEnabled,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async {
          if (_mihonManager == null) return;
          await runOnlineMangaUpdateProbe(
            database: database,
            serviceFor: onlineMangaLibraryService,
            // 订阅且开了「新章自动下载」的条目：新章直接入队（设计稿 §5），
            // `auto_ocr` 取作品页 chip 的持久值。
            autoDownload: (
              OnlineMangaLibraryEntry entry,
              List<OnlineMangaChapter> chapters,
            ) =>
                mangaDownloadService.enqueueChapters(
              entry: entry,
              chapters: chapters,
              autoOcr: false,
            ),
          );
        },
        UpdateFeedKind.mangaExtension: () => _runMihonExtensionProbe(
              feed,
              UpdateFeedKind.mangaExtension,
              MihonMediaKind.manga,
            ),
      },
      // 自动更新开着时：扩展两个域在启动这一轮无视 24 小时间隔照查——自动安装
      // 只在「刚启动、还没碰过在线源」时做，被推迟的更新要在下次启动兑现。
      dueOnStart: mihonExtensionAutoUpdate
          ? const <UpdateFeedKind>{
              UpdateFeedKind.mangaExtension,
              }
          : const <UpdateFeedKind>{},
    );
    _updateCheckScheduler = scheduler;
    scheduler.start();
    // my-comic：安装统计 heartbeat（telemetry）已移除。
  }

  Future<void> stopUpdateChecks() async {
    final UpdateCheckScheduler? scheduler = _updateCheckScheduler;
    _updateCheckScheduler = null;
    await scheduler?.stop();
  }

  /// TODO-855: last prefs-version this process has reconciled its cache against.
  /// Used by [refreshPrefCacheIfChanged] so the warm-reuse :popup process only
  /// reloads its pref cache when the main app actually mutated a preference or
  /// switched profile, instead of unconditionally re-scanning the whole
  /// preferences table on every external lookup. -1 = not yet primed.
  int _lastSeenPrefsVersion = -1;

  /// Media history and search history, extracted for testability.
  late MediaHistoryRepository mediaHistoryRepo;

  /// Keyboard / gamepad shortcut bindings, persisted in preferences.
  final FushiShortcutRegistry shortcutRegistry = FushiShortcutRegistry();

  /// TODO-1375：媒体（阅读器 / 视频）是否打开的**可靠**通知源，专供 macOS 原生壳的
  /// 根 sidebar 显隐门控（main.dart 的 MacosWindow）。根因：sidebar 过去直接读
  /// `isMediaOpen`（= `_currentMediaSource != null`）在 MaterialApp.builder 里求值，
  /// 靠 `ref.watch(appProvider)` 重建——但 [openMedia] / [closeMedia] 只改
  /// `_currentMediaSource` 却**从不** notifyListeners，于是退出阅读器后 builder 不重跑、
  /// sidebar 卡在上一次求值的 `null`（永久消失 → 设置 tab 失去唯一切换出口 → 困死）。
  /// 用这个独立 ValueNotifier 在 open/close 里精确 set，配合 ValueListenableBuilder，
  /// 退出媒体必然重建并恢复 sidebar（单一真值源 + 保证通知），且不触发全局根重建。
  /// 非 macOS 平台不读它（阅读器是盖满的整页路由，与壳 sidebar 无关），纯 no-op。
  final ValueNotifier<bool> mediaOpenNotifier = ValueNotifier<bool>(false);

  /// 宽屏主导航 rail 用户手动选的展开（true）/ 收起（false）；null = 没选过，
  /// 按窗口尺寸档走默认（见 `adaptiveNavRailExtended`）。首页 rail 与桌面自绘
  /// 标题栏（按 rail 宽缩进标题）都听它，偏好装载后在 [initialise] 里同步。
  final ValueNotifier<bool?> navRailExpandedNotifier = ValueNotifier<bool?>(
    null,
  );

  /// rail 顶部菜单钮：记住并立即应用新的展开态。
  Future<void> setNavRailExpanded(bool expanded) async {
    navRailExpandedNotifier.value = expanded;
    await prefsRepo.setNavRailExpanded(expanded);
  }

  /// Polls physical game controllers and dispatches them into the shortcut /
  /// focus pipeline on platforms where the Flutter engine does not deliver
  /// gameButton* key events (desktop). No-op on Android/iOS (native key events)
  /// and on desktops without an implemented input source.
  late final GamepadService gamepadService = GamepadService(
    navigatorKey: navigatorKey,
    registry: shortcutRegistry,
    // TODO-1113 P3: lets the pointer route keep the ring lit on a mouse DOWN that
    // carries focus to a target while focus navigation is enabled (hover/move
    // still hide it). Live-read so toggling the preference takes effect at once.
    focusNavigationEnabled: () => experimentalFocusNavigationEnabled,
  );

  /// Resets the focus highlight to touch mode on every route push/pop so a ring
  /// lit by keyboard/gamepad navigation on one page is not carried onto the next
  /// (BUG-398). Wired into [MaterialApp.navigatorObservers] in main.dart. Same-
  /// route home-tab switches go through HomePage._selectTab, which calls the
  /// underlying [GamepadService.resetHighlightForScreenSwitch] directly.
  late final HighlightResetNavigatorObserver focusHighlightObserver =
      HighlightResetNavigatorObserver(
    gamepadService.resetHighlightForScreenSwitch,
  );

  Color? get systemPrimaryColor => themeNotifier.systemPrimaryColor;

  Future<void> refreshSystemPalette() {
    if (!_themeListenerAdded) {
      return Future<void>.value();
    }
    return themeNotifier.refreshSystemPalette();
  }

  /// Used to get the versioning metadata of the app. See [initialise].
  PackageInfo get packageInfo => _packageInfo;
  late PackageInfo _packageInfo;

  /// Whether [initialise] has completed successfully.
  bool get isInitialised => _isInitialised;
  bool _isInitialised = false;

  /// BUG-815: the currently-running [_initialiseOnce] future, or null when no
  /// init is in flight. [initialise] uses it to serialise concurrent callers so
  /// a second init can never race the first over the shared [_database] /
  /// repositories / [_isInitialised]. Cleared when the in-flight run completes.
  Future<void>? _initInFlight;

  /// Non-null if [initialise] threw; UI should display this instead of spinning.
  String? get initError => _initError;
  String? _initError;

  /// Non-null when init was refused because the on-disk DB was created by a
  /// NEWER build of Fushi than this one (downgrade protection). The UI shows a
  /// dedicated "update your app" notice with NO retry button — retry would fail
  /// identically and this is not a transient error. The DB file is left intact.
  FushiDatabaseDowngradeException? get downgradeError => _downgradeError;
  FushiDatabaseDowngradeException? _downgradeError;

  /// Non-null when init failed because the database could NOT be opened even
  /// after the full WAL/sidecar recovery ladder (TODO-905) — i.e. the main
  /// `fushi.db` itself is corrupt, not just a stale `-wal`/`-shm`. The UI shows
  /// an actionable "restore a backup / clear data" notice; a plain Retry would
  /// loop forever (the very bug TODO-905 fixes), so recovery already ran inside
  /// the open path and a fresh open of the same corrupt file would fail again.
  FushiDatabaseUnrecoverableException? get unrecoverableDbError =>
      _unrecoverableDbError;
  FushiDatabaseUnrecoverableException? _unrecoverableDbError;

  /// 非 null 表示库的 schema 低于本版本能升级的下限（[kMinSupportedSchemaVersion]，
  /// 或目录里只有改名前的 `hibiki.db`）：迁移阶梯的那一段已删除，开库被拒、库文件
  /// 原样保留。UI 显专屏提示先装 [kLegacySchemaBridgeAppVersion] 打开一次再更新；
  /// 不给重试——重试会以同样的方式失败。
  UnsupportedLegacySchemaException? get legacySchemaError => _legacySchemaError;
  UnsupportedLegacySchemaException? _legacySchemaError;

  /// BUG-815：非 null 表示桌面**配置了自定义数据根、但本次启动它不可达**（休眠 / 掉线 /
  /// 拔出的盘）。UI 据此显「数据位置未响应」逃生屏（重试 / 显式用默认位置启动），而**不**
  /// 静默把空默认库当真数据显示。真实数据仍原封不动躺在 [DataRootUnavailableException.
  /// configuredPath]。DB 尚未打开（init 在 resolve-data-roots 步就抛出），故重试是干净重跑。
  DataRootUnavailableException? get dataRootUnavailable => _dataRootUnavailable;
  DataRootUnavailableException? _dataRootUnavailable;

  /// Clears the error state and re-runs [initialise].
  Future<void> retryInitialise() async {
    // BUG-815: if an init started by main() is still IN FLIGHT — a slow cold
    // start that merely tripped the 20s loading watchdog, NOT a hang — do NOT
    // tear down / re-open the DB below. Closing [_database] out from under the
    // running init and spawning a SECOND concurrent init races them over the
    // shared _database / repositories / _isInitialised and surfaces as "all data
    // empty" on the home screen (mobile has no custom data root, so restarting —
    // a single clean init — restores everything). Await the in-flight attempt
    // instead: it completes (data appears) or sets _initError (whose own Retry
    // then runs cleanly, because [initialise]'s whenComplete has cleared
    // _initInFlight by that point).
    final Future<void>? inFlight = _initInFlight;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    // A previous attempt may have partially initialised resources. Tear down
    // the ones that would otherwise leak or double-register before re-running
    // (the late fields below are reassigned by initialise()).
    _initError = null;
    _downgradeError = null;
    _unrecoverableDbError = null;
    _legacySchemaError = null;
    _dataRootUnavailable = null;
    _isInitialised = false;
    notifyListeners();
    await initialise();
  }

  /// BUG-815：用户在「数据位置未响应」逃生屏点「仍用默认位置启动」时调用。置全局
  /// [AppPaths.forceDefaultRootForSession] 让本次进程用 `path_provider` 默认根打开
  /// （配置根不动、原盘数据一字节不动），再走常规 [retryInitialise]。仅本次有效：下次
  /// 启动重新探测配置根，盘醒了自动用回真实数据。绝不自动调用——只由用户显式点击触发。
  Future<void> retryInitialiseWithDefaultRoot() async {
    AppPaths.forceDefaultRootForSession = true;
    await retryInitialise();
  }

  /// Used for caching images and audio produced from media seeds.
  AppImageCacheManager get cacheManager =>
      _cacheManager ??= AppImageCacheManager();
  AppImageCacheManager? _cacheManager;

  /// Used to notify toggling incognito. Updates the app logo to and from
  /// grayscale.
  final ChangeNotifier incognitoNotifier = ChangeNotifier();

  /// Notifies app to stop showing any screens.
  final ChangeNotifier databaseCloseNotifier = ChangeNotifier();

  /// TODO-935 E0：应用数据根的唯一入口快照（启动期 [AppPaths.resolve] 解析一次）。
  /// [temporaryDirectory] / [appDirectory] / [databaseDirectory] 都从它派生，
  /// 后续 E1/E2/E3 换根只动 [AppPaths]，不必再碰这三个 getter 各自的调用点。
  AppPaths get appPaths => _appPaths;
  late AppPaths _appPaths;

  /// [appPaths] 是否已经解析。设置页副标题在极端早期 / 测试壳里可据此降级，
  /// 而不是用 `on Error` 吞掉 `late` 未初始化的异常（那会连真正的编程错误一起
  /// 掩盖）。
  AppPaths? get appPathsOrNull => _appPathsReady ? _appPaths : null;
  bool _appPathsReady = false;

  /// These directories are prepared at startup in order to reduce redundancy
  /// in actual runtime.
  /// Directory where data that may be dumped is stored.
  Directory get temporaryDirectory => _temporaryDirectory;
  late Directory _temporaryDirectory;

  /// Directory where data may be persisted.
  ///
  /// Ticket 02 起它的含义仍是 Content root（用户可见漫画内容）；Portable state
  /// 的落点（DB / prefs / 字体 / WebView2 / 日志）见 [stateDirectory]。
  Directory get appDirectory => _appDirectory;
  late Directory _appDirectory;

  /// Portable state 的持久状态根（`<programState>/state`）：DB、prefs、扩展、
  /// 自定义字体、WebView2 数据、日志都住在这里，随程序目录 + `userdata` 拷贝。
  Directory get stateDirectory => _appPaths.stateRoot;

  /// 自定义字体落地根（`<state>/custom_fonts`）。
  Directory get customFontsDirectory => _appPaths.customFontsRoot;

  /// Directory where database data is persisted.
  Directory get databaseDirectory => _databaseDirectory;
  late Directory _databaseDirectory;

  /// Directory where browser cache data may be persisted.
  Directory get browserDirectory => _browserDirectory;
  late Directory _browserDirectory;

  /// Directory where media source thumbnails may be persisted.
  Directory get thumbnailsDirectory => _thumbnailsDirectory;
  late Directory _thumbnailsDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs.
  Directory get exportDirectory => _exportDirectory;
  late Directory _exportDirectory;

  /// Directory where the browser media source saves web archives for offline
  /// use.
  Directory get webArchiveDirectory => _webArchiveDirectory;
  late Directory _webArchiveDirectory;

  /// Directory where media for export is stored for communication with
  /// third-party APIs. Fallback for failure.
  Directory get alternateExportDirectory => _alternateExportDirectory;
  late Directory _alternateExportDirectory;

  /// Directory used as a working directory for dictionary imports.
  Directory get dictionaryImportWorkingDirectory =>
      _dictionaryImportWorkingDirectory;
  late Directory _dictionaryImportWorkingDirectory;

  /// Used to fetch a media type by its unique key with constant time
  /// performance. Initialised with [populateMediaTypes] at startup.
  late Map<String, MediaType> mediaTypes;

  /// Used to fetch initialised sources by their unique key with constant
  /// time performance. Initialised with [populateMediaSources] at startup.
  late Map<MediaType, Map<String, MediaSource>> mediaSources;

  int get maximumSearchHistoryItems =>
      mediaHistoryRepo.maximumSearchHistoryItems;

  int get maximumMediaHistoryItems => mediaHistoryRepo.maximumMediaHistoryItems;

  /// Used to check whether or not the app is currently using a media source.
  bool get isMediaOpen => _currentMediaSource != null;

  /// Current active media source.
  MediaSource? get currentMediaSource => _currentMediaSource;
  MediaSource? _currentMediaSource;

  /// Current active media item.
  MediaItem? get currentMediaItem => _currentMediaItem;
  MediaItem? _currentMediaItem;

  /// The user's custom app-wide UI fonts, in the order they appear in the font
  /// library's `appUi` target — an ordered **fallback chain**, not a single
  /// face. Resolved and registered with the Flutter engine by [refreshAppFont];
  /// see [AppFontLoader.resolveAndLoadAll]. Empty means "no custom font", which
  /// hands the choice to the display language's system chain
  /// ([appUiFontChain]).
  List<String> _appFontFamilies = const <String>[];

  /// Primary app-chrome family = head of the resolved chain ([appFontChain]).
  /// Null keeps the platform default (non-CJK UI language with no custom font).
  String? get appFontFamily => appFontChain.isEmpty ? null : appFontChain.first;

  /// Everything after the primary family — feeds `TextStyle.fontFamilyFallback`.
  /// Null (not an empty list) when there is nothing to fall back to, so the
  /// style stays byte-identical to the pre-chain behaviour.
  List<String>? get appFontFallbacks {
    final List<String> chain = appFontChain;
    return chain.length > 1 ? chain.sublist(1) : null;
  }

  /// The full app-chrome font chain for the current display language, memoised
  /// on (locale, custom families) — [textStyle] is read on every theme rebuild,
  /// and rebuilding a dozen-entry chain each time is pure garbage.
  List<String> get appFontChain {
    final Locale uiLocale = appLocale;
    if (_cachedFontChainLocale == uiLocale &&
        identical(_cachedFontChainSource, _appFontFamilies)) {
      return _cachedFontChain;
    }
    _cachedFontChain = appUiFontChain(
      customFamilies: _appFontFamilies,
      locale: uiLocale,
      platform: defaultTargetPlatform,
    );
    _cachedFontChainLocale = uiLocale;
    _cachedFontChainSource = _appFontFamilies;
    return _cachedFontChain;
  }

  List<String> _cachedFontChain = const <String>[];
  Locale? _cachedFontChainLocale;
  List<String>? _cachedFontChainSource;

  /// Loads **all** enabled entries of the `appUiFonts` target as the app-wide UI
  /// font chain (registering each file with the Flutter engine via
  /// [AppFontLoader]) and rebuilds the theme. Falls back to the display
  /// language's system fonts when none is usable. Safe to call repeatedly — a
  /// no-op when the resolved chain is unchanged.
  Future<void> refreshAppFont() async {
    final ReaderSettings settings = ReaderSettings(_database);
    await settings.refreshFromDb();
    final List<String> families =
        await AppFontLoader.resolveAndLoadAll(settings.appUiFonts);
    if (listEquals(families, _appFontFamilies)) {
      return;
    }
    _appFontFamilies = families;
    notifyListeners();
  }

  /// Get the app-wide text style.
  ///
  /// The UI font follows the *display* language ([appLocale]), not the pinned
  /// Japanese reading language (直取 JapaneseLanguage.instance). With no user custom font,
  /// [fontFamily] is left null so the platform resolves the correct regional
  /// glyphs for the UI locale (e.g. Simplified-Chinese glyphs for `zh-CN`)
  /// instead of the Japanese kanji variants the old `NotoSansJP` + `ja`-locale
  /// pin forced on every Material platform. Japanese reader/dictionary content
  /// renders in WebView with its own CSS font, so it is unaffected by this
  /// app-chrome style.
  TextStyle get textStyle {
    final Locale uiLocale = appLocale;
    return TextStyle(
      fontFamily: appFontFamily,
      // 缺字回退链（[appUiFontChain]）：用户列表里剩下的字体 + 显示语言的系统
      // CJK 字体 + 其余 CJK 语言。没有它时，主字体缺字（典型如日文 face 上的
      // 简中「们/东」、中文 face 上的日文假名）会逐字掉进引擎默认 fallback，
      // 同一行里字形忽宽忽窄。
      fontFamilyFallback: appFontFallbacks,
      fontFeatures: const [FontFeature('liga', 0)],
      locale: uiLocale,
      textBaseline: _isIdeographicLocale(uiLocale)
          ? TextBaseline.ideographic
          : TextBaseline.alphabetic,
    );
  }

  /// CJK locales sit on the ideographic baseline; every other script uses the
  /// alphabetic baseline. Drives [textStyle]'s [TextStyle.textBaseline].
  static bool _isIdeographicLocale(Locale locale) {
    switch (locale.languageCode) {
      case 'ja':
      case 'zh':
      case 'ko':
        return true;
      default:
        return false;
    }
  }

  /// The app-wide [TextTheme]. [textStyle] carries the locale-aware font
  /// (fontFamily/fontFeatures/baseline); [FushiTypeScale] layers the editorial
  /// size/weight/line-height scale on top. Explicit sizes here survive the
  /// geometry merge `MaterialApp` performs, so this scale — not M3 defaults —
  /// is what renders.
  TextTheme get textTheme => FushiTypeScale.buildTextTheme(textStyle);

  ThemeMode get themeMode => themeNotifier.themeMode;
  ThemeData get theme => themeNotifier.theme;
  ThemeData get darkTheme => themeNotifier.darkTheme;

  ColorScheme buildColorScheme(Brightness brightness) =>
      themeNotifier.buildColorScheme(brightness);

  /// Get the current media item for use in tracking history and generating
  /// media for card creation based on media progress.
  MediaItem? getCurrentMediaItem() {
    if (_currentMediaSource == null) {
      return null;
    } else {
      return _currentMediaItem;
    }
  }

  /// Used to fetch an app locale by its locale tag with constant time
  /// performance. Initialised with [populateLocales] at startup.
  late Map<String, Locale> locales;

  /// Populate maps for locales at startup to optimise performance.
  void populateLocales() {
    /// A list of locales that the app will support at runtime. This is not
    /// related to supported target languages.
    final List<Locale> availableLocales = List<Locale>.unmodifiable(
      [
        const Locale('en', 'US'),
        const Locale('zh', 'CN'),
        const Locale('zh', 'HK'),
        const Locale('ja'),
        const Locale('ko'),
        const Locale('es'),
        const Locale('fr'),
        const Locale('de'),
        const Locale('pt', 'BR'),
        const Locale('ru'),
        const Locale('vi'),
        const Locale('th'),
        const Locale('id'),
        const Locale('ar'),
        const Locale('nl'),
        const Locale('it'),
        const Locale('tr'),
      ],
    );

    locales = Map<String, Locale>.unmodifiable(
      Map<String, Locale>.fromEntries(
        availableLocales.map(
          (locale) => MapEntry(locale.toLanguageTag(), locale),
        ),
      ),
    );
  }

  /// Populate maps for media types at startup to optimise performance.
  void populateMediaTypes() {
    /// A list of media types that the app will support at runtime.
    final List<MediaType> availableMediaTypes = List<MediaType>.unmodifiable(
      [ReaderMediaType.instance],
    );

    mediaTypes = Map<String, MediaType>.unmodifiable(
      Map<String, MediaType>.fromEntries(
        availableMediaTypes.map(
          (mediaType) => MapEntry(mediaType.uniqueKey, mediaType),
        ),
      ),
    );
  }

  /// Populate maps for media sources at startup to optimise performance.
  void populateMediaSources() {
    /// A list of media sources that the app will support at runtime.
    final Map<MediaType, List<MediaSource>> availableMediaSources = {
      ReaderMediaType.instance: [
        ReaderFushiSource.instance,
        // 漫画阅读源：format=='manga' 的行在打开时经
        // mediaSourceIdentifier='reader_manga' 路由到本源、进 MangaFushiPage。
        MangaFushiSource.instance,
      ],
    };

    mediaSources = Map<MediaType, Map<String, MediaSource>>.unmodifiable(
      availableMediaSources.map(
        (type, sources) => MapEntry(
          type,
          Map<String, MediaSource>.unmodifiable(
            Map<String, MediaSource>.fromEntries(
              sources.map(
                (source) => MapEntry(source.uniqueKey, source),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<Directory> prepareExportDirectory() async {
    final Directory exportDirectory = prepareExportDirectoryAt(
      appDirectory.path,
      onMigrationError: (Object e, StackTrace stack) => ErrorLogService.instance
          .log('AppModel.prepareExportDirectory.renameLegacy', e, stack),
    );
    await platformServices.directory
        .excludeFromMediaScanner(exportDirectory.path);

    return exportDirectory;
  }

  /// Preloads the app icon so that there is no pop-in.
  final Image appIcon = Image.asset(
    'assets/meta/icon.png',
  );

  /// Injects licenses to be displayed in the licenses page that aren't
  /// pre-included by Flutter upon compilation but are included as assets.
  Future<void> injectAssetLicenses() async {
    final packageNames = [
      'ebook-reader',
      // TODO-1368/BUG-691: "Hibiki Symbols" = renamed 3-glyph subset of
      // DejaVu Sans 2.37, embedded as a data: URI @font-face in popup.css.
      'dejavu-fonts',
      // Windows galgame overlay toolbar: reduced official Google font subset.
      'material-symbols-rounded',
      // 内置 AnkiConnect 插件包（assets/anki/，GPLv3，新手引导一键安装用）。
      'anki-connect',
      // galgame 校准 OCR 的 NFKC 映射表（gal_lookup_ocr_unicode.dart）由
      // Unicode Character Database 生成，Unicode License V3 要求随附许可。
      'unicode-data',
      // 复习（SRS）排程内核 native/fushi_fsrs 静态链进的两个 Rust crate：
      // fsrs-rs（BSD-3-Clause，open-spaced-repetition）与 ruzstd（MIT，Anki 新格式包解压）。
      'fsrs-rs',
      'ruzstd',
    ];

    for (String packageName in packageNames) {
      String licenseText =
          await rootBundle.loadString('assets/licenses/$packageName.txt');
      LicenseRegistry.addLicense(
        () => Stream<LicenseEntry>.value(
          LicenseEntryWithLineBreaks(<String>[packageName], licenseText),
        ),
      );
    }
  }

  /// TODO-1260：启动期对**数据根**做 IO 的关键 await 的超时上限。旧代码这些 await 若
  /// 因自定义数据根所在磁盘掉线而永不返回，会让 `initialise()` 无限挂起（首帧不出、
  /// 无限加载），而 `initialise()` 的顶层 try/catch 只接异常、接不住 hang。给这些 await
  /// 叠超时后，超时抛 [TimeoutException]→落顶层 catch→`_initError` 错误屏（有 Retry），
  /// 把「无逃生的无限 hang」变成「可重试的错误」。取 12s：远大于本机盘正常耗时（毫秒级），
  /// 只在盘真掉线 / 卡死时触发。
  static const Duration _initIoTimeout = Duration(seconds: 12);

  /// 给启动关键 IO 的 [Future] 叠一层超时：超时抛带**步骤名**的 [TimeoutException]，
  /// 让错误屏文案能指出卡在哪一步。
  Future<T> _guardInitIo<T>(String step, Future<T> future) => future.timeout(
        _initIoTimeout,
        onTimeout: () => throw TimeoutException(
          'AppModel.initialise 卡在「$step」超过 ${_initIoTimeout.inSeconds}s 未返回'
          '（多半是自定义数据根所在磁盘掉线 / 卡死）',
          _initIoTimeout,
        ),
      );

  /// Prepare application data and state to be ready of use upon starting up
  /// the application. [AppModel] is initialised in the main function before
  /// [runApp] is executed.
  Future<void> _prepareRuntimeDirectories() async {
    // Ticket 01：根解析只剩 Content root / Program state root 两个新根。
    // 旧 data_root 偏好、安装向导 bootstrap 与布局锚点都不再参与解析。
    _appPaths = await AppPaths.resolve();
    _appPathsReady = true;
    // TODO-1236：把上游 `fushi_audio` 的有声书持久根解析接到 `AppPaths`（它无法 import
    // AppPaths）。有声书属于用户可见内容，跟随 Content root。
    // Program state 的 DB / prefs / Mihon runtime / 更新包都落在 state 下；
    // 可丢弃缓存落在 cache 下；用户可见内容落在 Content root 下。
    _temporaryDirectory = _appPaths.cacheRoot;
    _appDirectory = _appPaths.contentRoot;
    _databaseDirectory = _appPaths.stateRoot;
  }

  /// Public entry point for app initialisation.
  ///
  /// BUG-815: serialises initialisation. If a run is already in flight (e.g. the
  /// loading-watchdog Retry firing while main()'s init is still going on a slow
  /// cold start), concurrent callers share that single run instead of starting a
  /// SECOND init that races the first over [_database] / repositories /
  /// [_isInitialised]. Once the run completes — success OR [_initError] (the body
  /// catches internally and never rethrows, so this future always resolves
  /// normally) — the guard clears, so a genuine retry-after-error still starts a
  /// fresh attempt.
  Future<void> initialise() {
    final Future<void>? existing = _initInFlight;
    if (existing != null) return existing;
    final Future<void> run = _initialiseOnce();
    _initInFlight = run;
    return run.whenComplete(() {
      if (identical(_initInFlight, run)) _initInFlight = null;
    });
  }

  /// One-shot initialisation body. Never call directly — always go through
  /// [initialise] so the in-flight guard holds.
  Future<void> _initialiseOnce() async {
    try {
      debugPrint('[Fushi] init: PackageInfo + DeviceInfo');

      /// Prepare entities that may be repeatedly used at runtime.
      _packageInfo = await PackageInfo.fromPlatform();
      await platformServices.init();

      debugPrint('[Fushi] init: directories (early, needed for DB)');
      // TODO-1260：这一步内部解析数据根（含对自定义数据根盘的 stat）。盘掉线时最易 hang，
      // 故写启动面包屑 + 叠超时（超时→错误屏 Retry，不再无限加载）。
      ErrorLogService.instance
          .markInitStep('resolve-data-roots（AppPaths.resolve / 数据根 stat）');
      await _guardInitIo('resolve-data-roots', _prepareRuntimeDirectories());

      // W2-7：存量书库目录 hoshi_books → fushi_books 就地改名。必须在 DB 打开
      // **之前**跑：v72 迁移在首次打开时把 extract_dir / image_url 里的目录段
      // 改写成新名，先改磁盘再开库，同一次启动内两侧一致。改名失败不阻塞
      // （上报错误日志，下次启动重试自愈；旧目录原地保留，数据零丢失）。
      migrateLegacyBooksDirectoryAt(
        _appDirectory.path,
        onMigrationError: (Object e, StackTrace stack) => ErrorLogService
            .instance
            .log('AppModel.migrateLegacyBooksDirectory', e, stack),
      );

      debugPrint('[Fushi] init: Drift database');
      ErrorLogService.instance.markInitStep('open-database（Drift 打开 fushi.db）');
      _database = FushiDatabase(_databaseDirectory.path);
      _databaseOpened = true;

      // Ticket 02：Portable copy（程序目录 + userdata）到另一个 Windows 用户 /
      // 机器后，把库内绝对路径从旧默认 Content root / 旧 Program state root 重基
      // 到本次解析出的根。必须在任何消费路径的仓库读库之前跑；失败只记录不阻塞
      // 启动（下次启动重试），自定义 Content root 不可达仍由 AppPaths.resolve 的
      // 逃生屏处理，不在这里静默降级。
      final PortableStateRebaseOutcome portableOutcome =
          await PortableStateRebase.reconcile(
        db: _database,
        paths: _appPaths,
        staleContentRoot: _appPaths.contentRootRebaseFrom,
      );
      if (portableOutcome.error != null) {
        ErrorLogService.instance.log(
          'AppModel.portableStateRebase',
          portableOutcome.error!,
        );
      } else if (portableOutcome.rebased) {
        debugPrint('[Fushi] portable state rebased: $portableOutcome');
      }

      // my-comic：Fushi 的备份恢复（`.fushi.zip` / 旧库导入）与互联/云同步已移除。
      // 全新 schema 从 `my_comic.db` 起步，不恢复、不迁移任何 Fushi 旧数据。
      //
      // 沙箱重定位（路径重基）依赖 Fushi 的全部媒体表，漫画-only schema 下不再
      // 运行；my-comic 是全新安装模型，没有需要从旧容器重基的存量路径。
      //
      // Fushi 的 sync 偏好迁移（SMB→WebDAV / 互联开关 / folder cache 清理）同样
      // 只服务已删除的同步功能，不再执行。

      /// Prepare all repositories (objects created first, then loaded in
      /// parallel to avoid serial await chains).
      _prefsRepo = PreferencesRepository(_database);
      mediaHistoryRepo = MediaHistoryRepository(_database);

      debugPrint('[Fushi] init: repositories (parallel)');
      await Future.wait(<Future<void>>[
        prefsRepo.loadFromDb(),
        mediaHistoryRepo.loadFromDb(),
      ]);
      prefsRepo.addListener(notifyListeners);
      navRailExpandedNotifier.value = prefsRepo.navRailExpanded;
      // 阅读器工具栏样式一次性强制悬浮（含各 Profile 快照），之后尊重用户选择。
      await prefsRepo.settleReaderToolbarStyleFloating();
      // 「漫画新章提醒」一次性重置为关闭（含各 Profile 快照），之后尊重用户选择。
      // 扩展更新提醒的已存值不动。
      await prefsRepo.settleUpdatesNotifyMangaChapterDefaultOff();
      // my-comic：SRS/Anki 挖词目标、推荐包回执与查词折叠开关都已随非漫画域移除。
      // settleSrsMiningTargetInstallDefault 会读 mined_sentences / pending_mine_queue，
      // 这两张表不在漫画-only schema 里，启动期不得调用。
      // 代理是**进程级**网络出口配置，却只存在偏好里；同步层的单例（GoogleDriveAuth 等）
      // 拿不到 AppModel，以前就只能各自裸连——BUG-1348 的谷歌云盘登录超时正是如此。四个
      // 代理读取器的绑定已下沉到 `PreferencesRepository.loadFromDb()`（偏好变得可读的
      // 那一刻），这样弹窗词典等**其它**入口不必各自记得补一行——漏一处就是一整个进程
      // 拿不到用户选的模式/凭据。这里只留更新专用的那个。
      appUpdateDownloadSourceReader = () => prefsRepo.updateDownloadSource;
      // 主入口与精简词典入口共用装配，并等系统代理就绪后再启动网络服务。
      await installAppNetworkBindings();
      _applyMemoryPolicy();
      final Map<String, String> prefsSnapshot = prefsRepo.prefsSnapshot;

      themeNotifier = ThemeNotifier(_database, () => textTheme);
      themeNotifier.loadFromPrefsSnapshot(prefsSnapshot);
      themeNotifier.addListener(notifyListeners);
      _themeListenerAdded = true;

      debugPrint('[Fushi] init: directories + system palette (parallel)');
      _thumbnailsDirectory =
          Directory(path.join(_appPaths.cacheRoot.path, 'thumbnails'));
      await _guardInitIo(
        'create-runtime-dirs',
        Future.wait(<Future<void>>[
          thumbnailsDirectory.create(recursive: true),
          refreshSystemPalette(),
        ]),
      );

      // W2-3：override 封面文件名的 hoshi://→fushi:// 前缀换代一次性清扫
      // （文件名是 identifier 的 hashCode，v73 改写库内 identifier 后旧文件
      // 不再命中）。pref 门控幂等；清扫不干净（rename 失败）不落标记，下次
      // 启动重试。放在 thumbnails 目录建好、DB 迁移已跑完之后。
      if (!prefsRepo.containsKey(kOverrideThumbnailPrefixMigratedPrefKey)) {
        final bool clean = await migrateOverrideThumbnailPrefixes(
          db: _database,
          thumbnailsDirectory: thumbnailsDirectory,
        );
        if (clean) {
          await prefsRepo.setPref(
              kOverrideThumbnailPrefixMigratedPrefKey, true);
        }
      }

      // my-comic：词典样式缓存与词典资源目录探测都属于已删除的查词域。
      // dictionary_metadata 不在漫画-only schema 里，启动期不得触碰。

      debugPrint('[Fushi] init: populate maps + locales');
      populateLocales();
      LocaleSettings.setLocaleRaw(appLocale.toLanguageTag());
      populateMediaTypes();
      populateMediaSources();

      await JapaneseLanguage.instance.initialise();

      MediaSource.setDatabase(_database);
      final readerSettings = ReaderSettings(_database);
      await readerSettings.loadFromPrefsSnapshot(prefsSnapshot);
      try {
        final int relocated = await readerSettings.healMissingFontFilePaths(
          customFontsDirectory.path,
        );
        if (relocated > 0) {
          debugPrint(
              '[Fushi] init: relocated $relocated stale custom-font path(s) to current custom_fonts dir');
        }
      } catch (e, stack) {
        ErrorLogService.instance.log('AppModel.healFontPaths', e, stack);
      }
      _appFontFamilies =
          await AppFontLoader.resolveAndLoadAll(readerSettings.appUiFonts);
      ReaderFushiSource.readerSettings = readerSettings;

      // Start polling physical controllers on platforms that need it (desktop);
      // start() is a no-op where the engine already delivers gameButton* keys.
      gamepadService.start();

      await Future.wait(<Future<void>>[
        for (MediaType type in mediaTypes.values)
          for (MediaSource source in mediaSources[type]!.values)
            source.initialise(),
      ]);

      // BUG-207: load the shortcut registry only AFTER ReaderFushiSource has
      // run initialise() (which populates its in-memory preference cache from
      // the DB). Reading shortcut_bindings_json before the cache is loaded saw
      // an empty cache -> null -> resetToDefaults, and getPreference's
      // cache-miss write-through clobbered the saved JSON with 's:null',
      // permanently dropping the user's custom keys on every launch. Mirrors the
      // profile-switch path (refreshPrefCache: refresh source caches first, then
      // loadShortcutRegistry).
      await loadShortcutRegistry(
        shortcutRegistry,
        ReaderFushiSource.instance,
        defaultTargetPlatform,
      );

      debugPrint(
          '[Fushi] init: search preload skipped (my-comic: no dictionary domain)');
      debugPrint('[Fushi] init: DONE');
      // TODO-1260：启动正常跑完，清掉启动步进面包屑（否则下次启动会误报上次 hang）。
      ErrorLogService.instance.clearInitStep();
      _isInitialised = true;
      // TODO-855: prime the prefs-version watermark from the freshly loaded
      // cache (keeps refreshPrefCacheIfChanged consistent if ever reused here).
      _lastSeenPrefsVersion = prefsRepo.prefsVersion;
      // my-comic：悬浮词典 / 弹窗词典 / 输入法同步等查词入口已移除。
      // 已迁移只读态（Fushi 迁移 P1-4）：不再自启互联服务——两版并存时端口
      // 固定必冲突（SyncServerPortInUseException 会打到用户脸上）；老版只保
      // 留「重新导出」通道。
      // 「功能模块」后台自启门（模块被关 = 它专属的后台**下次启动不再拉起**）。
      //
      // 快照只取一次：[moduleVisibility] 每次读都重新合成一个 Set，而下面这一串
      // 是同一帧里的连续判定，取一次既省分配也保证这一批门读的是同一份真值。
      //
      // 刻意**只判启动、不 stop**：用户在会话中途关模块时不切断进行中的任务
      // （正在跑的同步/下载/做种照常跑完），下次启动才不再拉起。
      final ModuleVisibility modules = moduleVisibility;
      // Start the LAN sync server now if hosting is enabled, so it runs app-wide
      // for the whole session instead of only while the sync settings page is on
      // screen (BUG-085). Fire-and-forget: a bind failure self-disables + is
      // logged and must never break app init.
      // 模块门（sync）：这两条都是「同步与备份 + 互联」专属后台——服务器要绑端口
      // 起发现广播，监听器要挂 DB 订阅并按写入推同步。关掉 sync 模块后不再自启，
      // 代价是本机不再作为互联 host 被别的设备发现/连接，合集增删也不再自动推送。
      // my-comic：Fushi Server / 云同步 / 互联后台服务已移除。
      // BUG-726：桌面端启动时把 <appSupport> 下已解压的浏览器扩展副本刷新到当前内置版本
      // （只在用户装过扩展、指纹不一致时重解压；没装过不落盘）。此前该副本只在手动跑
      // 「安装扩展」助手时写入 → app 升级后磁盘副本永远停在安装当天的旧版，扩展弹窗与
      // app 内弹窗漂移（BUG-621/688 修了也到不了用户浏览器）。fire-and-forget 不阻塞 init。
      // 模块门（browserExtension）：这份磁盘副本只服务「浏览器扩展」管理页的安装
      // 助手，模块关掉后那个页面本身也不存在。关掉后不再刷新副本，也不再算内置指纹
      // （查词响应里的 `extensionBuild` 字段随之省略——扩展模块已关，没有消费者）。
      // 平台判据走 modules（browserExtension 仅桌面），与函数内既有的桌面早退同向。
      // my-comic：浏览器查词扩展已移除。
      // my-comic：texthooker / 词典自动更新等查词后台已移除。
      // my-comic：BT/torrent 番剧下载后台已移除。
      // 推荐包（9.5 GB zip）的包目录进场收尾：删掉「已导入」的残包、搬改名前的旧
      // 半截文件，再把下载阶段对齐磁盘。
      //
      // BUG-2109：收尾必须挂在**启动必经路径**上，不能挂新手引导页 ——
      // 推荐包本身是一份含 settings 类目的备份，导入时 `preferences` 表被整层
      // 替换，`onboarding_completed` 随之变成 true，导入后的那次重启根本不会再
      // 打开引导页，9.5 GB 就永久留在盘上。
      //
      // BUG-2109：但它**不能**挂进 `_guardInitIo` 那批启动关键 IO：那层是 12s
      // 硬超时，同批其它任务全是毫秒级 mkdir，而删 9.5 GB（外置卡 / FAT32 /
      // 网络盘）超 12s 完全可能 —— 清个残包把启动干成错误屏。它不是启动关键
      // IO，放到这里 fire-and-forget。
      //
      // BUG-2109：同时这也是 `stage` 在新进程里唯一的对盘点。不跑它，stage 永远
      // 停在 idle，设置 → 系统里那行（判据是 `isActive`）就不渲染：下完没导入就
      // 关 app 的用户，重开后磁盘上躺着的 9.5 GB 既看不见也导不了。
      notifyListeners();
    } on DataRootUnavailableException catch (e, stack) {
      // BUG-815: a custom data root IS configured but is currently unreachable
      // (slow/sleeping/disconnected drive). AppPaths.resolve threw INSTEAD of
      // silently deriving the empty default location — the DB was never opened
      // (_databaseOpened stays false, so retry is a clean re-run). Surface a
      // dedicated "data location unavailable" escape screen (Retry / explicit
      // opt-in-to-default); do NOT set _initError so the generic error screen
      // doesn't shadow it. The real data is untouched on e.configuredPath.
      debugPrint('[Fushi] init PAUSED (data root unavailable): $e\n$stack');
      ErrorLogService.instance
          .log('AppModel.initialise.dataRootUnavailable', e, stack);
      _dataRootUnavailable = e;
      notifyListeners();
    } on FushiDatabaseDowngradeException catch (e, stack) {
      // The DB is newer than this build. drift refused to open it WITHOUT
      // touching the file (no DROP / migration ran). Surface a dedicated,
      // non-retryable notice instead of the generic init-error screen, and
      // STOP — never continue init, never delete or rebuild the DB.
      debugPrint('[Fushi] init REFUSED (DB downgrade): $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise.downgrade', e, stack);
      _downgradeError = e;
      _initError = '$e';
      notifyListeners();
    } on UnsupportedLegacySchemaException catch (e, stack) {
      // 库比本版本能升级的下限还老（低于最低 schema 门槛，或只有改名前的
      // hibiki.db）。开库在任何迁移语句之前被拒，文件原样保留。与降级同理：专屏、
      // 不重试、不继续 init、绝不删库重建。
      debugPrint('[Fushi] init REFUSED (legacy schema): $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise.legacySchema', e, stack);
      _legacySchemaError = e;
      _initError = '$e';
      notifyListeners();
    } on FushiDatabaseUnrecoverableException catch (e, stack) {
      // TODO-905: the WAL/sidecar recovery ladder already ran inside the open
      // path and exhausted — the main fushi.db is corrupt. Surface a dedicated,
      // actionable notice (restore backup / clear data) instead of looping the
      // generic Retry button forever against the same un-openable file.
      debugPrint('[Fushi] init FAILED (DB unrecoverable): $e\n$stack');
      ErrorLogService.instance
          .log('AppModel.initialise.unrecoverableDb', e, stack);
      _unrecoverableDbError = e;
      _initError = '$e';
      notifyListeners();
    } catch (e, stack) {
      debugPrint('[Fushi] init FAILED: $e\n$stack');
      ErrorLogService.instance.log('AppModel.initialise', e, stack);
      _initError = '$e';
      notifyListeners();
    }
  }

  /// Reload the preference cache from the database, e.g. after a profile
  /// switch has written new values.
  Future<void> refreshPrefCache() async {
    await prefsRepo.refreshFromDb();
    navRailExpandedNotifier.value = prefsRepo.navRailExpanded;
    for (final sourceMap in mediaSources.values) {
      for (final source in sourceMap.values) {
        await source.refreshPreferencesFromDb();
      }
    }
    await themeNotifier.refreshFromDb();
    // Shortcut bindings are profile-scoped: reload the live registry from the
    // (now-refreshed) source preference so a profile switch takes effect
    // immediately instead of only after an app restart.
    await loadShortcutRegistry(
      shortcutRegistry,
      ReaderFushiSource.instance,
      defaultTargetPlatform,
    );
    // TODO-855: after a full reload the in-memory cache holds the latest DB
    // version, so advance the watermark to keep refreshPrefCacheIfChanged from
    // immediately reloading again.
    _lastSeenPrefsVersion = prefsRepo.prefsVersion;
  }

  /// TODO-855: refresh the preference cache only when the persisted prefs
  /// version in the DB differs from the last value this process reconciled
  /// against. This is the warm-reuse :popup hot path: a separate process whose
  /// cache survives across external lookups but never observes the main app's
  /// profile switches / preference edits directly. A single indexed
  /// [PreferencesRepository.readPrefsVersionFromDb] row read replaces the
  /// previous unconditional full-table [refreshPrefCache] on every lookup; the
  /// expensive reload now happens only when something actually changed.
  Future<void> refreshPrefCacheIfChanged() async {
    final int dbVersion = await prefsRepo.readPrefsVersionFromDb();
    if (dbVersion == _lastSeenPrefsVersion) return;
    await refreshPrefCache();
    // refreshPrefCache already advanced _lastSeenPrefsVersion from the reloaded
    // cache; align it to the value we just read so a concurrent writer between
    // the read and the reload can still be detected on the next call.
    _lastSeenPrefsVersion = dbVersion;
  }

  // ── sync pref helpers (delegated to PreferencesRepository) ──────────

  dynamic _getPref(String key, {dynamic defaultValue}) =>
      prefsRepo.getPref(key, defaultValue: defaultValue);

  Future<void> _setPref(String key, dynamic value) =>
      prefsRepo.setPref(key, value);

  // _bindLocalAudioDbForNativeHandler moved to LocalAudioManager.bindForNativeHandler

  // _rowToDictionary, _dictionaryToCompanion, _persistDictionary
  // moved to DictionaryRepository.

  // ── Theme delegates (logic moved to ThemeNotifier) ──────────────────

  static Map<String, ThemePreset> get themePresets =>
      ThemeNotifier.themePresets;

  static ColorScheme buildPresetColorScheme(
    ThemePreset preset,
    Brightness brightness, {
    bool pureBlack = false,
  }) =>
      ThemeNotifier.buildPresetColorScheme(
        preset,
        brightness,
        pureBlack: pureBlack,
      );

  static String themeLabel(String key) => ThemeNotifier.themeLabel(key);

  String get appThemeKey => themeNotifier.appThemeKey;
  Future<void> setAppThemeKey(String key) => themeNotifier.setAppThemeKey(key);

  /// 阅读器纸色用的主题键：偏好原值（可能是已删的旧预设 id，如 ecru-theme），
  /// 让存量用户的阅读器纸色照旧生效（2026-10 预设精简时阅读器纸色不动）。
  String get readerThemeKey => themeNotifier.storedAppThemeKey;

  /// 「纯黑深色背景」开关（原「纯黑」预设的语义）。
  bool get pureBlackDark => themeNotifier.pureBlackDark;
  Future<void> setPureBlackDark(bool value) =>
      themeNotifier.setPureBlackDark(value);

  // TODO-930: multi custom theme list delegation. The UI (theme swatch row +
  // CustomThemePage) talks to AppModel, so mirror ThemeNotifier's list API here
  // exactly like the legacy flat custom_theme_* getters above.
  List<CustomThemeEntry> get customThemes => themeNotifier.customThemes;
  CustomThemeEntry? customThemeById(String id) =>
      themeNotifier.customThemeById(id);
  String? get selectedCustomThemeId => themeNotifier.selectedCustomThemeId;
  CustomThemeEntry? get activeCustomThemeEntry =>
      themeNotifier.activeCustomThemeEntry;
  Future<void> upsertCustomTheme(CustomThemeEntry entry) =>
      themeNotifier.upsertCustomTheme(entry);
  Future<void> deleteCustomTheme(String id) =>
      themeNotifier.deleteCustomTheme(id);
  Future<void> selectCustomTheme(String id) =>
      themeNotifier.selectCustomTheme(id);

  /// 自定义条目在当前系统取色 / 纯黑 / 墨水屏下的配色（编辑页预览与设置色卡）。
  /// 走 [theme_notifier.buildCustomThemeEntryColorScheme] 同一条解析链，
  /// 全局状态取本门面的 getter——UI 只跟 AppModel 说话，不穿透到
  /// [themeNotifier]。
  ColorScheme buildCustomThemeColorScheme(
    CustomThemeEntry entry,
    Brightness brightness,
  ) =>
      theme_notifier.buildCustomThemeEntryColorScheme(
        entry,
        brightness,
        einkMode: einkMode,
        pureBlack: pureBlackDark,
        systemPrimaryColor: systemPrimaryColor,
      );

  String get brightnessMode => themeNotifier.brightnessMode;
  Future<void> setBrightnessMode(String mode) =>
      themeNotifier.setBrightnessMode(mode);

  /// 墨水屏模式（E-ink）：全局纯黑白主题 + 关动画 + 阅读器/弹窗高对比。
  bool get einkMode => themeNotifier.einkMode;
  Future<void> setEinkMode(bool value) => themeNotifier.setEinkMode(value);

  /// 功能层表面材质（导航 / 底部弹层 / 对话框的毛玻璃），与颜色主题正交。
  FushiGlassMaterial get glassMaterial => themeNotifier.glassMaterial;
  Future<void> setGlassMaterial(FushiGlassMaterial value) =>
      themeNotifier.setGlassMaterial(value);

  /// BUG-1718：查词弹窗「CSS 尾段」供给器——词典包自带 CSS（`FushiDicts.dictionaryStyles`，
  /// mdx 导入落成的词典目录 `styles.css`）+ 用户全局/单典自定义 CSS，随查词响应按 revision
  /// 门控下发给浏览器扩展弹窗。与 in-app 弹窗注入的 `window.dictionaryStyles` /
  /// `globalDictCSS` / `customDictCSS` 同源（popup_settings_injection 的 tail 段），
  /// 三镜像消费方是同一份 `popup.js`，不得只喂其中一处。
  ///
  /// 实例按三个数据源缓存，避免在查词热路径上重复哈希数百 KB 的词典 CSS：
  /// 词典自带样式（可达数百 KB）按 **map 身份** 判——`FushiDicts._rebuildStylesCache` 只在
  /// 词典集合变化时整体换新实例；用户自定义 CSS（每次读偏好都重新 jsonDecode，身份必变但
  /// 体量极小）按 **内容** 判。任一变化即重建实例 ⇒ 新 revision ⇒ 扩展下次查词全量取一次。
  double get customAppUiScale => themeNotifier.customAppUiScale;
  double get autoAppUiScale => themeNotifier.autoAppUiScale;
  double get appUiScale => themeNotifier.appUiScale;
  Future<void> setAppUiScale(double value) =>
      themeNotifier.setAppUiScale(value);
  double resolveAppUiScaleForViewport({
    required Size viewport,
    required TargetPlatform platform,
  }) =>
      themeNotifier.resolveAppUiScaleForViewport(
        viewport: viewport,
        platform: platform,
      );

  bool get isDarkMode => themeNotifier.isDarkMode;

  Color get customThemeSeed => themeNotifier.customThemeSeed;
  Future<void> setCustomThemeSeed(Color c) =>
      themeNotifier.setCustomThemeSeed(c);

  bool get customThemeDark => themeNotifier.customThemeDark;
  Future<void> setCustomThemeDark(bool v) =>
      themeNotifier.setCustomThemeDark(v);

  // BUG-2187：阅读器等 ColorScheme 之外的消费者读「当前生效自定义主题」的角色色
  // 必须走这几个 getter（条目优先、扁平偏好兜底、非自定义 key 恒 null），
  // 不得再直接读下面的 legacy 扁平 getter。
  Color? get activeCustomThemeFontColor =>
      themeNotifier.activeCustomThemeFontColor;
  Color? get activeCustomThemeBackgroundColor =>
      themeNotifier.activeCustomThemeBackgroundColor;
  Color? get activeCustomThemeSelectionColor =>
      themeNotifier.activeCustomThemeSelectionColor;
  Color? get activeCustomThemeLinkColor =>
      themeNotifier.activeCustomThemeLinkColor;
  Color? get activeCustomThemeSurfaceColor =>
      themeNotifier.activeCustomThemeSurfaceColor;
  bool get activeCustomThemeNeutralDerived =>
      themeNotifier.activeCustomThemeNeutralDerived;

  Color? get customThemeFontColor => themeNotifier.customThemeFontColor;
  Future<void> setCustomThemeFontColor(Color? c) =>
      themeNotifier.setCustomThemeFontColor(c);

  Color? get customThemeBackgroundColor =>
      themeNotifier.customThemeBackgroundColor;
  Future<void> setCustomThemeBackgroundColor(Color? c) =>
      themeNotifier.setCustomThemeBackgroundColor(c);

  Color? get customThemeSelectionColor =>
      themeNotifier.customThemeSelectionColor;
  Future<void> setCustomThemeSelectionColor(Color? c) =>
      themeNotifier.setCustomThemeSelectionColor(c);

  Color? get customThemePrimaryColor => themeNotifier.customThemePrimaryColor;
  Future<void> setCustomThemePrimaryColor(Color? c) =>
      themeNotifier.setCustomThemePrimaryColor(c);

  Color? get customThemeSecondaryColor =>
      themeNotifier.customThemeSecondaryColor;
  Future<void> setCustomThemeSecondaryColor(Color? c) =>
      themeNotifier.setCustomThemeSecondaryColor(c);

  Color? get customThemeTertiaryColor => themeNotifier.customThemeTertiaryColor;
  Future<void> setCustomThemeTertiaryColor(Color? c) =>
      themeNotifier.setCustomThemeTertiaryColor(c);

  Color? get customThemeContainerColor =>
      themeNotifier.customThemeContainerColor;
  Future<void> setCustomThemeContainerColor(Color? c) =>
      themeNotifier.setCustomThemeContainerColor(c);

  Color? get customThemeSentenceAudioHighlightColor =>
      themeNotifier.customThemeSentenceAudioHighlightColor;
  Future<void> setCustomThemeSentenceAudioHighlightColor(Color? c) =>
      themeNotifier.setCustomThemeSentenceAudioHighlightColor(c);

  /// TODO-977: 全局音频高亮颜色（与阅读器主题解耦），委托 ThemeNotifier。
  Color? get audioHighlightColor => themeNotifier.audioHighlightColor;
  Future<void> setAudioHighlightColor(Color? c) =>
      themeNotifier.setAudioHighlightColor(c);

  Color? get customThemeLinkColor => themeNotifier.customThemeLinkColor;
  Future<void> setCustomThemeLinkColor(Color? c) =>
      themeNotifier.setCustomThemeLinkColor(c);

  // TODO-928: 委托层同步删 `brightnessMode` 参数（不再透传）。
  Future<void> applyCustomTheme({
    required Color seed,
    Color? fontColor,
    Color? backgroundColor,
    Color? selectionColor,
    Color? primaryColor,
    Color? secondaryColor,
    Color? tertiaryColor,
    Color? containerColor,
    Color? sentenceAudioHighlightColor,
    Color? linkColor,
  }) =>
      themeNotifier.applyCustomTheme(
        seed: seed,
        fontColor: fontColor,
        backgroundColor: backgroundColor,
        selectionColor: selectionColor,
        primaryColor: primaryColor,
        secondaryColor: secondaryColor,
        tertiaryColor: tertiaryColor,
        containerColor: containerColor,
        sentenceAudioHighlightColor: sentenceAudioHighlightColor,
        linkColor: linkColor,
      );

  // targetLanguage getter 已删（2026-07-26，用户指令）：它恒返回
  // JapaneseLanguage.instance，是个假装可配置的间接层（语言选择从未有 UI，
  // en/zh 子类与 setter 已于 2026-06-05 删除）。日语专属功能（振假名/音高/
  // 字体/字幕语言码/helloWorld 预热等）现直接引用 JapaneseLanguage.instance。
  // 注意：查词流水线语言无关（18 语言变换表全量加载是有意设计），从不经过
  // 这个概念。守卫：test/models/target_language_removed_guard_test.dart。

  /// Get the current app locale from persisted preferences.
  /// Defaults to system locale if supported, otherwise en-US.
  Locale get appLocale {
    String? saved = _getPref('app_locale');
    if (saved != null && saved.isNotEmpty && locales.containsKey(saved)) {
      return locales[saved]!;
    }

    // Match system locale to available locales.
    final systemLocale = PlatformDispatcher.instance.locale;
    final systemTag = systemLocale.toLanguageTag();
    if (locales.containsKey(systemTag)) {
      return locales[systemTag]!;
    }
    // Try language-only match (e.g. "zh" matches "zh-CN").
    for (final entry in locales.entries) {
      if (entry.value.languageCode == systemLocale.languageCode) {
        return entry.value;
      }
    }

    return locales.values.first;
  }

  /// Persist a new app locale in preferences and switch the UI language.
  ///
  /// Desktop (TODO-960): live hot-reload, **never** restart the process. The
  /// desktop restart path (`Process.start(detached) + exit(0)`) races the
  /// Windows single-instance mutex (`windows/runner/main.cpp`): the freshly
  /// spawned process reaches `CreateMutexW` before the old process has called
  /// `exit(0)`, gets `ERROR_ALREADY_EXISTS`, fronts the old window then
  /// `return EXIT_SUCCESS` (self-terminates) — moments later the old process
  /// also exits, leaving no process at all (app closes, never reopens). So on
  /// desktop we mutate [LocaleSettings] in place and [notifyListeners]; because
  /// the bulk of the UI reads the global Method A `t` (which does NOT rebuild
  /// on a [LocaleSettings] change by itself), the root widget tree is
  /// additionally remounted via a locale-keyed [Key] at [main]'s
  /// [TranslationProvider] (see `_FushiReaderAppState.build`).
  ///
  /// Mobile (Android/iOS) keeps the native restart path (`restart_app` plugin
  /// rebuilds the Activity/scene — no mutex race). The data-root migration
  /// path still restarts on every platform via its own call site
  /// (`data_root.part.dart`), and is intentionally unaffected by this method.
  Future<void> setAppLocale(String localeTag) async {
    await _setPref('app_locale', localeTag);
    LocaleSettings.setLocaleRaw(localeTag);
    if (isDesktopPlatform) {
      notifyListeners();
      return;
    }
    if (platformServices.lifecycle.supportsRestart) {
      await platformServices.lifecycle.restartApp();
    } else {
      notifyListeners();
    }
  }

  /// Persist a new last selected dictionary format. This is called when the
  /// user changes the import format in the dictionary menu.
  Future<void> setLastSelectedDictionaryFormat(
      DictionaryFormat dictionaryFormat) async {
    String lastDictionaryFormatName = dictionaryFormat.uniqueKey;
    await _setPref('last_selected_dictionary_format', lastDictionaryFormatName);
  }

  Future<void> setLastSelectedModelName(String modelName) =>
      prefsRepo.setLastSelectedModelName(modelName);

  Future<void> setLastSelectedDeck(String deckName) =>
      prefsRepo.setLastSelectedDeck(deckName);

  int get currentHomeTabIndex => prefsRepo.currentHomeTabIndex;

  Future<void> setCurrentHomeTabIndex(int index) =>
      prefsRepo.setCurrentHomeTabIndex(index);

  /// 启动页模块（`null` = 默认，底栏第一个可见页），见
  /// [PreferencesRepository.startupModule]。
  ModuleId? get startupModule => prefsRepo.startupModule;

  Future<void> setStartupModule(ModuleId? module) =>
      prefsRepo.setStartupModule(module);

  MangaDownloadService? _mangaDownloadService;
  MangaDownloadService get mangaDownloadService =>
      _mangaDownloadService ??= MangaDownloadService(
        database: database,
        serviceFor: onlineMangaLibraryService,
        // 任务开始运行时现读：排队任务按真正开始那一刻的开关落盘。
        saveAsCbz: () => prefsRepo.downloadSaveAsCbz,
      );

  /// 启动章节下载 worker：复位上次进程死亡留下的 `running` 行并开始消费。幂等。
  Future<void> startMangaDownloads() => mangaDownloadService.start();

  /// Mihon 扩展生态宿主（Android 原生 / Windows、macOS 内置 Java sidecar）。
  ///
  /// 与漫画下载服务一样按首次访问懒建：普通书架和在线源浏览不会启动 JVM，
  /// 只有进入漫画源/漫画扩展/来源设置才读取扩展数据库；桌面 runtime 又会等到
  /// 第一次真正调用扩展时才启动 M-Extension-Server。
  MihonManager? _mihonManager;
  MihonManager get mihonManager {
    _onlineSourcesTouched = true;
    return _mihonManager ??= _createMihonManager(MihonMediaKind.manga);
  }

  /// 视频（Aniyomi）扩展的 manager：与 [mihonManager] 共用同一个运行时，只是
  /// 三张扩展表按 `media_kind` 分片、默认仓库不同、根目录不同（`mihon_anime/`，
  /// 扩展 APK / 暂存 / 封面缓存各自独立，删一边的缓存不波及另一边）。
  MihonManager? _animeMihonManager;
  MihonManager get animeMihonManager {
    _onlineSourcesTouched = true;
    return _animeMihonManager ??= _createMihonManager(MihonMediaKind.anime);
  }

  /// 本进程里有没有任何调用方取过 [mihonManager] / [animeMihonManager]。
  ///
  /// 这是扩展后台自动更新的「空闲」判据。两个公开 getter 只在在线源相关的地方被
  /// 取：漫画 / 视频在线源页、扩展页、在线漫画阅读与章节下载
  /// （[onlineMangaLibraryService]）、在线视频播放、全局搜索、桌面 ctl 在线路由。
  /// 运行时没有「此刻正有会话在用」的信号，装完要让运行时失效（桌面 = 重启
  /// sidecar）——于是取最保守的判据：**一旦碰过就算在用**，本进程不再自动装，
  /// 推迟到下次启动。自动更新自己建 manager 走 [_mihonManagerForAutoUpdate]，
  /// 不经公开 getter，不会把自己判成「在用」。
  bool _onlineSourcesTouched = false;

  /// 「后台自动更新扩展」开关（漫画与视频扩展共用，默认关）。
  bool get mihonExtensionAutoUpdate =>
      prefsRepo.getPref(kMihonExtensionAutoUpdatePref, defaultValue: false)
          as bool;

  Future<void> setMihonExtensionAutoUpdate(bool value) =>
      prefsRepo.setPref(kMihonExtensionAutoUpdatePref, value);

  /// 后台扩展检查要用的 manager：已建就用；没建时只有自动更新开着、平台与合规
  /// 门都过、且库里确有这个生态的已装扩展，才为它建一个（建 manager 不起
  /// sidecar，sidecar 要等真去装时才起）。其余情况返回 null，这一轮跳过——与
  /// 自动更新关着时「没用过在线源就不查」的既有行为一致。
  Future<MihonManager?> _mihonManagerForAutoUpdate(MihonMediaKind kind) async {
    final MihonManager? existing = switch (kind) {
      MihonMediaKind.manga => _mihonManager,
      MihonMediaKind.anime => _animeMihonManager,
    };
    if (existing != null) return existing;
    if (!mihonExtensionAutoUpdate || !MihonRuntimeFactory.isSupported) {
      return null;
    }
    final StoreRestrictedCapability capability = switch (kind) {
      MihonMediaKind.manga => StoreRestrictedCapability.onlineMangaSource,
      MihonMediaKind.anime => StoreRestrictedCapability.onlineVideoSource,
    };
    if (!capability.isAvailable) return null;
    final List<MangaExtensionRow> installed = await database.getMangaExtensions(
      mediaKind: kind.dbValue,
    );
    if (installed.isEmpty) return null;
    final MihonManager manager = switch (kind) {
      MihonMediaKind.manga => _mihonManager ??= _createMihonManager(
        MihonMediaKind.manga,
      ),
      MihonMediaKind.anime => _animeMihonManager ??= _createMihonManager(
        MihonMediaKind.anime,
      ),
    };
    // 构造时已经起了 initialise（读库 + 拉索引）；等它完成再比版本，否则
    // installed 还是空表。
    await manager.initialise();
    return manager;
  }

  /// 一个扩展域的后台检查（漫画 / 视频同构）。
  Future<void> _runMihonExtensionProbe(
    UpdateFeedService feed,
    UpdateFeedKind kind,
    MihonMediaKind mediaKind,
  ) async {
    final MihonManager? manager = await _mihonManagerForAutoUpdate(mediaKind);
    if (manager == null) return;
    await runMihonExtensionUpdateProbe(
      feed: feed,
      kind: kind,
      refreshStores: manager.refreshStores,
      available: () => manager.available,
      installed: () => manager.installed,
      autoUpdate: mihonExtensionAutoUpdate
          ? MihonExtensionAutoUpdater(
              isIdle: () => !_onlineSourcesTouched,
              install:
                  (
                    List<MihonAvailableExtension> targets,
                    bool Function() isCancelled,
                  ) => manager.installMany(
                    targets,
                    upgrade: true,
                    // 签名变了的在 SIGNATURE_CHANGED 门就进 failed；这里再保证
                    // 后台绝不替用户信任任何新签名。
                    trustSigner: false,
                    isCancelled: isCancelled,
                  ),
            )
          : null,
    );
  }

  /// 两个生态共用的扩展宿主：桌面端一个 sidecar JVM（`-Xmx512m`，两个太贵），
  /// Android 原生宿主本来就是进程单例。生命周期归这里管——两个 manager 都以
  /// `ownsRuntime: false` 构造，退出时的 sidecar 关闭由 [_mihonRuntimeExitShutdown]
  /// 登记一次，[dispose] 也只关一次。数据目录沿用漫画那份 `mihon/`（sidecar 的
  /// 偏好 / 日志 / cookie 真值都在那下面，改路径等于让存量用户重新登录源站）。
  MihonRuntime? _mihonRuntime;
  ExitFlushCallback? _mihonRuntimeExitShutdown;
  Future<void>? _mihonRuntimeShutdown;
  MihonRuntime get _sharedMihonRuntime {
    final MihonRuntime? existing = _mihonRuntime;
    if (existing != null) return existing;
    if (!MihonRuntimeFactory.isSupported) {
      throw UnsupportedError(
        'Mihon extensions are unavailable on this platform',
      );
    }
    final MihonRuntime runtime = MihonRuntimeFactory.create(
      Directory(path.join(databaseDirectory.path, 'mihon')),
    );
    _mihonRuntime = runtime;
    if (MihonRuntimeFactory.usesDesktopSidecar) {
      _mihonRuntimeExitShutdown = ExitFlushRegistry.instance.register(
        _shutdownMihonRuntime,
      );
    }
    return runtime;
  }

  Future<void> _shutdownMihonRuntime() =>
      _mihonRuntimeShutdown ??= _mihonRuntime?.dispose() ?? Future<void>.value();

  MihonManager _createMihonManager(MihonMediaKind kind) {
    final MihonRuntime runtime = _sharedMihonRuntime;
    final Directory root = Directory(
      path.join(
        databaseDirectory.path,
        switch (kind) {
          MihonMediaKind.manga => 'mihon',
          MihonMediaKind.anime => 'mihon_anime',
        },
      ),
    );
    final MihonManager manager = MihonManager(
      database: database,
      rootDirectory: root,
      runtime: runtime,
      kind: kind,
      ownsRuntime: false,
      coverCacheMaxAge: Duration(days: prefsRepo.mangaCoverCacheMaxAgeDays),
      // 扩展仓库不内置（2026-10-09）：新装为空，由用户自己添加。
      // 只有真实 app 去拉扩展的公开下载量（一次 5 MB 量级的 GitHub API
      // 请求）；单测构造的 manager 一律不碰外网。
      fetchDownloadCounts: true,
    );
    unawaited(manager.initialise());
    return manager;
  }

  /// 按 runtime 分派在线漫画书架服务。
  ///
  /// 书架条目和作品页手上只有 `bookKey` + 描述符里的 runtime，不知道该找哪个
  /// 运行时；这里是唯一的分派点。
  ///
  /// **旧 Aidoku 分支刻意不碰 [mihonManager]**：Aidoku 宿主已整体移除，这一支只
  /// 服务旧版本留下的书架条目（[LegacyAidokuLibraryAdapter] 一律回报不可用）；
  /// 在没有 Mihon 宿主的 iOS 上去取 mihonManager 会直接抛 `UnsupportedError`，
  /// 把「打开这本书」变成崩溃。
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) {
    switch (runtime) {
      case OnlineMangaRuntimeKind.mihon:
        final MihonManager manager = mihonManager;
        return OnlineMangaLibraryService(
          database: manager.database,
          rootDirectory: manager.rootDirectory,
          adapter: MihonLibraryAdapter(manager),
          updateFeed: updateFeedService,
        );
      case OnlineMangaRuntimeKind.aidoku:
        return OnlineMangaLibraryService(
          database: database,
          rootDirectory: aidokuLibraryRoot,
          adapter: const LegacyAidokuLibraryAdapter(),
          updateFeed: updateFeedService,
        );
      case OnlineMangaRuntimeKind.interconnect:
        // my-comic：设备互联已删除；旧书架条目保持可解析但不再可达。
        throw UnsupportedError(
          'Interconnect manga runtime is not available in my-comic',
        );
      case OnlineMangaRuntimeKind.local:
        // Local source 没有在线 service/adapter：作品页只把它借给章节列表渲染。
        throw UnsupportedError(
          'Local source is not an online manga runtime',
        );
    }
  }

  /// 旧 Aidoku 书架条目的本地落盘根（占位 manga.json、封面、已下载章节）。
  ///
  /// Aidoku 宿主已移除，但目录名 `aidoku` 是磁盘持久化名（冻结）：旧条目的封面与
  /// 已下载章节仍在这里，删除条目时也要按它清理。
  Directory get aidokuLibraryRoot =>
      Directory(path.join(databaseDirectory.path, 'aidoku'));

  /// 发现页源注册表（懒建，app 生命周期常驻）。内置源在此登记；加源 = 加一个
  /// adapter 实例。Sukebei（18+）默认不进「全部源」聚合，见
  /// [discoveryDisabledSourceIds]。
  ///
  /// **偏好未就绪时也必须能建**：发现页与「发现来源」设置区在初始化早期就可能
  /// 被构建（`_prefsRepo` 此时还是 null，[isPreferencesReady] 的存在本身就是
  /// 这条时序的证据），无条件解引用 [prefsRepo] 会把「早一帧打开发现页」变成
  /// 崩溃路径。此刻先给一份**不含用户自配 OPDS 源**的注册表，并记下这份是偏好
  /// 缺席时建的；等偏好就绪后第一次取用时自动重建，免得把「我配的服务器全都
  /// 不见了」latch 到整个进程生命周期。
  MediaDiscoveryService get mediaDiscoveryService {
    final MediaDiscoveryService? cached = _mediaDiscoveryService;
    if (cached != null &&
        !(_discoveryRegistryLacksPrefs && isPreferencesReady)) {
      return cached;
    }
    cached?.close();
    _discoveryRegistryLacksPrefs = !isPreferencesReady;
    // iOS 上一个源都不登记，内置的与用户自配 OPDS 的都不登记
    // （[StoreRestrictedCapability.externalDiscovery]）。
    //
    // 仍然建一份**空**注册表而不是返回 null：设置页的「发现来源」开关区、停用
    // 清单、发现页自身都无条件解引用本 getter，把合规边界做成一条空指针路径只会
    // 换来一批 iOS 专属崩溃。空注册表让这些消费端自然渲染成「没有源」。
    if (!StoreRestrictedCapability.externalDiscovery.isAvailable) {
      return _mediaDiscoveryService = MediaDiscoveryService(
        sources: const <MediaDiscoverySource>[],
      );
    }
    return _mediaDiscoveryService =
        MediaDiscoveryService(sources: <MediaDiscoverySource>[
      // 用户自配的 OPDS 服务器：**运行期**由偏好展开，一条配置 = 一个源
      // 实例。停用的条目直接不进注册表（而不是进了再靠停用清单挡）——
      // 源开关列表遍历的就是本注册表，两套「关掉」的语义并存只会让设置页
      // 出现一个既在清单里又被排除的幽灵条目。
      if (isPreferencesReady)
        for (final OpdsServerConfig server in prefsRepo.discoveryOpdsServers)
          if (server.enabled) OpdsDiscoverySource(config: server),
    ]);
  }

  MediaDiscoveryService? _mediaDiscoveryService;

  /// 上一份注册表是否在偏好就绪前建的（因而必然缺用户自配的 OPDS 源）。
  /// 偏好就绪后第一次取用就据此重建一次，见 [mediaDiscoveryService]。
  bool _discoveryRegistryLacksPrefs = false;

  /// 重建发现源注册表：用户增删改 OPDS 服务器后必须调。
  ///
  /// 注册表是**构造期快照**（懒建后 app 生命周期常驻），不重建的话新加的服务器
  /// 要等下次冷启动才出现。
  ///
  /// 旧实例先 close 再丢弃，否则每改一次配置就漏一个 HTTP client。
  Future<void> reloadDiscoverySources() async {
    _mediaDiscoveryService?.close();
    _mediaDiscoveryService = null;
    notifyListeners();
  }

  /// 增删改一台 OPDS 服务器后的统一写回口：落偏好 → 重建注册表。
  ///
  /// 只经这一个入口，免得每个调用点各写一遍「写完别忘了重建」——忘了的那次
  /// 表现为「我明明保存了，发现页里却没有」。
  Future<void> setDiscoveryOpdsServers(
    Iterable<OpdsServerConfig> servers,
  ) async {
    await prefsRepo.setDiscoveryOpdsServers(servers);
    await reloadDiscoverySources();
  }

  /// 「全部源」聚合排除的源 id（用户显式单选某源时不受限）。
  Set<String> get discoveryDisabledSourceIds => <String>{
        for (final String id in prefsRepo.discoveryDisabledSources.split(','))
          if (id.trim().isNotEmpty) id.trim(),
      };

  /// 开/关一个发现源。停用清单是逗号分隔的字符串，读写都只经这一个入口，
  /// 免得每个调用点各写一份 split/join。
  Future<void> setDiscoverySourceEnabled(String sourceId, bool enabled) async {
    await prefsRepo.setDiscoveryDisabledSources(
      _toggleDisabledId(discoveryDisabledSourceIds, sourceId, enabled),
    );
    notifyListeners();
  }

  static String _toggleDisabledId(
    Set<String> current,
    String sourceId,
    bool enabled,
  ) {
    final Set<String> next = <String>{...current};
    if (enabled) {
      next.remove(sourceId);
    } else {
      next.add(sourceId);
    }
    final List<String> sorted = next.toList()..sort();
    return sorted.join(',');
  }

  /// 发现页自动导入执行器（懒建；漫画图包是唯一保留的域导入器）。
  DiscoveryImportExecutor get _discoveryImportExecutor =>
      __discoveryImportExecutor ??= DiscoveryImportExecutor(
        importers: buildProductionDiscoveryImporters(db: database),
      );
  DiscoveryImportExecutor? __discoveryImportExecutor;

  /// 发现页直链下载队列（懒建，app 生命周期常驻——关闭发现页不中断下载，
  /// 语义同 [mangaDownloadService]）。
  DiscoveryDownloadQueue get discoveryDownloadQueue {
    final DiscoveryDownloadQueue? existing = _discoveryDownloadQueue;
    if (existing != null) return existing;
    final DiscoveryDownloadQueue queue = DiscoveryDownloadQueue(
      resolvePayload: (DiscoveryResourceItem item) {
        // 直链条目（控制通道 `dl add <url>`）没有发现源，payload 入队时已物化。
        final DiscoveryHttpPayload? direct = directLinkPayloadOf(item);
        if (direct != null) return Future<DiscoveryPayload>.value(direct);
        final MediaDiscoverySource? source =
            mediaDiscoveryService.sourceById(item.sourceId);
        if (source == null) {
          throw StateError('unknown discovery source: ${item.sourceId}');
        }
        return source.resolvePayload(item);
      },
      importer: (DiscoveryDownloadTask task, File file) =>
          _discoveryImportExecutor.importDownload(task, file),
    );
    // BUG-2714：队列有未结束任务时挂下载保活。
    _discoveryDownloadKeepAlive = DiscoveryDownloadKeepAliveBinding(queue);
    return _discoveryDownloadQueue = queue;
  }

  DiscoveryDownloadQueue? _discoveryDownloadQueue;
  DiscoveryDownloadKeepAliveBinding? _discoveryDownloadKeepAlive;

  /// 发现页下载的落盘目录（与 torrent 同根：用户配置的下载根 → 默认根
  /// [downloadDefaultSaveRoot]，再按媒体域分子目录）。
  ///
  /// 不再自造 documents 派生点：默认根由 [startAnimeDownloadService] 在
  /// initialise 期唯一计算（UI 可达发现页时必已就绪），这里只消费。
  String discoveryDownloadDirFor(DiscoveryMediaKind kind) {
    String root = prefsRepo.downloadSaveRoot.trim();
    if (root.isEmpty) root = path.join(appDirectory.path, 'downloads');
    return path.join(root, 'discovery', kind.name);
  }

  bool get reverseNavigationBar => prefsRepo.reverseNavigationBar;

  /// MD3 悬浮底栏图标下是否显示标签（设置 · 外观，默认显示）。
  bool get navBarLabelsVisible => prefsRepo.navBarLabelsVisible;
  Future<void> setNavBarLabelsVisible(bool value) =>
      prefsRepo.setNavBarLabelsVisible(value);
  AdaptiveNavBarStyle get navBarStyle => prefsRepo.navBarStyle;
  Future<void> setNavBarStyle(AdaptiveNavBarStyle value) =>
      prefsRepo.setNavBarStyle(value);
  void toggleReverseNavigationBar() => prefsRepo.toggleReverseNavigationBar();

  bool get reverseReaderBottomBar => prefsRepo.reverseReaderBottomBar;
  void toggleReverseReaderBottomBar() =>
      prefsRepo.toggleReverseReaderBottomBar();

  /// Show the dictionary menu. This should be callable from many parts of the
  /// app, so it is appropriately handled by the model.
  /// 关书后是否顺带关闭 app（`killOnPop`）。manga reader 的旧行为保留。
  bool _shouldKillMediaOnPop = false;

  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    if (killOnPop) {
      _shouldKillMediaOnPop = true;
    }

    mediaSource.clearCurrentSentence();
    mediaSource.clearExtraData();

    _currentMediaSource = mediaSource;
    if (item != null) {
      _currentMediaItem = item;
    }
    // TODO-1375：把「媒体已打开」推给可靠通知源，让 macOS 根 sidebar 隐藏（阅读全宽）。
    mediaOpenNotifier.value = true;

    if (ReaderFushiSource.instance.keepScreenAwake) {
      await setScreenWakelock(enable: true, source: 'openMedia');
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (recordHistory && item != null && mediaSource.implementsHistory) {
      addMediaItem(item);
    }

    final ctx = _ctx;
    if (ctx == null || !ctx.mounted) return;
    final Future<dynamic> routeDone;
    if (pushReplacement) {
      routeDone = Navigator.pushReplacement(
        ctx,
        adaptivePageRoute(
          context: ctx,
          builder: (context) =>
              launchPageBuilder?.call() ??
              mediaSource.buildLaunchPage(
                item: item,
                initialBookmarkJump: initialBookmarkJump,
              ),
        ),
      );
    } else {
      routeDone = Navigator.push(
        ctx,
        adaptivePageRoute(
          context: ctx,
          builder: (context) =>
              launchPageBuilder?.call() ??
              mediaSource.buildLaunchPage(
                item: item,
                initialBookmarkJump: initialBookmarkJump,
              ),
        ),
      );
    }
    if (waitUntilClosed) {
      await routeDone;
    } else {
      unawaited(routeDone);
    }
  }

  /// Ends a media session and ensures that values are reset.
  Future<void> closeMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    MediaItem? item,
  }) async {
    mediaSource.setShouldGenerateImage(value: true);
    mediaSource.setShouldGenerateAudio(value: true);
    mediaSource.clearCurrentSentence();
    mediaSource.clearExtraData();
    _currentMediaSource = null;
    _currentMediaItem = null;
    // TODO-1375：把「媒体已关闭」推给可靠通知源，保证退出阅读器后 macOS 根 sidebar
    // 必然重建恢复（不再依赖碰巧有别的 notifyListeners 触发 builder 重跑）。
    mediaOpenNotifier.value = false;
    await setScreenWakelock(enable: false, source: 'closeMedia');
    // Returning to the home/menu shell: restore both system bars.
    await setHomeShellSystemUiMode();
    // TODO-1275 / BUG-361: returning to the home shell — restore desktop_drop's
    // Windows OS drop registration in case an opened reader/video/lookup
    // WebView2 usurped it, so drag-import works again after any media was
    // opened. No-op off Windows / when desktop_drop lacks the reinitialize patch.
    await DesktopDropReinitializer.reinitialize();
    await mediaSource.onSourceExit(
      appModel: this,
      ref: ref,
    );

    mediaSource.mediaType.refreshTab();

    if (_shouldKillMediaOnPop) {
      shutdown();
    }
  }

  // ── media item CRUD (delegated to MediaHistoryRepository) ───────────

  void addMediaItem(MediaItem item) => mediaHistoryRepo.addMediaItem(item);

  void updateMediaItem(MediaItem item) =>
      mediaHistoryRepo.updateMediaItem(item);

  void removeFromReadingList(String mediaIdentifier) =>
      mediaHistoryRepo.removeFromReadingList(mediaIdentifier);

  Future<void> deleteMediaItem(MediaItem item) async {
    MediaSource mediaSource = item.getMediaSource(appModel: this);
    await mediaSource.clearOverrideValues(appModel: this, item: item);
    await mediaSource.onMediaItemClear(item);
    await mediaHistoryRepo.deleteMediaItemById(item);
  }

  /// Copies a [term] to clipboard and shows an appropriate toast.
  void copyToClipboard(String term) {
    platformServices.clipboard.copyToClipboard(term);

    /// Redundant to do this with the share notification on Android 33+
    if (platformServices.clipboard.shouldShowCopyToast) {
      FushiToast.show(
        msg: t.copied_to_clipboard,
        toastLength: Toast.LENGTH_SHORT,
        gravity: ToastGravity.BOTTOM,
        severity: ToastSeverity.success,
      );
    }
  }

  /// For a given [MediaType], return the selected media source. If there is
  /// no persisted media source, use the first source in the list.
  MediaSource getCurrentSourceForMediaType({
    required MediaType mediaType,
  }) {
    MediaSource fallbackSource = mediaSources[mediaType]!.values.first;
    String uniqueKey = _getPref('current_source/${mediaType.uniqueKey}',
        defaultValue: fallbackSource.uniqueKey);

    return mediaSources[mediaType]![uniqueKey] ?? fallbackSource;
  }

  /// For a given [MediaType], set the selected media source.
  void setCurrentSourceForMediaType({
    required MediaType mediaType,
    required MediaSource mediaSource,
  }) {
    _setPref('current_source/${mediaType.uniqueKey}', mediaSource.uniqueKey);
  }

  List<MediaItem> getMediaTypeHistory({required MediaType mediaType}) =>
      mediaHistoryRepo.getMediaTypeHistory(mediaTypeKey: mediaType.uniqueKey);

  List<MediaItem> getMediaSourceHistory({required MediaSource mediaSource}) =>
      mediaHistoryRepo.getMediaSourceHistory(
          mediaSourceKey: mediaSource.uniqueKey);

  /// Returns the last navigated directory the user used for picking a file for a
  /// certain media type.
  Directory? getLastPickedDirectory(MediaType type) {
    String path =
        _getPref('${type.uniqueKey}/last_picked_file', defaultValue: '');
    if (path.isEmpty) {
      return null;
    }

    Directory directory = Directory(path);
    if (!directory.existsSync()) {
      return null;
    }
    return directory;
  }

  /// Returns the last navigated directory the user used for picking a file for a
  /// certain media type.
  void setLastPickedDirectory({
    required MediaType type,
    required Directory directory,
  }) {
    _setPref('${type.uniqueKey}/last_picked_file', directory.path);
  }

  /// Returns valid file picker directories. If there is a last picked directory for
  /// a media type, this will be included as first on the list. Otherwise, external
  /// root directories will be included.
  Future<List<Directory>> getFilePickerDirectoriesForMediaType(
      MediaType type) async {
    List<Directory> directories = [];
    Directory? lastPickedDirectory = getLastPickedDirectory(type);
    if (lastPickedDirectory != null) {
      directories.add(lastPickedDirectory);
    }

    final List<String> defaultPaths =
        await platformServices.directory.getDefaultPickerDirectories();
    for (final String dirPath in defaultPaths) {
      final Directory directory = Directory(dirPath);
      if (!directories.contains(directory)) {
        directories.add(directory);
      }
    }

    return directories;
  }

  bool get isFirstTimeSetup => prefsRepo.isFirstTimeSetup;
  void setFirstTimeSetupFlag() => prefsRepo.setFirstTimeSetupFlag();

  bool get onboardingCompleted => prefsRepo.onboardingCompleted;
  Future<void> setOnboardingCompleted({required bool value}) =>
      prefsRepo.setOnboardingCompleted(value: value);

  /// 「功能模块」用户意愿的读写。**平台判据不在这里**——见 [moduleVisibility]。
  ///
  /// 偏好仓库还没装配好时取出厂默认（[ModuleId.defaultEnabled]，fail-open）；复习
  /// 例外按关：此刻还不知道本安装是不是老用户（老用户升级后复习保持关、不提醒，见
  /// `PreferencesRepository.settleSrsMiningTargetInstallDefault`）。模块门控读得比 `initialise()`
  /// 早：设置 schema 的 `visible` 谓词同时喂渲染与搜索索引，展平索引这条路径在弹窗
  /// 词典入口与纯 widget 测试里都会撞上一个未初始化的 AppModel。裸 `prefsRepo!` 会
  /// 在那里抛 null check——而「读不到用户意愿」的安全方向是全都显示，不是把整个设置
  /// 页藏掉（与 module_registry 里「漏写映射默认恒在」同一个方向）。
  bool moduleEnabled(ModuleId module) => isPreferencesReady
      ? prefsRepo.moduleEnabled(module)
      : module != ModuleId.srs && module.defaultEnabled;

  Future<void> setModuleEnabled(ModuleId module, bool value) async {
    await prefsRepo.setModuleEnabled(module, value);
    // 设置 schema 树按 locale 记忆化，两张投影表（阅读器/视频快捷面板）也惰性缓存。
    // 模块可见性会改变这些树的过滤结果，故翻转开关必须丢弃快照，否则快捷面板会
    // 继续发已被关掉模块的设置项（settings_schema.dart 的 `_SettingsSchemaCache`）。
    resetSettingsSchemaCache();
    notifyListeners();
  }

  /// 「功能模块」的用户排序（底栏 / 侧栏 tab 顺序，见 [ModuleVisibility.order]）。
  /// 偏好仓库没装配好时按枚举顺序，理由同 [moduleEnabled]。
  List<ModuleId> get moduleOrder =>
      isPreferencesReady ? prefsRepo.moduleOrder : const <ModuleId>[];

  Future<void> setModuleOrder(List<ModuleId> order) async {
    await prefsRepo.setModuleOrder(order);
    notifyListeners();
  }

  /// 「此刻哪些模块可见」——pref 真值与平台判据的**唯一合成**。
  ///
  /// 全 app 的门控一律读它。此前底栏与 macOS 侧栏各手抄一份七参表，`games` 的
  /// `Platform.isWindows` 判据抄了两遍、漏了一遍（macOS 那份靠缺省值蒙对）。
  ///
  /// 平台判据取自 [PlatformServices]（那是本类「不必知道自己跑在哪个平台」的出口），
  /// 不再直读 `dart:io` —— 直读会让 widget 测试无缝可注，Windows 独有的模块
  /// （galgame）在 Linux CI 上被静默滤掉而本机全绿。
  ModuleVisibility get moduleVisibility => ModuleVisibility.resolve(
        prefOf: moduleEnabled,
        order: moduleOrder,
        isWindows: platformServices.isWindows,
        isDesktop: platformServices.isDesktop,
        isIOS: platformServices.isIOS,
        isAndroid: platformServices.isAndroid,
      );

  /// games 模块在本平台上的形态（本机 galgame 库 / 串流接收端）。平台判据同样
  /// 取自 [PlatformServices]，理由同上。
  GamesModuleForm get gamesModuleForm =>
      GamesModuleForm.on(isWindows: platformServices.isWindows);

  /// 「下载」改名「浏览」的一次性搬迁提示是否已处理（见 `browse_moved_notice.dart`）。
  bool get browseMovedNoticeHandled => prefsRepo.browseMovedNoticeHandled;
  Future<void> setBrowseMovedNoticeHandled() =>
      prefsRepo.setBrowseMovedNoticeHandled();

  int get maximumTerms => prefsRepo.maximumTerms;
  void setMaximumTerms(int value) => prefsRepo.setMaximumTerms(value);

  /// Check if the database is still open.
  bool get isDatabaseOpen => _isInitialised;

  /// Direct access to the Drift database instance.
  FushiDatabase get database => _database;

  /// Close the database and notify listeners, without exiting the app.
  /// BUG-1505：关库**之前**把后台写手停掉。
  ///
  /// `closeDatabase()` 只关连接，不停任何人。下载流水线这类常驻 drain 循环仍在跑，
  /// 于是关库后每次唤醒都撞上 drift 的
  /// 「Tried to send Request ... over isolate channel, but the connection was
  /// closed!」——用户机器上实测一次迁移导入刷出 8 条。它至少污染诊断日志（真正的
  /// 失败原因被淹没），更糟的是合并导入正在直接操作同一个库文件，此时放任第二个
  /// 写手继续往里写是数据安全问题，不是噪声问题。
  ///
  /// 只停「后台自己会写库」的那几个（下载/订阅/漫画队列），不碰查词、TTS 这类只读
  /// 子系统：closeDatabase 之后调用方一律走重启，停多了没收益、只增加爆炸半径。
  ///
  /// [pipelineDrainTimeout] 只在**退出路径**给：见
  /// [VideoDownloadPipelineService.stop] 的注释——迁移导入 / 备份导入 / 数据根迁移
  /// 也走这条链，它们在关库后要在文件层动整个 DB 目录，放行一个仍在飞的 `_process`
  /// 会让它继续打已关闭的连接、并被随后的 `_videoDownloadBackend?.close()` 抽掉
  /// 句柄。那些路径必须等到真收尾。
  Future<void> quiesceBackgroundDatabaseWriters({
    Duration? pipelineDrainTimeout,
  }) async {
    _mangaDownloadService?.dispose();
    _mangaDownloadService = null;
    _discoveryDownloadKeepAlive?.dispose();
    _discoveryDownloadKeepAlive = null;
    _discoveryDownloadQueue?.dispose();
    _discoveryDownloadQueue = null;
    _mediaDiscoveryService?.close();
    _mediaDiscoveryService = null;
  }

  Future<void> closeDatabase({Duration? pipelineDrainTimeout}) async {
    _isInitialised = false;
    // BUG-1569②：合集观察者持有本库的表订阅 + 未决防抖 Timer，关库前必须撤——
    // 否则防抖到点后 _runCollectionsSync 会对已关闭的 db 发起查询（drift「connection
    // was closed」异常）。initialise 装载（installCollectionsSyncWatcher），此前只有
    // 测试 teardown 调过 uninstall，生产三条关库路径全都不撤订阅。
    databaseCloseNotifier.notifyListeners();
    await quiesceBackgroundDatabaseWriters(
      pipelineDrainTimeout: pipelineDrainTimeout,
    );
    await _database.close();
  }

  /// Safely shutdown and stop database operations.
  Future<void> shutdown() async {
    await closeDatabase();
    await platformServices.lifecycle.exitApp();
  }

  Future<void> closeForPopup() async {
    // BUG-1569②：与 [closeDatabase] 同理——撤合集观察者，防止防抖 Timer 对已
    // 关闭的 db 跑轻量同步。
    _prefsRepo?.removeListener(notifyListeners);
    databaseCloseNotifier.notifyListeners();
    await _database.close();
  }

  @override
  void dispose() {
    // BUG-913：对称释放 initialise() 起的 4 个 app-wide 常驻子系统。dispose 是同步的、
    // 这些 stop 多为 Future → fire-and-forget（unawaited）；先停常驻服务，再走现有
    // notifier/repo dispose，最后 super.dispose()。
    _mangaDownloadService?.dispose();
    _mangaDownloadService = null;
    _discoveryDownloadKeepAlive?.dispose();
    _discoveryDownloadKeepAlive = null;
    _discoveryDownloadQueue?.dispose();
    _discoveryDownloadQueue = null;
    _mediaDiscoveryService?.close();
    _mediaDiscoveryService = null;
    _mihonManager?.dispose();
    _mihonManager = null;
    final ExitFlushCallback? mihonExitShutdown = _mihonRuntimeExitShutdown;
    _mihonRuntimeExitShutdown = null;
    if (mihonExitShutdown != null) {
      ExitFlushRegistry.instance.unregister(mihonExitShutdown);
    }
    unawaited(_shutdownMihonRuntime());
    _mihonRuntime = null;
    _prefsRepo?.removeListener(notifyListeners);
    if (_themeListenerAdded) {
      themeNotifier.removeListener(notifyListeners);
      themeNotifier.dispose();
      _themeListenerAdded = false;
    }
    incognitoNotifier.dispose();
    databaseCloseNotifier.dispose();
    mediaOpenNotifier.dispose();
    gamepadService.dispose();
    // Dispose the extracted repository notifiers (all ChangeNotifiers). Only
    // when fully initialised — a failed/partial init leaves these `late`
    // fields unassigned, and reading them would throw.
    _prefsRepo?.dispose();
    if (_isInitialised) {
      mediaHistoryRepo.dispose();
    }
    super.dispose();
  }

  /// 移动端「所有文件访问」权限请求；my-comic Windows-only，恒 no-op。
  Future<void> requestExternalStoragePermissions() async {}

  /// 实验性：整套键盘/手柄焦点导航是否启用（默认 false）。关闭时 main.dart 不安装
  /// FushiFocusRoot/Ring，App 回退到 Flutter 原生焦点遍历。
  bool get experimentalFocusNavigationEnabled =>
      prefsRepo.experimentalFocusNavigationEnabled;
  Future<void> setExperimentalFocusNavigationEnabled(bool value) =>
      prefsRepo.setExperimentalFocusNavigationEnabled(value);

  // TODO-1030 M0 — 全局查词是否抓取选中文本上下文（隐私敏感，默认关）。
  bool get updateNeverRemind => prefsRepo.updateNeverRemind;
  Future<void> setUpdateNeverRemind(bool value) =>
      prefsRepo.setUpdateNeverRemind(value);

  bool get updateAutoInstall => prefsRepo.updateAutoInstall;
  Future<void> setUpdateAutoInstall(bool value) =>
      prefsRepo.setUpdateAutoInstall(value);

  /// 安装统计心跳开关（[UsageHeartbeat]），设备本地。
  bool get usageStatsEnabled => prefsRepo.usageStatsEnabled;
  Future<void> setUsageStatsEnabled(bool value) =>
      prefsRepo.setUsageStatsEnabled(value);

  bool get updateBetaChannel => prefsRepo.updateBetaChannel;
  Future<void> setUpdateBetaChannel(bool value) =>
      prefsRepo.setUpdateBetaChannel(value);

  bool get updateDebugChannel => prefsRepo.updateDebugChannel;
  Future<void> setUpdateDebugChannel(bool value) =>
      prefsRepo.setUpdateDebugChannel(value);

  String get updateCustomProxy => prefsRepo.updateCustomProxy;
  Future<void> setUpdateCustomProxy(String value) =>
      prefsRepo.setUpdateCustomProxy(value);

  String get networkProxyMode => prefsRepo.networkProxyMode;
  Future<void> setNetworkProxyMode(String value) =>
      prefsRepo.setNetworkProxyMode(value);

  String get networkProxyUsername => prefsRepo.networkProxyUsername;
  Future<void> setNetworkProxyUsername(String value) async {
    await prefsRepo.setNetworkProxyUsername(value);
  }

  String get networkProxyPassword => prefsRepo.networkProxyPassword;
  Future<void> setNetworkProxyPassword(String value) async {
    await prefsRepo.setNetworkProxyPassword(value);
  }

  /// 阅读器顶栏 / 底栏按钮布局（ReaderControlLayout，2026-09-13）。
  ReaderControlLayout get readerControlLayout => prefsRepo.readerControlLayout;

  Future<void> setReaderControlLayout(ReaderControlLayout layout) =>
      prefsRepo.setReaderControlLayout(layout);

  /// 窄窗（手机竖屏）按钮布局；没存过时沿用存量宽窗自定义（见 prefsRepo）。
  ReaderControlLayout get readerCompactControlLayout =>
      prefsRepo.readerCompactControlLayout;

  Future<void> setReaderCompactControlLayout(ReaderControlLayout layout) =>
      prefsRepo.setReaderCompactControlLayout(layout);

  /// 按窗口宽度取当前生效的按钮布局（< [kReaderControlCompactWidth] 用窄窗那份）。
  ReaderControlLayout readerControlLayoutFor({required bool compact}) =>
      compact ? readerCompactControlLayout : readerControlLayout;

  /// 阅读器工具栏样式：`floating`（默认）/ `docked`。
  String get readerToolbarStyle => prefsRepo.readerToolbarStyle;

  Future<void> setReaderToolbarStyle(String style) =>
      prefsRepo.setReaderToolbarStyle(style);

  String get defaultContentLanguage => prefsRepo.defaultContentLanguage;

  Future<void> setDefaultContentLanguage(String language) =>
      prefsRepo.setDefaultContentLanguage(language);

  String get updateDownloadSource => prefsRepo.updateDownloadSource;
  Future<void> setUpdateDownloadSource(String value) =>
      prefsRepo.setUpdateDownloadSource(value);

  String get mangaSpreadPreference => prefsRepo.mangaSpreadPreference;
  Future<void> setMangaSpreadPreference(String value) =>
      prefsRepo.setMangaSpreadPreference(value);

  String get mangaReadingDirection => prefsRepo.mangaReadingDirection;
  Future<void> setMangaReadingDirection(String value) =>
      prefsRepo.setMangaReadingDirection(value);

  int get mangaZoomPercent => prefsRepo.mangaZoomPercent;
  Future<void> setMangaZoomPercent(int value) =>
      prefsRepo.setMangaZoomPercent(value);

  /// 在线漫画封面磁盘缓存保留天数（BUG-2450）。manager 已建时同步改到缓存实例，
  /// 不必重启；未建时下次懒建从偏好读。
  int get mangaCoverCacheMaxAgeDays => prefsRepo.mangaCoverCacheMaxAgeDays;
  Future<void> setMangaCoverCacheMaxAgeDays(int value) async {
    await prefsRepo.setMangaCoverCacheMaxAgeDays(value);
    _mihonManager?.coverCache.maxAge =
        Duration(days: prefsRepo.mangaCoverCacheMaxAgeDays);
  }

  int get mangaZoomSensitivity => prefsRepo.mangaZoomSensitivity;
  Future<void> setMangaZoomSensitivity(int value) =>
      prefsRepo.setMangaZoomSensitivity(value);

  String get mangaPageAnimation => prefsRepo.mangaPageAnimation;
  Future<void> setMangaPageAnimation(String value) =>
      prefsRepo.setMangaPageAnimation(value);

  String get mangaPageAnimationSpeed => prefsRepo.mangaPageAnimationSpeed;
  Future<void> setMangaPageAnimationSpeed(String value) =>
      prefsRepo.setMangaPageAnimationSpeed(value);

  bool get mangaPageTurnFollowDrag => prefsRepo.mangaPageTurnFollowDrag;
  Future<void> setMangaPageTurnFollowDrag(bool value) =>
      prefsRepo.setMangaPageTurnFollowDrag(value);

  bool get mangaVolumeKeyPaging => prefsRepo.mangaVolumeKeyPaging;
  Future<void> setMangaVolumeKeyPaging(bool value) =>
      prefsRepo.setMangaVolumeKeyPaging(value);

  bool get mangaChromeFloating => prefsRepo.mangaChromeFloating;
  Future<void> setMangaChromeFloating(bool value) =>
      prefsRepo.setMangaChromeFloating(value);

  bool get mangaTapZonePaging => prefsRepo.mangaTapZonePaging;
  Future<void> setMangaTapZonePaging(bool value) =>
      prefsRepo.setMangaTapZonePaging(value);

  bool get mangaPanelNavigation =>
      _prefsRepo?.mangaPanelNavigation ?? kMangaPanelNavigationDefault;
  Future<void> setMangaPanelNavigation(bool value) =>
      prefsRepo.setMangaPanelNavigation(value);

  bool get mangaPanelNavigationEnabled => mangaPanelNavigation;

  /// 一键制卡默认裁到所在分镜。弹窗 / 悬浮词典 entry point 不经 `initialise()`，
  /// `_prefsRepo` 可能为空，回落到同一个默认值常量。
  bool get mangaMiningCropToPanel =>
      _prefsRepo?.mangaMiningCropToPanel ?? kMangaMiningCropToPanelDefault;
  Future<void> setMangaMiningCropToPanel(bool value) =>
      prefsRepo.setMangaMiningCropToPanel(value);
  Future<void> setMangaPanelNavigationEnabled(bool value) =>
      setMangaPanelNavigation(value);

  // 下面四个在漫画页 build 路径上被读（`_loadLocalPayload`），而弹窗词典与悬浮查词
  // 是不经 `initialise()` 的 entry point，那里 `_prefsRepo` 恒 null——裸 `prefsRepo`
  // （即 `_prefsRepo!`）会让整页 build 抛。与 `moduleEnabled` / `mineToServerEnabled`
  // 同律：偏好未就绪时回落到与 repo 侧逐字一致的默认值。
  String get mangaTapZoneLayout =>
      _prefsRepo?.mangaTapZoneLayout ?? kMangaTapZoneLayoutDefault;
  Future<void> setMangaTapZoneLayout(String value) =>
      prefsRepo.setMangaTapZoneLayout(value);

  String get mangaBackground =>
      _prefsRepo?.mangaBackground ?? kMangaBackgroundDefault;
  Future<void> setMangaBackground(String value) =>
      prefsRepo.setMangaBackground(value);

  int get mangaSpreadOffset =>
      _prefsRepo?.mangaSpreadOffset ?? kMangaSpreadOffsetDefault;
  Future<void> setMangaSpreadOffset(int value) =>
      prefsRepo.setMangaSpreadOffset(value);

  bool get mangaWidePageSolo =>
      _prefsRepo?.mangaWidePageSolo ?? kMangaWidePageSoloDefault;
  Future<void> setMangaWidePageSolo(bool value) =>
      prefsRepo.setMangaWidePageSolo(value);

  String get mangaResumeTarget =>
      _prefsRepo?.mangaResumeTarget ?? kMangaResumeTargetDefault;
  Future<void> setMangaResumeTarget(String value) =>
      prefsRepo.setMangaResumeTarget(value);

  bool get mangaChapterListNewestFirst =>
      _prefsRepo?.mangaChapterListNewestFirst ?? true;
  Future<void> setMangaChapterListNewestFirst(bool value) =>
      prefsRepo.setMangaChapterListNewestFirst(value);

  /// 内置「本地图源」是否启用。偏好未就绪时按默认开处理（与仓库默认一致）。
  bool get localSourceEnabled => _prefsRepo?.localSourceEnabled ?? true;

  Future<void> setLocalSourceEnabled(bool value) =>
      prefsRepo.setLocalSourceEnabled(value);

  MangaReaderPreferences get mangaReaderPreferences =>
      _prefsRepo?.mangaReaderPreferences ?? const MangaReaderPreferences();

  Future<void> setMangaReaderPreferences(MangaReaderPreferences value) =>
      prefsRepo.setMangaReaderPreferences(value);

  /// 无痕阅读（设备本地偏好，默认 false = 记录 History）。阅读器在**每次落库
  /// 时**现读本值，设置里切换后立即生效。`_prefsRepo` 为空（弹窗进程 / 部分测试
  /// 壳）时按默认「记录 History」处理。
  bool get incognitoReading => _prefsRepo?.incognitoReading ?? false;

  /// 阅读器落库时的 History 写入策略（无痕开关 → 冻结 `updatedAt` / 跳过自动
  /// `readAt` 与书级完成标记）。三个阅读器共用这一份判定，不再各自 `if
  /// (incognito)`。
  ReaderHistoryPolicy get readerHistoryPolicy =>
      ReaderHistoryPolicy.forIncognito(incognitoReading);

  Future<void> setIncognitoReading(bool value) =>
      prefsRepo.setIncognitoReading(value);

  /// 作品页「完成后自动识别」chip 的持久值；单章 / 整部入队都读它作 `auto_ocr`。
  bool get mangaDownloadAutoOcr => prefsRepo.mangaDownloadAutoOcr;
  Future<void> setMangaDownloadAutoOcr(bool value) =>
      prefsRepo.setMangaDownloadAutoOcr(value);

  /// 「保存为CBZ压缩包」（默认开）。下载服务在任务开始运行时现读，运行中的
  /// 任务不受开关切换影响。
  bool get downloadSaveAsCbz => prefsRepo.downloadSaveAsCbz;
  Future<void> setDownloadSaveAsCbz(bool value) =>
      prefsRepo.setDownloadSaveAsCbz(value);

  // TODO-1024 / BUG-479：更新检查结果缓存（缓存优先 + 后台静默刷新）。
  UpdateCheckCacheEntry? get updateCheckCache => prefsRepo.updateCheckCache;
  Future<void> setUpdateCheckCache(UpdateCheckCacheEntry entry) =>
      prefsRepo.setUpdateCheckCache(entry);

  // ── low memory mode (side effect stays here) ─────────────────────────

  /// 兼容保留：词典历史已删除，旧测试仍读取该上限。
  int get maximumDictionaryHistoryItems => lowMemoryMode ? 5 : 10;

  bool get lowMemoryMode => prefsRepo.lowMemoryMode;

  Future<void> setLowMemoryMode(bool v) async {
    await prefsRepo.setPref('low_memory_mode', v);
    _applyMemoryPolicy();
    notifyListeners();
  }

  void _applyMemoryPolicy() {
    final imageCache = PaintingBinding.instance.imageCache;
    if (lowMemoryMode) {
      imageCache.maximumSize = 50;
      imageCache.maximumSizeBytes = 20 << 20; // 20 MB
    } else {
      imageCache.maximumSize = 1000;
      imageCache.maximumSizeBytes = 100 << 20; // 100 MB
    }
  }
}

