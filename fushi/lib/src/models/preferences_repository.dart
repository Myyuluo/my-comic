import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:material_ui/material_ui.dart';
import 'package:fushi_audio/fushi_audio.dart'
    show kDefaultReadingIdleTimeout, kStudyIdleTimeoutPrefKey;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:fushi_engine/srs/srs_backup_retention.dart';
import 'package:fushi_engine/profile/profile_document.dart'
    show kProfileSettingCategoryPref;

import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart'
    show
        WebKnowledgeSite,
        encodeWebKnowledgeCustomSites,
        kBuiltinWebKnowledgeSites,
        kLegacyWebKnowledgeSiteIds,
        parseWebKnowledgeCustomSites,
        parseWebKnowledgeEnabledIds;
import 'package:fushi/src/utils/adaptive/nav_bar_style.dart';
import 'package:fushi/src/dictionary/dict_style_rules.dart';


import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/sync/hidden_remote_books.dart'
    show HiddenRemoteBook, decodeHiddenRemoteBooks, encodeHiddenRemoteBooks;
import 'package:fushi/src/media/manga/mihon/mihon_cover_cache.dart'
    show
        kMangaCoverCacheDefaultMaxAgeDays,
        kMangaCoverCacheMaxDays,
        kMangaCoverCacheMinDays;











import 'package:fushi_engine/ai/ai_key_rotation.dart'
    show AiKeyHealth, AiKeyHealthStore, AiKeyHealthUpdate, aiKeyHealthStore;






import 'package:fushi/src/reader/reader_control_layout.dart';

import 'package:fushi/src/stats/reader_study_clock_start_mode.dart';








import 'package:fushi/src/media/audiobook/mining_audio_clip.dart'
    show kMiningHeadPadMs, kMiningPadMaxMs, kMiningTailPadMs;

// 迁移判据要用「这个存量代理地址归一得出来吗」，与 applyAppProxy 同一份实现，
// 不在这里重写一遍（重写就会漂移，而漂移的后果是存量用户升级即断网）。
import 'package:fushi_engine/utils/net/app_proxy.dart'
    show
        appUserProxyModeReader,
        appUserProxyPasswordReader,
        appUserProxyReader,
        appUserProxyUsernameReader,
        kProxyModeAuto,
        kProxyModeDirect,
        kProxyModeManual,
        normalizeUserProxyHostPort;
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show
        MiningAnimatedFormat,
        MiningClipFormat,
        MiningStillFormat,
        VideoMiningImageMode;
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show MiningMediaCompression;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/update_check_cache.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/library/manga_resume_point.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart'
    show UpdateFeedKind;

/// 视频画面缩放/比例模式（作用于 Flutter 层 [Video] widget 的 [BoxFit]，TODO-152 子B）。
///
/// 与 mpv 内置几何（`video_setting_mpv_aspect`/`zoom`/`panscan`）是两个不同层：这里只决定
/// 解码后的画面如何映射进媒体框，不改 mpv 渲染管线。窗口模式与全屏路由共用本偏好。
/// - [cover]：保持比例铺满媒体框、超出部分裁切（无 letterbox/pillarbox 黑边）。
/// - [contain]：默认。保持比例完整显示，比例不匹配时上下/左右补黑边（画面缩窄时
///   加黑，即用户要的「适应」）。
/// - [fill]：拉伸填满整个媒体框、不保持比例（变形）。
enum VideoFitMode {
  cover('cover'),
  contain('contain'),
  fill('fill');

  const VideoFitMode(this.storageValue);

  final String storageValue;

  static VideoFitMode fromStorage(String value) {
    for (final VideoFitMode mode in VideoFitMode.values) {
      if (mode.storageValue == value) return mode;
    }
    return VideoFitMode.contain;
  }
}

/// 把 [VideoFitMode] 映射成 Flutter [BoxFit]（纯函数，是窗口/全屏 [Video] fit 与单测的
/// 共享真相源）。穷举枚举无 default 分支，新增模式编译期强制补齐。
BoxFit videoFitModeToBoxFit(VideoFitMode mode) {
  switch (mode) {
    case VideoFitMode.cover:
      return BoxFit.cover;
    case VideoFitMode.contain:
      return BoxFit.contain;
    case VideoFitMode.fill:
      return BoxFit.fill;
  }
}

/// bool（默认 false = 记录 History）：「无痕阅读」。
///
/// 开启后阅读器仍写精确续读位置（`reader_positions` 的章 / 页 / 页内位置、在线
/// 漫画当前章的 `manga_chapter_states.updatedAt`），但不推进 History 的可见
/// 信号：冻结 `reader_positions.updatedAt`，不自动写
/// `manga_chapter_states.readAt`，也不写 `EpubBooks.completedAt`。Tracking 与
/// 统计不受影响。
///
/// 设备本地（见 `SyncRepository.deviceLocalPrefKeys`）：是否在这台设备留阅读
/// 痕迹不随 Profile 快照 / 备份同步，换设备按新设备自己的设置走。
const String kIncognitoReadingPrefKey = 'reader_incognito_reading';

/// 「新下载任务交给哪台互联 host 执行」的偏好键（空 = 本机）。
/// 设备本地（见 `SyncRepository.deviceLocalPrefKeys`）。
const String kDownloadExecutionHostPrefKey = 'download_execution_host';

/// 主机侧「允许已配对设备从游戏库远程启动游戏并串流」。默认关：开启即允许配对
/// 设备在本机起进程。设备本地（见 `SyncRepository.deviceLocalPrefKeys`），不能随
/// 备份把这扇门带到另一台电脑上。
const String kGameStreamRemoteLaunchPrefKey = 'game_stream_remote_launch';

/// 接收端的串流参数，只存与默认值不同的字段（`toOverridesJson`）：没动过的
/// 字段一律跟随当前默认，默认值改了对所有人生效。旧键 `game_stream_video_settings`
/// 存的是整张表（连隐式默认一起固化），已弃用不读。
const String kGameStreamVideoSettingsPrefKey = 'game_stream_video_overrides';

/// 串流页查词栏的尺寸（侧边栏宽度 + 台词区高度，JSON）。设备本地（见
/// `SyncRepository.deviceLocalPrefKeys`）：合适的尺寸取决于这台设备的屏幕，
/// 平板上调大的值随备份到手机 / 电脑只会不合身。
const String kGameStreamLookupLayoutPrefKey = 'game_stream_lookup_layout';

/// Windows 悬浮字幕窗口矩形（本机**物理像素**坐标 JSON）。设备本地（见
/// `SyncRepository.deviceLocalPrefKeys`）：坐标只对这台机器的显示器布局 / DPI
/// 有意义，随备份 / 同步 / Profile 带到别的设备会把窗口放到屏幕外或尺寸错位。
const String kFloatingLyricWindowRectPrefKey = 'floating_lyric_window_rect';

/// 悬浮字幕可自选的四种颜色。键缺省 / 偏好值
/// [PreferencesRepository.floatingLyricColorFollowTheme]（-1）= 跟随主题（见
/// `floating_lyric_style.dart`）；0 是合法的完全透明黑。
enum FloatingLyricColorRole {
  /// 底板。
  background('floating_lyric_color_background'),

  /// 非当前句（及单行时整行）的字色。
  text('floating_lyric_color_text'),

  /// 多行时当前句的字色。
  current('floating_lyric_color_current'),

  /// 描边色（描边宽 > 0 时才可见）。
  outline('floating_lyric_color_outline');

  const FloatingLyricColorRole(this.prefKey);

  final String prefKey;
}

class PreferencesRepository extends ChangeNotifier
    implements PrefStore, AiSettingsSource {
  PreferencesRepository(this._db);

  /// TODO-855: persisted monotonic counter, the cross-process change signal the
  /// separate :popup process reads via [readPrefsVersionFromDb] to decide
  /// whether to reload its warm-reuse pref cache, instead of unconditionally
  /// re-scanning the whole preferences table on every lookup. The bump itself
  /// lives at the single lowest write choke point [FushiDatabase.setPref], so
  /// EVERY writer (this repository, ThemeNotifier, MediaSource, profile switch,
  /// sync/backup restore) advances it automatically. This is an alias to that
  /// DB-layer key so app-layer call sites (ProfileKeys, tests) share one truth.
  /// Excluded from profile snapshots (see ProfileKeys) so it stays app-global
  /// and monotonic.
  static const String prefsVersionKey = FushiDatabase.prefsVersionKey;

  final FushiDatabase _db;
  final Map<String, String> _prefCache = {};

  Future<void> loadFromDb() async {
    final all = await _db.getAllPrefs();
    _prefCache
      ..clear()
      ..addAll(all);
    // 把版本重读回来：缓存是**在它之前**读的，任何启动期修复写都会抬高持久化版本号，
    // 不重读会「版本不同 = 别的进程改过」每次启动误报一次、白重载一次。
    _prefCache[prefsVersionKey] =
        PrefCodec.encode(await readPrefsVersionFromDb());
    _installAppProxyReaders();
    // AI 多 key 轮换的冷却记录（引擎全局装配点）：落偏好表，app 重启后被拒 /
    // 限流的 key 仍在冷却里，不会一启动就把同一把坏 key 再打一遍。
    aiKeyHealthStore = _PrefsAiKeyHealthStore(this);
  }

  /// 把进程级代理读取器接到本仓库上。**绑定点必须是「偏好变得可读的那一刻」**，不是
  /// 某一个调用点：以前只有 `AppModel.initialise()` 绑，而弹窗词典进程
  /// （`AppModel.initialiseForDictionaryPopup`）同样建了本仓库、同样读了偏好，却没绑，
  /// 于是那个进程整段生命周期都落在 [kProxyModeUnresolved] 兜底上——选了「直连」的用户
  /// 在弹窗里照样走系统代理（哨兵表达不了 direct）。绑在这里，任何读得到偏好的入口都
  /// 自动拿到用户的真实选择，不必各自记得补一行。
  ///
  /// 读取器是闭包而非快照：设置页改完立刻生效，`findProxy` 请求时才求值。
  void _installAppProxyReaders() {
    appUserProxyReader = () => updateCustomProxy;
    appUserProxyModeReader = () => networkProxyMode;
    appUserProxyUsernameReader = () => networkProxyUsername;
    appUserProxyPasswordReader = () => networkProxyPassword;
  }

  Map<String, String> get prefsSnapshot =>
      Map<String, String>.unmodifiable(_prefCache);

  Future<void> refreshFromDb() async {
    await loadFromDb();
    notifyListeners();
  }

  @override
  dynamic getPref(String key, {dynamic defaultValue}) {
    final raw = _prefCache[key];
    if (raw == null) {
      return defaultValue;
    }
    return PrefCodec.decode(raw, defaultValue);
  }

  @override
  Future<void> setPref(String key, dynamic value) async {
    final String strVal = PrefCodec.encode(value);
    _prefCache[key] = strVal;
    // [FushiDatabase.setPref] also bumps the persisted prefs-version (TODO-855)
    // for any key other than the version key itself; no explicit bump needed
    // here. The in-memory [prefsVersion] getter intentionally does NOT track
    // that same-process bump — change detection is cross-process and goes
    // through [readPrefsVersionFromDb] / a full [loadFromDb] reload.
    await _db.setPref(key, strVal);
  }

  /// 一个**逻辑设置**由多个 key 承载时（三态投影成两个 bool 键、值 + 判别键……）的写入
  /// 入口：全部 key 一次性进内存缓存、再走 [FushiDatabase.setPrefs] 的**单事务**落盘。
  ///
  /// 对比逐个 [setPref]：省掉每键一次事务提交（Windows/WAL 实测 12.3ms → 5.1ms），并且
  /// 消除「半个设置已落盘」的可观察窗口——:popup 进程不会读到 blur=true / hide 尚未写入
  /// 的中间态。同样重要的是**同步段**：返回的 Future 之前，缓存里所有 key 已是新值，故
  /// 调用方可以先刷 UI 再落盘，getter 立即返回一致的完整设置。
  Future<void> setPrefs(Map<String, dynamic> values) async {
    final Map<String, String> encoded = <String, String>{
      for (final MapEntry<String, dynamic> e in values.entries)
        e.key: PrefCodec.encode(e.value),
    };
    _prefCache.addAll(encoded);
    await _db.setPrefs(encoded);
  }

  /// 只在持久化原值仍匹配快照时提交更新。耗时迁移在事务外准备文件，
  /// 此处仅短事务比较/写入，避免覆盖其它进程或用户期间的新配置。
  /// [expectedRaw] 使用 [prefsSnapshot] 的原始编码值；null 表示 key 不存在。
  Future<bool> compareAndSetPrefs({
    required Map<String, String?> expectedRaw,
    required Map<String, dynamic> updates,
  }) async {
    final Map<String, String> encoded = <String, String>{
      for (final MapEntry<String, dynamic> entry in updates.entries)
        entry.key: PrefCodec.encode(entry.value),
    };
    final bool applied = await _db.transaction(() async {
      final Map<String, String> persisted = await _db.getAllPrefs();
      for (final MapEntry<String, String?> entry in expectedRaw.entries) {
        if (persisted[entry.key] != entry.value) return false;
      }
      await _db.setPrefs(encoded);
      return true;
    });
    // 冲突时也刷新本进程，后续绑定必须使用赢家配置；提交前不改缓存。
    await loadFromDb();
    return applied;
  }

  /// The prefs-version value currently held in this process's in-memory cache,
  /// as last populated by [loadFromDb]/[refreshFromDb] (0 when never loaded).
  /// Cheap synchronous read; NOT a cross-process check and NOT advanced by this
  /// process's own [setPref] calls (the bump is sunk into the DB layer and only
  /// re-enters the cache on the next full reload). [AppModel] uses it solely to
  /// prime its watermark right after a reload; live change detection goes
  /// through [readPrefsVersionFromDb]. Stored as a PrefCodec int, so
  /// [PrefCodec.decode] tolerates both the tagged (`i:N`) and legacy raw (`N`)
  /// form.
  int get prefsVersion {
    final String? raw = _prefCache[prefsVersionKey];
    return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
  }

  /// Read the prefs-version straight from the DB (single indexed row lookup),
  /// bypassing this process's in-memory cache. The :popup process uses this to
  /// detect that the main app mutated a preference or switched profile while the
  /// warm-reuse popup was alive, without a full preferences-table reload.
  Future<int> readPrefsVersionFromDb() async {
    final String? raw = await _db.getPref(prefsVersionKey);
    return raw == null ? 0 : PrefCodec.decode<int>(raw, 0);
  }

  bool containsKey(String key) => _prefCache.containsKey(key);

  // ── player preferences ───────────────────────────────────────────────

  bool get playerHardwareAcceleration =>
      getPref('player_hardware_acceleration', defaultValue: true) as bool;

  void setPlayerHardwareAcceleration({required bool value}) async {
    await setPref('player_hardware_acceleration', value);
    notifyListeners();
  }

  /// TODO-702：有声书「退出阅读页后是否继续后台播放」。默认 **false** = 退出即停
  /// （detachReader 卸回调后 [AudiobookSession.stop] 真正止声/释放解码器，符合多数
  /// 用户「关掉书就别再响」的预期）。开启后退书只 detachReader、会话留在进程级常驻
  /// 持有者里继续后台播放（保 TODO-291 阶段2 的后台续播能力）。这是独立的偏好，
  /// **不复用**旧 `player_background_play` 死 pref（其代码通道已删除，复用会把语义
  /// 搅混）。getPref 仅在 key 从未写过时返回默认 false，已切过开关的用户保留其存值。
  bool get audiobookBackgroundPlay =>
      getPref('audiobook_background_play', defaultValue: false) as bool;

  Future<void> setAudiobookBackgroundPlay({required bool value}) async {
    await setPref('audiobook_background_play', value);
    notifyListeners();
  }

  /// 有声书 / 书籍导入对话框「引用原文件（不复制）」开关的上次选择（仅桌面有这个
  /// 开关）。默认 false = 复制进应用目录（原有行为）。两个导入对话框共用这一个键：
  /// 同一个用户对「音频要不要复制」的取向不随入口变（反馈 qLuedSmAnt：每次打开都
  /// 回到关，像被回退了）。
  bool get audiobookImportReferenceOriginal =>
      getPref('audiobook_import_reference_original', defaultValue: false)
          as bool;

  Future<void> setAudiobookImportReferenceOriginal({
    required bool value,
  }) async {
    await setPref('audiobook_import_reference_original', value);
    notifyListeners();
  }

  // ── search & dictionary display ──────────────────────────────────────

  bool get autoSearchEnabled =>
      getPref('auto_search', defaultValue: true) as bool;

  void toggleAutoSearchEnabled() async {
    await setPref('auto_search', !autoSearchEnabled);
    notifyListeners();
  }

  bool get remoteLookupEnabled =>
      getPref('remote_lookup_enabled', defaultValue: false) as bool;

  Future<void> setRemoteLookupEnabled(bool value) async {
    await setPref('remote_lookup_enabled', value);
    notifyListeners();
  }

  // TODO-861②（移植 Hoshi `07b5c09`）：是否扫描非日文文本进选区/查词。默认 true =
  // 现状（注入端原硬编码 true）。关闭时选区遇非日文码点即停（见
  // reader_selection_scripts.dart 的 isDelimiter 消费端）。
  bool get scanNonJapaneseText =>
      getPref('scan_non_japanese_text', defaultValue: true) as bool;

  Future<void> setScanNonJapaneseText(bool value) async {
    await setPref('scan_non_japanese_text', value);
    notifyListeners();
  }

  // ── dictionary auto-update (TODO-861③, ported from Hoshi 94d0c41) ────
  //
  // 启动时 check-due 自动更新词典。interval 存 enum `.name`（daily/weekly/monthly），
  // lastUpdate 存上次完整成功检查的 ISO8601 字符串（'' = 从未成功检查）。沿用既有
  // 持久化 key 兼容旧数据。默认 autoUpdate=false（opt-in，
  // 向后兼容，不在升级后静默联网/自动下载重导词典；用户须主动开启）、weekly。
  // MVP 只做启动 check-due，无计费网络门控（本仓库无 connectivity 依赖）。

  bool get autoUpdateDictionaries =>
      getPref('auto_update_dictionaries', defaultValue: false) as bool;

  Future<void> setAutoUpdateDictionaries(bool value) async {
    await setPref('auto_update_dictionaries', value);
    notifyListeners();
  }

  /// 检查周期的持久化 `.name`（daily/weekly/monthly）。默认 'weekly'。
  String get dictionaryUpdateIntervalName =>
      getPref('dictionary_update_interval', defaultValue: 'weekly') as String;

  Future<void> setDictionaryUpdateIntervalName(String name) async {
    await setPref('dictionary_update_interval', name);
    notifyListeners();
  }

  /// 上次完整成功检查时间（ISO8601）；解析失败/未设 → null（= 从未成功检查）。
  DateTime? get lastDictionaryUpdateAt {
    final String raw =
        getPref('last_dictionary_update_at', defaultValue: '') as String;
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> setLastDictionaryUpdateAt(DateTime when) async {
    await setPref('last_dictionary_update_at', when.toIso8601String());
    notifyListeners();
  }

  // ── 内容语言（内容字体链）────────────────────────────────────────────

  /// **全局默认内容语言**（BCP-47，如 `ja` / `zh-Hant`）。空串 = 未设置。
  ///
  /// 它是内容字体链优先级里的第三档，兜在资源级之后：
  /// `资源手动指定 > 内容自带元数据 > 本项 > 硬编码兜底链`（见
  /// `content_font_chain.dart` 的 [resolveContentLanguage]）。
  ///
  /// 存在的理由：前两档覆盖不全——外挂 SRT 不带语言标记、自制 EPUB 常缺
  /// `dc:language`、hook 出来的 galgame 文本更没有任何声明。逐个资源手动指定能解
  /// 决，但用户装的内容通常以某一种语言为主，给一个默认值比让他点几十次省事。
  /// 默认空串而不是 `ja`：本仓不做「内容恒为日语」这种全局假设。
  String get defaultContentLanguage =>
      getPref('default_content_language', defaultValue: '') as String;

  Future<void> setDefaultContentLanguage(String language) async {
    await setPref('default_content_language', language);
    notifyListeners();
  }

  // ── 库页排序方式（排序交互重设计 2026-07-12）──────────────────────────

  /// 书架排序方式 `.name`（recent/title/imported）。默认 recent（=历史序，现状零变化）。
  String get shelfSortModeName =>
      getPref('shelf_sort_mode', defaultValue: 'recent') as String;

  Future<void> setShelfSortModeName(String name) async {
    await setPref('shelf_sort_mode', name);
    notifyListeners();
  }

  /// 书架搜索栏「阅读状态」筛选的 [ShelfReadStatus] `.name`（unread/reading/
  /// finished）；空串 = 全部。跨重启保留（与游戏库页游玩状态筛选同一决定）。
  String get shelfReadStatusFilterName =>
      getPref('shelf_read_status_filter', defaultValue: '') as String;

  Future<void> setShelfReadStatusFilterName(String name) async {
    await setPref('shelf_read_status_filter', name);
  }

  /// 视频库排序方式 `.name`。默认 recent（最近观看，用户拍板；一键可切回导入时间）。
  String get videoSortModeName =>
      getPref('video_sort_mode', defaultValue: 'recent') as String;

  Future<void> setVideoSortModeName(String name) async {
    await setPref('video_sort_mode', name);
    notifyListeners();
  }

  /// 「全部视频」系列归属筛选 `.name`（all / inSeries / standalone）。默认
  /// standalone：合集里的视频在系列页折成卡片，平铺视图默认只看散片（BUG-2835）。
  String get videoAllSeriesFilterName =>
      getPref('video_all_series_filter', defaultValue: 'standalone') as String;

  Future<void> setVideoAllSeriesFilterName(String name) async {
    await setPref('video_all_series_filter', name);
    notifyListeners();
  }

  /// 已折叠的合集横排行 collectionId 集（书架/视频页共用；折叠 = 行只剩行头）。
  /// 逗号串存储；解析对空串/脏值宽容（tryParse 过滤）。
  Set<int> get collapsedCollectionIds {
    final String raw =
        getPref('collapsed_collection_ids', defaultValue: '') as String;
    return <int>{
      for (final String part in raw.split(','))
        if (int.tryParse(part) case final int id) id,
    };
  }

  Future<void> setCollapsedCollectionIds(Set<int> ids) async {
    final List<int> sorted = ids.toList()..sort();
    await setPref('collapsed_collection_ids', sorted.join(','));
    notifyListeners();
  }

  /// 游戏库合集横排行的折叠集（独立命名空间：同一个合集在书架折叠不应连带游戏库
  /// 折叠，两页各记各的）。存储格式与 [collapsedCollectionIds] 相同。
  Set<int> get gamesCollapsedCollectionIds {
    final String raw =
        getPref('games_collapsed_collection_ids', defaultValue: '') as String;
    return <int>{
      for (final String part in raw.split(','))
        if (int.tryParse(part) case final int id) id,
    };
  }

  Future<void> setGamesCollapsedCollectionIds(Set<int> ids) async {
    final List<int> sorted = ids.toList()..sort();
    await setPref('games_collapsed_collection_ids', sorted.join(','));
    notifyListeners();
  }

  /// 游戏库是否用列表布局（`games_library_layout` == 'list'）；默认海报网格。
  bool get gamesLibraryListLayout =>
      (getPref('games_library_layout', defaultValue: 'grid') as String) ==
      'list';

  Future<void> setGamesLibraryListLayout(bool list) async {
    await setPref('games_library_layout', list ? 'list' : 'grid');
    notifyListeners();
  }

  /// 多端库联合视图（spec 2026-07-12 §2.1/§2.4）：书架/视频页主网格是否把「远端有、
  /// 本地无」的条目渲染成占位卡（云角标 + 远端封面，点击下载/流播）。**默认 true**——
  /// 用户拍板远端混排默认开。关闭时占位卡全部不渲染，两页只剩本地库。离线/未配对/
  /// 后端不可达时占位卡本就不出现（远端目录拉取失败态），与本开关正交。
  bool get showRemoteEntries =>
      getPref('show_remote_entries', defaultValue: true) as bool;

  Future<void> setShowRemoteEntries(bool value) async {
    await setPref('show_remote_entries', value);
    notifyListeners();
  }

  /// 「仅从本机移除」的远端书（反馈 nvlhtczbro）：只在本机书架隐藏、对端那份不动。
  /// 按「来源身份 + 远端身份键」记（[HiddenRemoteBook.key]）——同名书在另一台
  /// host / 云盘上不受牵连。找回列表在 设置 › 同步 › 已从本机移除的远端书。
  /// 设备本地（`SyncRepository.deviceLocalPrefKeys`），不随备份 / 同步带到别的设备。
  List<HiddenRemoteBook> get hiddenRemoteBooks => decodeHiddenRemoteBooks(
        getPref('hidden_remote_books', defaultValue: null) as String?,
      );

  Future<void> setHiddenRemoteBooks(List<HiddenRemoteBook> books) async {
    await setPref('hidden_remote_books', encodeHiddenRemoteBooks(books));
    notifyListeners();
  }

  // ── Jellyfin / Emby 媒体服务器 ───────────────────────────────────────

  /// BUG-1891：进视频页（含切回视频 tab）时是否**自动**向已登录的 Jellyfin/Emby
  /// 服务器枚举条目。
  ///
  /// **默认 true**——绝大多数用户的服务器是自建小库，几百到几千条，自动列出正是他们
  /// 要的体验，改默认等于把所有人的远端卡片关掉去迁就少数人（Never break userspace）。
  /// 关掉之后进页面一个请求都不发，只复用上一次拉到的清单；要更新走视频页下拉刷新
  /// （手动 = 用户自己按的，风控无从抱怨）。这条开关只管 Jellyfin/Emby：互联对端与
  /// 云盘清单是自家后端，没有这种滥用检测问题，仍归 [showRemoteEntries] 管。
  bool get jellyfinAutoListVideos =>
      getPref('jellyfin_auto_list_videos', defaultValue: true) as bool;

  Future<void> setJellyfinAutoListVideos(bool value) async {
    await setPref('jellyfin_auto_list_videos', value);
    notifyListeners();
  }

  /// 系列详情页在宽屏上用「海报横幅」版式（与竖屏同形：fanart 横幅在顶、hero
  /// 叠在上面）而不是两栏（左栏信息、右栏选集）。默认 false = 两栏。
  bool get videoDetailPosterLayout =>
      getPref('video_detail_poster_layout', defaultValue: false) as bool;

  Future<void> setVideoDetailPosterLayout(bool value) async {
    await setPref('video_detail_poster_layout', value);
    notifyListeners();
  }

  /// 是否把 Jellyfin/Emby 条目混排进首页 / 系列 / 全部视频（B4）。默认 false：
  /// 媒体服务器条目只在视频页「媒体服务器」分区按服务器自己的树浏览，不再一进
  /// 视频页就整库拍平枚举；[jellyfinAutoListVideos] 只在本开关开着时才有意义。
  bool get jellyfinShowInLibrary =>
      getPref('jellyfin_show_in_library', defaultValue: false) as bool;

  Future<void> setJellyfinShowInLibrary(bool value) async {
    await setPref('jellyfin_show_in_library', value);
    notifyListeners();
  }

  /// 媒体服务器（Jellyfin/Emby）串流画质档下标；-1 = 自动（服务器允许时直播放原
  /// 文件）。选档 = 向服务器声明码率 / 宽度上限，超限由服务器转码到该档。
  int get mediaServerQualityPresetIndex =>
      getPref('video_media_server_quality_preset', defaultValue: -1) as int;

  Future<void> setMediaServerQualityPresetIndex(int index) async {
    await setPref('video_media_server_quality_preset', index);
    notifyListeners();
  }

  /// AI 多 key 轮换的冷却记录上限（超出按写入先后丢最旧的）。正常情况下成功一次
  /// 就清掉，留存的只有还在失败的 key，这个上限只防删掉的提供商留下的孤儿无界增长。
  static const int kAiKeyHealthLimit = 200;

  /// 冷却记录的偏好键（设备本地）。
  static const String aiKeyHealthPrefKey = 'ai_key_health';

  /// AI 多 key 轮换的冷却记录：`{指纹: AiKeyHealth.toJson()}`（指纹见
  /// `aiKeyFingerprint`，不含 key 本身）。设备本地。解析失败回退空 map——冷却
  /// 记录丢了只等于「这些 key 下次照常再试」，不能挡住请求。
  Map<String, AiKeyHealth> get aiKeyHealth => _decodeAiKeyHealth(
    getPref(aiKeyHealthPrefKey, defaultValue: '') as String,
  );

  /// 正在落库的 [updateAiKeyHealth] 笔数；归零时才把缓存对齐到持久值。
  int _aiKeyHealthWritesInFlight = 0;

  /// 改一条冷却记录（[AiKeyHealthStore.update] 的偏好表实现）。不 notifyListeners：
  /// 设置页在自己的探测结束时重建，没有别的界面监听它。
  ///
  /// 对同一条记录分两处各算一次 [update]（所以它必须是纯函数）：
  /// 1. 进程内缓存**同步**生效——请求热路径上的下一次 read 立刻看得到；
  /// 2. 落库在一个事务里**重读最新持久值**、只改 [fingerprint] 这一条再写回。
  ///    弹窗词典 `:popup` 进程与主进程各有一份偏好缓存，拿自己缓存里的整份 map
  ///    覆盖写回会抹掉对方刚记的冷却；按条合并则互不影响，[update] 看到的也是
  ///    别的进程写过之后的当前值。
  /// 最后一笔在途写完成时把缓存换成持久值（顺带收进别的进程记的条目）。
  Future<void> updateAiKeyHealth(
    String fingerprint,
    AiKeyHealthUpdate update,
  ) async {
    final Map<String, AiKeyHealth> cached = aiKeyHealth;
    if (_applyAiKeyHealthUpdate(cached, fingerprint, update)) {
      _prefCache[aiKeyHealthPrefKey] =
          PrefCodec.encode(_encodeAiKeyHealth(cached));
    }
    // 缓存里没变也照样去持久值上算一遍：别的进程可能刚写过这一条（例如缓存里
    // 没有、持久值里有），只看缓存就跳过会漏掉该做的清除 / 合并。没变时事务里
    // 只有一次读、不写不抬版本号。
    _aiKeyHealthWritesInFlight++;
    final String? persistedRaw;
    try {
      persistedRaw = await _db.transaction(() async {
        final String? raw = await _db.getPref(aiKeyHealthPrefKey);
        final Map<String, AiKeyHealth> persisted = _decodeAiKeyHealth(
          raw == null ? '' : PrefCodec.decode<String>(raw, ''),
        );
        if (!_applyAiKeyHealthUpdate(persisted, fingerprint, update)) {
          return raw;
        }
        final String encoded =
            PrefCodec.encode(_encodeAiKeyHealth(persisted));
        await _db.setPref(aiKeyHealthPrefKey, encoded);
        return encoded;
      });
    } finally {
      _aiKeyHealthWritesInFlight--;
    }
    if (_aiKeyHealthWritesInFlight > 0) return;
    if (persistedRaw == null) {
      _prefCache.remove(aiKeyHealthPrefKey);
    } else {
      _prefCache[aiKeyHealthPrefKey] = persistedRaw;
    }
  }

  /// 对 [map] 里 [fingerprint] 这一条套用 [update]；值没变返回 false（不必落库）。
  /// 改过的条目挪到末尾，超出 [kAiKeyHealthLimit] 时丢最旧的。
  static bool _applyAiKeyHealthUpdate(
    Map<String, AiKeyHealth> map,
    String fingerprint,
    AiKeyHealthUpdate update,
  ) {
    final AiKeyHealth? current = map[fingerprint];
    final AiKeyHealth? next = update(current);
    if (next == current) return false;
    map.remove(fingerprint);
    if (next != null) map[fingerprint] = next;
    while (map.length > kAiKeyHealthLimit) {
      map.remove(map.keys.first);
    }
    return true;
  }

  static Map<String, AiKeyHealth> _decodeAiKeyHealth(String raw) {
    if (raw.isEmpty) return <String, AiKeyHealth>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return <String, AiKeyHealth>{
          for (final MapEntry<dynamic, dynamic> e in decoded.entries)
            if (AiKeyHealth.fromJson(e.value) case final AiKeyHealth health)
              e.key.toString(): health,
        };
      }
    } on FormatException catch (e, stack) {
      ErrorLogService.instance
          .log('PreferencesRepository.aiKeyHealth.decode', e, stack);
    }
    return <String, AiKeyHealth>{};
  }

  static String _encodeAiKeyHealth(Map<String, AiKeyHealth> map) =>
      map.isEmpty
          ? ''
          : jsonEncode(<String, Object?>{
              for (final MapEntry<String, AiKeyHealth> e in map.entries)
                e.key: e.value.toJson(),
            });

  // ── yomitan-api server ───────────────────────────────────────────────

  bool get fushiApiServerEnabled =>
      getPref('yomitan_api_server_enabled', defaultValue: false) as bool;

  Future<void> setFushiApiServerEnabled(bool value) async {
    await setPref('yomitan_api_server_enabled', value);
    notifyListeners();
  }

  int get fushiApiPort =>
      getPref('yomitan_api_port', defaultValue: 19633) as int;

  Future<void> setFushiApiPort(int value) async {
    await setPref('yomitan_api_port', value);
    notifyListeners();
  }

  String get fushiApiKey =>
      getPref('yomitan_api_key', defaultValue: '') as String;

  Future<void> setFushiApiKey(String value) async {
    await setPref('yomitan_api_key', value);
    notifyListeners();
  }

  // ── 实验性：键盘/手柄焦点导航 ──────────────────────────────────────────
  // 整套自定义焦点导航（FushiFocusRoot/Ring + 手柄/方向键焦点移动）默认关闭，
  // 关闭时回退到 Flutter 原生焦点遍历。空格不再确认焦点的行为不受此开关影响。

  bool get experimentalFocusNavigationEnabled =>
      getPref('experimental_focus_navigation_enabled', defaultValue: false)
          as bool;

  Future<void> setExperimentalFocusNavigationEnabled(bool value) async {
    await setPref('experimental_focus_navigation_enabled', value);
    notifyListeners();
  }

  // ── desktop global lookup ────────────────────────────────────────────

  // TODO-1030 M0 — 全局查词（应用外）是否抓取选中文本周围的上下文句。默认 false：
  // 抓取要读前台应用的 UIA 文本，隐私敏感，用户显式开启才启用；关闭时全局查词只用
  // 剪贴板拿到的纯选中串（现状），不接触前台应用文本。
  bool get globalContextCaptureEnabled =>
      getPref('lookup.global_context_capture', defaultValue: false) as bool;

  Future<void> setGlobalContextCaptureEnabled(bool value) async {
    await setPref('lookup.global_context_capture', value);
    notifyListeners();
  }

  /// 查词输入框希望输入法切到哪种语言（BCP-47，`ja` / `zh-Hans` / `ko`…）。
  /// 空串 = 未设置，不碰输入法——默认不动用户的系统输入法状态。
  ///
  /// 这**不是**「查词的目标语言」：查词流水线语言无关（18 种变换表全量加载是有意
  /// 设计），`AppModel.targetLanguage` 那个恒定单值的假抽象已于 2026-07-26 删除且
  /// 有守卫钉着。本偏好只决定输入法/软键盘切到哪种语言，不进查询链路。
  String get lookupImeLanguage =>
      getPref('lookup.ime_language', defaultValue: '') as String;

  Future<void> setLookupImeLanguage(String value) async {
    await setPref('lookup.ime_language', value);
    notifyListeners();
  }

  /// 防截屏（桌面查词浮窗，Windows）—— 覆盖窗设 SetWindowDisplayAffinity
  /// (WDA_EXCLUDEFROMCAPTURE)，对用户可见但从截图 / 录屏 / 屏幕共享排除。
  /// 默认 false（用户要求默认关闭，2026-07）。
  /// 存储键 `clipboard_panel_block_capture` 是历史名（该偏好最初随剪贴板面板引入，
  /// 面板已删；持久化键冻结不追改，避免用户已存的开关值丢失）。
  bool get lookupBlockCapture =>
      getPref('clipboard_panel_block_capture', defaultValue: false) as bool;

  Future<void> setLookupBlockCapture(bool value) async {
    await setPref('clipboard_panel_block_capture', value);
    notifyListeners();
  }

  final int defaultSearchDebounceDelay = 100;

  int get searchDebounceDelay => getPref('auto_search_debounce_delay',
      defaultValue: defaultSearchDebounceDelay) as int;

  void setSearchDebounceDelay(int debounceDelay) async {
    await setPref('auto_search_debounce_delay', debounceDelay);
    notifyListeners();
  }

  final double defaultDictionaryFontSize = 16;

  double get dictionaryFontSize => getPref('dictionary_entry_font_size',
      defaultValue: defaultDictionaryFontSize) as double;

  void setDictionaryFontSize(double fontSize) async {
    await setPref('dictionary_entry_font_size', fontSize);
    notifyListeners();
  }

  final double defaultPopupMaxWidth = 400;

  double get popupMaxWidth =>
      getPref('popup_max_width', defaultValue: defaultPopupMaxWidth) as double;

  void setPopupMaxWidth(double width) async {
    await setPref('popup_max_width', width);
    notifyListeners();
  }

  final double defaultPopupMaxHeight = 360;

  double get popupMaxHeight =>
      getPref('popup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setPopupMaxHeight(double height) async {
    await setPref('popup_max_height', height);
    notifyListeners();
  }

  // 查词弹窗尺寸精细化（2026-07-13 设计）：app 外覆盖窗 / 浏览器扩展各自可「独立尺寸」。
  // 默认 independent=false → 跟随 app 内 popupMaxWidth/Height；用户显式解锁后用各自键。
  // 各自宽/高默认值等于 app 内默认（400×360），保证解锁瞬间不跳尺寸。

  bool get overlayLookupIndependentSize =>
      getPref('overlay_lookup_independent_size', defaultValue: false) as bool;

  Future<void> setOverlayLookupIndependentSize(bool value) async {
    await setPref('overlay_lookup_independent_size', value);
    notifyListeners();
  }

  double get overlayLookupMaxWidth =>
      getPref('overlay_lookup_max_width', defaultValue: defaultPopupMaxWidth)
          as double;

  void setOverlayLookupMaxWidth(double width) async {
    await setPref('overlay_lookup_max_width', width);
    notifyListeners();
  }

  double get overlayLookupMaxHeight =>
      getPref('overlay_lookup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setOverlayLookupMaxHeight(double height) async {
    await setPref('overlay_lookup_max_height', height);
    notifyListeners();
  }

  // 游戏内查词卡（galgame hook 直接贴进游戏画面的那张）是**第三个形态**。它与 app 外
  // 覆盖窗曾共用 overlay 那组键，于是「游戏里合适」和「桌面上合适」只能二选一——真机上
  // 表现为一个过小、另一个过大。合适尺寸本就不同：覆盖窗浮在整块桌面上，游戏内卡片要
  // 挤在游戏客户区里且不能遮住正文，所以给它自己的键。默认同样 independent=false，
  // 跟随 app 内共享值，解锁后才用自己的宽高（解锁瞬间不跳尺寸）。
  bool get galCardLookupIndependentSize =>
      getPref('gal_card_lookup_independent_size', defaultValue: false) as bool;

  Future<void> setGalCardLookupIndependentSize(bool value) async {
    await setPref('gal_card_lookup_independent_size', value);
    notifyListeners();
  }

  double get galCardLookupMaxWidth =>
      getPref('gal_card_lookup_max_width', defaultValue: defaultPopupMaxWidth)
          as double;

  void setGalCardLookupMaxWidth(double width) async {
    await setPref('gal_card_lookup_max_width', width);
    notifyListeners();
  }

  double get galCardLookupMaxHeight =>
      getPref('gal_card_lookup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setGalCardLookupMaxHeight(double height) async {
    await setPref('gal_card_lookup_max_height', height);
    notifyListeners();
  }

  bool get extensionPopupIndependentSize =>
      getPref('extension_popup_independent_size', defaultValue: false) as bool;

  Future<void> setExtensionPopupIndependentSize(bool value) async {
    await setPref('extension_popup_independent_size', value);
    notifyListeners();
  }

  double get extensionPopupMaxWidth =>
      getPref('extension_popup_max_width', defaultValue: defaultPopupMaxWidth)
          as double;

  void setExtensionPopupMaxWidth(double width) async {
    await setPref('extension_popup_max_width', width);
    notifyListeners();
  }

  double get extensionPopupMaxHeight =>
      getPref('extension_popup_max_height', defaultValue: defaultPopupMaxHeight)
          as double;

  void setExtensionPopupMaxHeight(double height) async {
    await setPref('extension_popup_max_height', height);
    notifyListeners();
  }

  // TODO-776: number of dictionary blocks rendered per row inside one entry's
  // glossary section (experimental). Default 1 = the classic single vertical
  // column; clamped to 1..4 both on read and write so a corrupt/out-of-range
  // stored value can never reach the CSS grid as an absurd column count.
  int get popupDictionaryColumns =>
      (getPref('popup_dictionary_columns', defaultValue: 1) as int).clamp(1, 4);

  /// TODO-1357: 用户是否显式设过弹窗列数。区分「从未设→用平台默认（桌面 2 / 移动 1，
  /// 在 [AppModel.popupDictionaryColumns] 解析）」与「显式设过→遵从其值」（三态）。
  bool get hasExplicitPopupDictionaryColumns =>
      containsKey('popup_dictionary_columns');

  Future<void> setPopupDictionaryColumns(int columns) async {
    await setPref('popup_dictionary_columns', columns.clamp(1, 4));
    notifyListeners();
  }

  // TODO-845: how many leading *rows* of dictionary blocks the lookup popup
  // auto-expands (force-open <details>) even when "collapse dictionaries" is on.
  // The unit is rows, not blocks: popup.js expands `rows × effective columns`
  // (see autoExpandCount there), so the expanded region is always whole top rows
  // and never fights the --dict-columns masonry. Default 1 preserves the
  // historical "only the first dictionary is expanded" behaviour, because the
  // default column count is 1 (1 row × 1 column === 1 block).
  //
  // The storage key keeps its legacy `popup_auto_expand_dictionaries` name so
  // existing stored values carry over untouched. Clamped to 0..6 on read and
  // write so a corrupt/out-of-range stored value can never reach popup.js as an
  // absurd expand threshold; the clamp range is identical to the lookup settings
  // slider min/max.
  int get popupAutoExpandDictionaries =>
      (getPref('popup_auto_expand_dictionaries', defaultValue: 1) as int)
          .clamp(0, 6);

  /// TODO-1357: 用户是否显式设过自动展开词典数（三态，同 [hasExplicitPopupDictionaryColumns]）。
  bool get hasExplicitPopupAutoExpandDictionaries =>
      containsKey('popup_auto_expand_dictionaries');

  Future<void> setPopupAutoExpandDictionaries(int count) async {
    await setPref('popup_auto_expand_dictionaries', count.clamp(0, 6));
    notifyListeners();
  }

  // Default OFF (smooth/animated popup scrolling). Instant (no-animation)
  // jump scrolling is an e-ink opt-in enabled only by the dedicated lookup
  // setting. getPref returns this default solely when the key was never set,
  // so existing users who already toggled the switch keep their stored value.
  bool get popupInstantScroll =>
      getPref('popup_instant_scroll', defaultValue: false) as bool;

  Future<void> setPopupInstantScroll(bool value) async {
    await setPref('popup_instant_scroll', value);
    notifyListeners();
  }

  // 瞬时滚动步长：一次跳被滚表面视口高度的多大比例。BUG-2284 / BUG-2415 里写死在
  // popup.js 的 POPUP_EINK_WHEEL_VIEWPORT_FRACTION(0.5) / POPUP_EINK_TOUCH_VIEWPORT_
  // FRACTION(0.25) 现在只是默认值；墨水屏尺寸与刷新特性差异大，用户按自己的屏调。
  // 两条路径各一个旋钮：滚轮是离散 notch（一格跳半屏顺手），触摸是量化的 1:1 跟手
  // （手指滑满一步才跳一步，1/4 屏更跟手）——默认值本就不同，硬合成一个会改掉其中
  // 一边的现有行为。clamp 到 [0.1, 1.0]：popup.js 侧同样夹在 [MIN_STEP, 一屏] 内，
  // 永不一步跳过整屏内容。下发通道与 popupInstantScroll 完全同法（in-app 注入
  // window.__fushiPopupInstantScroll{Wheel,Touch}Step；扩展经 theme
  // --fushi-instant-scroll-wheel-step，触摸半边扩展侧不挂所以不下发）。
  static const double kPopupInstantScrollWheelStepDefault = 0.5;
  static const double kPopupInstantScrollTouchStepDefault = 0.25;
  static const double kPopupInstantScrollStepMin = 0.1;
  static const double kPopupInstantScrollStepMax = 1.0;

  static double _clampInstantScrollStep(Object? raw, double fallback) {
    if (raw is! num) return fallback;
    final double v = raw.toDouble();
    if (!v.isFinite) return fallback;
    return v.clamp(kPopupInstantScrollStepMin, kPopupInstantScrollStepMax);
  }

  double get popupInstantScrollWheelStep => _clampInstantScrollStep(
        getPref('popup_instant_scroll_wheel_step',
            defaultValue: kPopupInstantScrollWheelStepDefault),
        kPopupInstantScrollWheelStepDefault,
      );

  Future<void> setPopupInstantScrollWheelStep(double value) async {
    await setPref(
      'popup_instant_scroll_wheel_step',
      _clampInstantScrollStep(value, kPopupInstantScrollWheelStepDefault),
    );
    notifyListeners();
  }

  double get popupInstantScrollTouchStep => _clampInstantScrollStep(
        getPref('popup_instant_scroll_touch_step',
            defaultValue: kPopupInstantScrollTouchStepDefault),
        kPopupInstantScrollTouchStepDefault,
      );

  Future<void> setPopupInstantScrollTouchStep(double value) async {
    await setPref(
      'popup_instant_scroll_touch_step',
      _clampInstantScrollStep(value, kPopupInstantScrollTouchStepDefault),
    );
    notifyListeners();
  }

  // BUG-1026：查词弹窗滚轮速度倍率。popup.js 的粗鼠标 notch 用 0.24 降速系数（BUG-260），
  // 部分用户觉得太慢；此倍率乘进 popup.js 的 factor（同乘粗鼠标 0.24 与触控板 1.0），
  // 作为统一「滚轮速度」旋钮。默认 1.0 与改前逐帧一致。clamp 0.5–5.0 防越界值把滚动放飞。
  // 一处存储驱动全部弹窗：in-app 三种弹窗经 popup_settings_injection 注入
  // window.__fushiPopupWheelSpeed；浏览器扩展弹窗经查词响应 theme 的 --fushi-wheel-speed 下发。
  double get popupWheelSpeed {
    final double v =
        (getPref('popup_wheel_speed', defaultValue: 1.0) as num).toDouble();
    return v.isFinite ? v.clamp(0.5, 5.0) : 1.0;
  }

  Future<void> setPopupWheelSpeed(double value) async {
    final double v = value.isFinite ? value.clamp(0.5, 5.0) : 1.0;
    await setPref('popup_wheel_speed', v);
    notifyListeners();
  }

  // TODO-108：查词弹窗显示模式。默认 OFF（跟随被查词位置，即现状的左/右/上/下避让）。
  // ON 时弹窗固定为屏幕底部一条全宽面板，忽略选区位置——适合需要稳定固定弹窗落点的
  // 用户。getPref 仅在 key 从未写过时返回默认 false，已切过开关的用户保留其存值。
  bool get popupBottomDocked =>
      getPref('popup_bottom_docked', defaultValue: false) as bool;

  Future<void> setPopupBottomDocked(bool value) async {
    await setPref('popup_bottom_docked', value);
    notifyListeners();
  }

  /// 底部停靠在各媒体页里是否生效（总开关 [popupBottomDocked] 之下的按模块细分）。
  /// 不是所有场景都需要停靠：例如只想在视频里固定弹窗、小说里仍跟随选区。
  /// 顺序 = 设置页展示顺序。
  static const List<ModuleId> kPopupBottomDockedModules = <ModuleId>[
    ModuleId.books,
    ModuleId.manga,
    ModuleId.video,
    ModuleId.games,
  ];

  /// 按模块细分的持久化键。显式列出而不是拼 `module.name`（[ModuleId.prefKey]
  /// 的纪律：键永不随枚举改名漂移）；不在 [kPopupBottomDockedModules] 里的模块
  /// 返回 `null`，只听总开关。
  static String? popupBottomDockedKeyFor(ModuleId module) => switch (module) {
        ModuleId.books => 'popup_bottom_docked_books',
        ModuleId.manga => 'popup_bottom_docked_manga',
        ModuleId.video => 'popup_bottom_docked_video',
        ModuleId.games => 'popup_bottom_docked_games',
        _ => null,
      };

  /// 默认 ON：升级上来的用户打开总开关时行为与旧版（全局停靠）一致。
  bool popupBottomDockedIn(ModuleId module) {
    final String? key = popupBottomDockedKeyFor(module);
    if (key == null) return true;
    return getPref(key, defaultValue: true) as bool;
  }

  Future<void> setPopupBottomDockedIn(ModuleId module, bool value) async {
    final String? key = popupBottomDockedKeyFor(module);
    if (key == null) return;
    await setPref(key, value);
    notifyListeners();
  }

  /// 用户请求（Flow Launcher 式用法）：app 外热键把主窗置顶到查词页、查完按「返回
  /// 上一级」（默认 Esc）直接把窗口收回去，不用碰鼠标就回到之前的程序。默认 OFF——
  /// 首页根路由上 globalBack 原本是 no-op，开了才把这一步接成「最小化主窗」；只对
  /// 桌面有意义（移动端没有「最小化」这回事，消费端按平台早退）。
  bool get lookupPageEscapeMinimizesWindow =>
      getPref('lookup_page_escape_minimizes_window', defaultValue: false)
          as bool;

  Future<void> setLookupPageEscapeMinimizesWindow(bool value) async {
    await setPref('lookup_page_escape_minimizes_window', value);
    notifyListeners();
  }

  bool get isFirstTimeSetup =>
      getPref('first_time_setup', defaultValue: true) as bool;

  void setFirstTimeSetupFlag() async {
    await setPref('first_time_setup', false);
  }

  /// 「功能模块」显隐：用户意愿的**唯一存储**，一个 [ModuleId] 一个键。
  ///
  /// 默认开（与旧版行为一致；复习 [ModuleId.srs] 老用户由一次性迁移写成关）；新手引导的功能选择与 设置 → 外观 → 功能模块
  /// 写同一真值。games（Windows）与浏览器扩展（桌面）的平台门控**不在这里**——
  /// 这里只存用户意愿，平台判据统一在 [ModuleId.availableOn] 判一次，合成见
  /// [ModuleVisibility.resolve]。首页/设置恒在，是全部关闭后的安全回退面，
  /// 没有对应 [ModuleId]。
  ///
  /// 此前这里是七对手写 getter/setter（22 行/模块），加一个模块要在 prefs /
  /// AppModel / 设置 schema / 引导 / 底栏 / macOS 侧栏各抄一遍，少抄一处就静默
  /// 漏一处门控。现在读写都走枚举，加模块只加一个 enum 值。
  ///
  /// 缺省值按模块取 [ModuleId.defaultEnabled]（全部默认开）。
  ///
  /// 复习例外：本安装的老 / 新用户判定（[settleSrsMiningTargetInstallDefault]）还没跑过
  /// 时按关读——与 [srsMiningTarget] 判定前按 'anki' 同一方向，老用户升级后在主进程
  /// 首启之前（:popup 进程、整层恢复老备份后）不会冒出复习入口。
  bool moduleEnabled(ModuleId module) {
    if (module == ModuleId.srs &&
        getPref(module.prefKey, defaultValue: null) == null &&
        getPref(srsMiningTargetInstallDefaultKey, defaultValue: null) ==
            null) {
      return false;
    }
    return getPref(module.prefKey, defaultValue: module.defaultEnabled)
        as bool;
  }

  Future<void> setModuleEnabled(ModuleId module, bool value) async {
    await setPref(module.prefKey, value);
    notifyListeners();
  }

  /// 「功能模块」的用户排序（底栏 / 侧栏 tab 顺序）。与开关同为设备本地键
  /// （[ModuleId.devicePrefKeys]）；缺省空 = 枚举顺序。
  List<ModuleId> get moduleOrder => ModuleId.parseOrder(
        getPref(ModuleId.orderPrefKey, defaultValue: '') as String,
      );

  Future<void> setModuleOrder(List<ModuleId> order) async {
    await setPref(ModuleId.orderPrefKey, ModuleId.encodeOrder(order));
    notifyListeners();
  }

  /// 新手引导完成标志。缺省值刻意取 **true**：既有安装升级上来不重弹引导；
  /// 全新安装在 HomePage 的 `first_time_setup` 首帧分支里显式写 false，向导
  /// 关闭后写回 true——中途杀进程下次启动值仍是 false，会重新弹出。备份合并的
  /// insert-if-absent 天然不会覆盖本键（描述本库自身状态，同 `first_time_setup`）。
  bool get onboardingCompleted =>
      getPref('onboarding_completed', defaultValue: true) as bool;

  Future<void> setOnboardingCompleted({required bool value}) async {
    await setPref('onboarding_completed', value);
  }

  final int defaultMaximumDictionaryTermsInResult = 10;

  int get maximumTerms => getPref('maximum_terms',
      defaultValue: defaultMaximumDictionaryTermsInResult) as int;

  void setMaximumTerms(int value) async {
    await setPref('maximum_terms', value);
    notifyListeners();
  }

  // ── home tab ─────────────────────────────────────────────────────────

  int get currentHomeTabIndex =>
      getPref('current_home_tab_index', defaultValue: 0) as int;

  Future<void> setCurrentHomeTabIndex(int index) async {
    await setPref('current_home_tab_index', index);
  }

  /// 旧开关「启动时打开查词」的持久化键，已由 [ModuleId.startupPrefKey] 取代。
  /// 只读不写：[ModuleId.startupPrefKey] 从未写过时据此迁移（开着 = 查词）。
  static const String legacyStartupDictionaryTabKey =
      'startup_default_dictionary_tab';

  /// 启动页模块；`null` = 默认（底栏第一个可见页）。只是用户意愿：所选模块此刻
  /// 是否可见由 `homeInitialTab` 判，不可见时回退默认。
  ///
  /// 迁移：新键从未写过（`getPref` 返回 null）时读旧开关——升级前开了「启动时打开
  /// 查词」的用户启动页 = 查词。新键一旦写过（含写成默认的空串），旧开关不再读。
  ModuleId? get startupModule {
    final Object? stored = getPref(ModuleId.startupPrefKey);
    if (stored is String) return ModuleId.tryParsePrefKey(stored);
    final bool legacyLookup =
        getPref(legacyStartupDictionaryTabKey, defaultValue: false) as bool;
    return legacyLookup ? ModuleId.lookup : null;
  }

  Future<void> setStartupModule(ModuleId? module) async {
    await setPref(ModuleId.startupPrefKey, module?.prefKey ?? '');
    notifyListeners();
  }

  bool get reverseNavigationBar =>
      getPref('reverse_navigation_bar', defaultValue: false) as bool;

  void toggleReverseNavigationBar() async {
    await setPref('reverse_navigation_bar', !reverseNavigationBar);
    notifyListeners();
  }

  /// 宽屏主导航 rail（MD3 / M3 Expressive）用户手动选的展开 / 收起：
  /// `''` = 未选过（按窗口尺寸档：expanded 档展开、medium 档收起）、
  /// `'expanded'` / `'collapsed'`。由 rail 顶部的菜单钮切换并记忆。
  bool? get navRailExpanded {
    final String value =
        getPref('nav_rail_expanded', defaultValue: '') as String;
    if (value == 'expanded') return true;
    if (value == 'collapsed') return false;
    return null;
  }

  Future<void> setNavRailExpanded(bool expanded) async {
    await setPref('nav_rail_expanded', expanded ? 'expanded' : 'collapsed');
  }

  /// MD3 悬浮底栏是否在图标下显示标签。默认关 = M3E floating toolbar 的纯图标
  /// 形态（标签进 tooltip / 语义；用户 2026-10-06「底部栏的文字砍掉」）。只有
  /// 显式打开过开关、库里存了 true 的用户才继续显示标签。
  bool get navBarLabelsVisible =>
      getPref('nav_bar_labels_visible', defaultValue: false) as bool;

  Future<void> setNavBarLabelsVisible(bool value) async {
    await setPref('nav_bar_labels_visible', value);
    notifyListeners();
  }

  /// 手机底栏形态（[AdaptiveNavBarStyle]）：平铺 / 分页滑动。没写过时取
  /// [AdaptiveNavBarStyle.defaultStyle]（2026-10-16 起为分页滑动）；只在用户
  /// 显式选择时落库，所以「没选过」与「选了平铺」可区分。
  AdaptiveNavBarStyle get navBarStyle => AdaptiveNavBarStyle.fromPref(
    getPref('nav_bar_style', defaultValue: '') as String,
  );

  Future<void> setNavBarStyle(AdaptiveNavBarStyle value) async {
    await setPref('nav_bar_style', value.prefValue);
    notifyListeners();
  }

  bool get reverseReaderBottomBar =>
      getPref('reverse_reader_bottom_bar', defaultValue: false) as bool;

  void toggleReverseReaderBottomBar() async {
    await setPref('reverse_reader_bottom_bar', !reverseReaderBottomBar);
    notifyListeners();
  }

  /// 启用的 mpv 着色器（JSON 字符串数组的文件名，相对着色器目录）。空串=未启用。
  /// 解析/编码见 video_shader_manager.dart 的 encode/decodeEnabledShaders。
  /// 用户自配的 OPDS 书目服务器清单（设备本地；含 base64 密码）。
  ///
  /// 逐条容错在 [decodeOpdsServerConfigs] 里：一条记录坏掉只丢那一条，不让
  /// 整份服务器列表消失（否则用户会看到「我的书库全没了」）。
  List<OpdsServerConfig> get discoveryOpdsServers {
    final String raw =
        getPref('discovery_opds_servers', defaultValue: '') as String;
    if (raw.trim().isEmpty) return const <OpdsServerConfig>[];
    try {
      return decodeOpdsServerConfigs(raw);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'PreferencesRepository.discoveryOpdsServers.decode',
        error,
        stack,
      );
      return const <OpdsServerConfig>[];
    }
  }

  Future<void> setDiscoveryOpdsServers(
    Iterable<OpdsServerConfig> servers,
  ) async {
    await setPref('discovery_opds_servers', encodeOpdsServerConfigs(servers));
    notifyListeners();
  }

  /// 用户自配的 Audiobookshelf 服务器清单（设备本地；含 base64 令牌）。
  /// 逐条容错同 [discoveryOpdsServers]。
  List<AudiobookshelfServerConfig> get discoveryAudiobookshelfServers {
    final String raw =
        getPref('discovery_audiobookshelf_servers', defaultValue: '')
            as String;
    if (raw.trim().isEmpty) return const <AudiobookshelfServerConfig>[];
    try {
      return decodeAudiobookshelfServerConfigs(raw);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'PreferencesRepository.discoveryAudiobookshelfServers.decode',
        error,
        stack,
      );
      return const <AudiobookshelfServerConfig>[];
    }
  }

  Future<void> setDiscoveryAudiobookshelfServers(
    Iterable<AudiobookshelfServerConfig> servers,
  ) async {
    await setPref(
      'discovery_audiobookshelf_servers',
      encodeAudiobookshelfServerConfigs(servers),
    );
    notifyListeners();
  }

  /// 用户自配的 AI 提供商清单（设备本地；含 base64 API key）。
  ///
  /// 与 [discoveryOpdsServers] 同范式：逐条容错在 [decodeAiProviderConfigs] 里，
  /// 一条记录坏掉只丢那一条，不让整份清单消失。
  @override
  List<AiProviderConfig> get aiProviders {
    final String raw = getPref('ai_providers', defaultValue: '') as String;
    if (raw.trim().isEmpty) return const <AiProviderConfig>[];
    try {
      return decodeAiProviderConfigs(raw);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'PreferencesRepository.aiProviders.decode',
        error,
        stack,
      );
      return const <AiProviderConfig>[];
    }
  }

  Future<void> setAiProviders(Iterable<AiProviderConfig> providers) async {
    await setPref('ai_providers', encodeAiProviderConfigs(providers));
    notifyListeners();
  }

  /// 运行时**生效**的「哪个功能用哪家 AI」：AI 模块（[ModuleId.ai]）关掉时投影成
  /// 空指派，于是每个 `AiFeature` 都解析不到提供商——行为与「从没配过 AI」完全
  /// 一致，后台刮削 / 补字幕 / AI 下载 / 漫画 OCR 重读一个请求都不发。
  ///
  /// 这是 AI 调用层（[AiSettingsSource] 的全部消费方）的唯一门：入口 UI 另由
  /// `isAiModuleEnabled` 藏，但即使某个入口漏藏，这里也兜住不发请求。设置页编辑
  /// 用户真实存的指派一律读 [storedAiFeatureAssignments]，不读本 getter——否则模块
  /// 关着时编辑再保存会把真实指派清空。
  @override
  AiFeatureAssignments get aiFeatureAssignments => moduleEnabled(ModuleId.ai)
      ? storedAiFeatureAssignments
      : const AiFeatureAssignments();

  /// 用户真实存的「哪个功能用哪家 AI」映射（设备本地），不看 AI 模块开关。
  /// 只给设置 › AI 编辑用；运行时解析走 [aiFeatureAssignments]。
  AiFeatureAssignments get storedAiFeatureAssignments {
    final String raw = getPref(
      'ai_feature_providers',
      defaultValue: '',
    ) as String;
    return AiFeatureAssignments.fromJson(raw);
  }

  Future<void> setAiFeatureAssignments(AiFeatureAssignments value) async {
    await setPref('ai_feature_providers', value.toJson());
    notifyListeners();
  }

  /// [resolveAiFeatureProvider] 的解码缓存，键是两份**原始**偏好串。
  ({
    String? providersRaw,
    String? assignmentsRaw,
    List<AiProviderConfig> providers,
    AiFeatureAssignments assignments,
  })? _aiResolveCache;

  /// 「[feature] 当前该用哪家 AI」，与
  /// `aiFeatureAssignments.resolve(feature, aiProviders)` 同义。
  ///
  /// 调用方可能在热路径上反复问，而 [aiProviders] 每读一次都要
  /// 解 JSON + base64。这里以 `ai_providers` / `ai_feature_providers` 的原始串为
  /// 缓存键：任何写入（[setPref]、[loadFromDb] 换整份缓存、跨进程刷新）都会换串，
  /// 串一变就重新解码——判据就是数据本身，不存在漏掉失效通知而读到陈旧值的路径。
  AiProviderConfig? resolveAiFeatureProvider(AiFeature feature) {
    // 模块门在缓存之外判：缓存键只有两份原始串，翻模块开关不会换串。
    if (!moduleEnabled(ModuleId.ai)) return null;
    final String? providersRaw = _prefCache['ai_providers'];
    final String? assignmentsRaw = _prefCache['ai_feature_providers'];
    var cache = _aiResolveCache;
    if (cache == null ||
        cache.providersRaw != providersRaw ||
        cache.assignmentsRaw != assignmentsRaw) {
      cache = _aiResolveCache = (
        providersRaw: providersRaw,
        assignmentsRaw: assignmentsRaw,
        providers: aiProviders,
        assignments: storedAiFeatureAssignments,
      );
    }
    return cache.assignments.resolve(feature, cache.providers);
  }

  /// OpenSubtitles 的设备本地配置。登录 token 只存在 client 内存中，绝不写入本键。
  ///
  /// **永不返回 null**：没配置过 = [OpenSubtitlesConfig.unconfigured]（启用 + 内置
  /// 应用密钥）。BUG-2429：此前返回 null，于是「没配置过」这个特殊情况要由每个消费方
  /// 各自解释一遍，而三处解释互相矛盾——运行时装配当它「不装配」（内置密钥形同虚设），
  /// 设置页列表当它「已内置」（谎报可用），详情页草稿当它「开关关闭」（用户一碰字段
  /// 就把 enabled=false 落盘）。默认值收敛到一处，特殊情况随之消失。
  bool get usageStatsEnabled =>
      getPref('usage_stats_enabled', defaultValue: true) as bool;

  Future<void> setUsageStatsEnabled(bool value) async {
    await setPref('usage_stats_enabled', value);
    notifyListeners();
  }

  /// 安装统计的**回退随机种子**（随机 UUID v4，与下载器安装身份同一个生成器，但各自独立）。
  /// 2026-10-17 起上报的 installId 由系统机器标识派生（updates/install_attestation.dart），
  /// 只有取不到机器标识时才用它做种子（重装即变，等同旧行为）；它本身不再直接上报。
  /// 第一次读取时生成并持久化。设备本地：不进备份 / 同步 / Profile 快照，恢复备份到另一台
  /// 设备不会克隆它（两台设备被算成一个安装）。持久化键名沿用 `usage_stats_install_id`（冻结）。
  Future<String> ensureUsageStatsInstallId() async {
    final String existing = getPref(
      'usage_stats_install_id',
      defaultValue: '',
    ) as String;
    if (existing.trim().isNotEmpty) return existing.trim();
    final String created = _randomUuidV4();
    await setPref('usage_stats_install_id', created);
    return created;
  }

  /// 安装证明的工作量证明 nonce 缓存（`<installId>:<nonce>`）。只在属于 [installId] 时返回，
  /// 否则 null（installId 变了就该重算）。设备本地。
  String? usageStatsInstallPowFor(String installId) {
    final String raw =
        getPref('usage_stats_install_pow', defaultValue: '') as String;
    final String prefix = '$installId:';
    if (!raw.startsWith(prefix)) return null;
    final String nonce = raw.substring(prefix.length);
    return nonce.isEmpty ? null : nonce;
  }

  Future<void> setUsageStatsInstallPow(String installId, String nonce) async {
    await setPref('usage_stats_install_pow', '$installId:$nonce');
  }

  /// 上次心跳成功的时刻（毫秒；0 = 从没成功过）。设备本地。
  int get usageStatsLastPingAt =>
      getPref('usage_stats_last_ping_at', defaultValue: 0) as int;

  Future<void> setUsageStatsLastPingAt(int at) async {
    await setPref('usage_stats_last_ping_at', at);
  }

  /// 是否已展示过「上传/做种」首用提示（默认 false = 未展示）。首次下载时弹
  /// 一次性对话框提醒上传默认关并询问是否开启（见下载对话框），之后置真不再弹。
  bool get browseMovedNoticeHandled =>
      getPref('browse_moved_notice_handled', defaultValue: false) as bool;

  Future<void> setBrowseMovedNoticeHandled() async {
    await setPref('browse_moved_notice_handled', true);
  }

  ReaderControlLayout get readerControlLayout => ReaderControlLayout.decode(
        getPref('reader_control_layout', defaultValue: '') as String,
      );

  Future<void> setReaderControlLayout(ReaderControlLayout layout) async {
    await setPref('reader_control_layout', layout.encode());
    notifyListeners();
  }

  /// 窄窗（手机竖屏）的按钮布局（2026-10：手机与桌面分别可配）。持久化键
  /// `reader_control_layout_compact`。兼容存量：没存过窄窗布局、但存过（宽窗）
  /// 布局的用户——此前一份布局两端共用——继续沿用那份自定义，不丢；两份都没有
  /// 才落窄窗出厂布局 [ReaderControlLayout.compactDefaults]。
  ReaderControlLayout get readerCompactControlLayout {
    final String compact =
        getPref('reader_control_layout_compact', defaultValue: '') as String;
    if (compact.trim().isNotEmpty) {
      return ReaderControlLayout.decode(
        compact,
        fallback: ReaderControlLayout.compactDefaults,
      );
    }
    final String wide =
        getPref('reader_control_layout', defaultValue: '') as String;
    if (wide.trim().isNotEmpty) return ReaderControlLayout.decode(wide);
    return ReaderControlLayout.compactDefaults;
  }

  Future<void> setReaderCompactControlLayout(ReaderControlLayout layout) async {
    await setPref('reader_control_layout_compact', layout.encode());
    notifyListeners();
  }

  /// 无痕阅读（默认 false = 记录 History）。读取方在**每次落库时**现读本值，
  /// 因此在设置里切换后立即生效，不需要重启阅读器。
  bool get incognitoReading =>
      getPref(kIncognitoReadingPrefKey, defaultValue: false) as bool;

  Future<void> setIncognitoReading(bool value) async {
    await setPref(kIncognitoReadingPrefKey, value);
  }

  /// 阅读器工具栏样式（2026-10，M3 Expressive toolbars）：`floating`（默认：
  /// 悬浮胶囊 + 底部悬浮工具栏，正文满屏）/ `docked`（贴边整宽实体条，旧形态）。
  /// 未知值按默认。
  String get readerToolbarStyle {
    final String v =
        getPref('reader_toolbar_style', defaultValue: 'floating') as String;
    return v == 'docked' ? 'docked' : 'floating';
  }

  Future<void> setReaderToolbarStyle(String style) async {
    await setPref('reader_toolbar_style', style == 'docked' ? 'docked' : 'floating');
    notifyListeners();
  }

  /// 「工具栏样式强制悬浮」一次性迁移的已跑标记（bool）。本键不随 Profile 走
  /// （`ProfileKeys` 排除）：描述的是本安装是否迁过，进快照的话切到老 Profile
  /// 会把它删掉、迁移重跑，用户事后手动选的贴边又被改回悬浮。
  static const String readerToolbarStyleFloatingMigratedKey =
      'reader_toolbar_style_floating_migrated';

  /// 启动时（`AppModel.initialise()`）跑一次：所有者 2026-10-06「工具栏样式默认
  /// 悬浮，老用户更新也强制先悬浮」。把 live 偏好**和每个 Profile 快照里**的
  /// `reader_toolbar_style` 一起改成 `floating`——只改 live 的话，切一次 Profile
  /// 快照就把旧的 `docked` 带回来。标记与新值同一次 [setPrefs] 落盘；此后用户
  /// 再手动选贴边，标记已在，不会被改回。快照先改、标记后写：中途中断下次重跑
  /// 也只是把同一个值再写一遍。
  Future<void> settleReaderToolbarStyleFloating() async {
    if (getPref(readerToolbarStyleFloatingMigratedKey, defaultValue: false) ==
        true) {
      return;
    }
    await _db.customStatement(
      'UPDATE profile_settings SET value = ? WHERE category = ? AND key = ?',
      <Object>[
        PrefCodec.encode('floating'),
        kProfileSettingCategoryPref,
        'reader_toolbar_style',
      ],
    );
    await setPrefs(<String, dynamic>{
      'reader_toolbar_style': 'floating',
      readerToolbarStyleFloatingMigratedKey: true,
    });
  }

  /// 「漫画新章提醒默认关闭」一次性重置的已跑标记（bool）。本键不随 Profile 走
  /// （`ProfileKeys` 排除）：描述的是本安装是否迁过；进快照的话切到老 Profile 会
  /// 把它删掉、迁移重跑，用户此后手动开启的提醒又被改回关闭。
  static const String updatesNotifyMangaChapterDefaultOffMigratedKey =
      'updates_notify_manga_chapter_default_off_migrated';

  /// 启动时（`AppModel.initialise()`）跑一次：2026-11 用户要求「漫画新章提醒」
  /// 默认关闭，并且升级后把已有安装保存的开关值强制重置为关闭一次。
  ///
  /// 与 [settleReaderToolbarStyleFloating] 同一形状：live 偏好**和每个 Profile
  /// 快照里**的值一起改成 `false`——只改 live 的话，切一次 Profile 快照就把旧的
  /// `true` 带回来。扩展更新提醒的已存值不动。标记与新值同一次 [setPrefs] 落盘；
  /// 此后用户再手动开启，标记已在，不会被改回。快照先改、标记后写：中途中断下次
  /// 重跑也只是把同一个值再写一遍。
  Future<void> settleUpdatesNotifyMangaChapterDefaultOff() async {
    if (getPref(
          updatesNotifyMangaChapterDefaultOffMigratedKey,
          defaultValue: false,
        ) ==
        true) {
      return;
    }
    final String key = UpdateFeedKind.mangaChapter.enabledPrefKey;
    await _db.customStatement(
      'UPDATE profile_settings SET value = ? WHERE category = ? AND key = ?',
      <Object>[
        PrefCodec.encode(false),
        kProfileSettingCategoryPref,
        key,
      ],
    );
    await setPrefs(<String, dynamic>{
      key: false,
      updatesNotifyMangaChapterDefaultOffMigratedKey: true,
    });
  }

  /// 视频「快捷键 1..4」自定义动作按钮的绑定（用户请求）：槽位序号 → 视频动作。
  ///
  /// 与 [videoControlLayout] **分开存**：布局管「按钮在哪个槽位、显不显示」，本表管
  /// 「按钮按下去干什么」。两者正交——用户可以只改位置不改动作，反之亦然；混进同一个
  /// JSON 只会让那个已经在扛 v1→v2→v3 迁移的 payload 再多一层版本。
  /// 空串 = 一个都没绑（[VideoCustomActionBindings.empty]）。此时按钮仍显示在控制条上，
  /// 点它就地弹动作选择器——空槽位是配置入口，不是死按钮。
  List<WebKnowledgeSite> get aiWebKnowledgeCustomSites =>
      parseWebKnowledgeCustomSites(
        getPref('ai_web_knowledge_custom_sites', defaultValue: null) as String?,
      );

  Future<void> setAiWebKnowledgeCustomSites(
    List<WebKnowledgeSite> sites,
  ) async {
    await setPref(
      'ai_web_knowledge_custom_sites',
      encodeWebKnowledgeCustomSites(sites),
    );
    notifyListeners();
  }

  /// 启用的站点 id（内置 + 自定义）。
  ///
  /// 落盘记的是**关掉了哪些**（`ai_web_knowledge_disabled_sites`），不是开了哪些：
  /// 记「开了哪些」时，以后新增的内置站对任何动过开关的用户都默认关；旧版客户端
  /// 经同步写回它认识的 id 子集，还会把新站一起关掉。记「关了哪些」，新站默认开、
  /// 旧客户端不认识的 id 也不会被它抹掉。
  ///
  /// 迁移：还没有新键时读旧键 `ai_web_knowledge_sources`（只可能含三个维基 id）——
  /// 旧键里没列的维基视为关掉，其余一律开。
  Set<String> get aiWebKnowledgeEnabledSiteIds {
    final Set<String> all = <String>{
      for (final WebKnowledgeSite site in kBuiltinWebKnowledgeSites) site.id,
      for (final WebKnowledgeSite site in aiWebKnowledgeCustomSites) site.id,
    };
    final Set<String>? disabled = parseWebKnowledgeEnabledIds(
      getPref('ai_web_knowledge_disabled_sites', defaultValue: null)
          as String?,
    );
    if (disabled != null) return all.difference(disabled);
    final Set<String>? legacyEnabled = parseWebKnowledgeEnabledIds(
      getPref('ai_web_knowledge_sources', defaultValue: null) as String?,
    );
    if (legacyEnabled == null) return all;
    return all.difference(
      kLegacyWebKnowledgeSiteIds.difference(legacyEnabled),
    );
  }

  Future<void> setAiWebKnowledgeEnabledSiteIds(Set<String> ids) async {
    // 按「内置顺序 + 自定义顺序」写出关掉的那些，同一组选择写出的值恒相同；已删掉
    // 的站点 id 顺手清掉，不在偏好里越攒越多。
    final List<String> disabled = <String>[
      for (final WebKnowledgeSite site in <WebKnowledgeSite>[
        ...kBuiltinWebKnowledgeSites,
        ...aiWebKnowledgeCustomSites,
      ])
        if (!ids.contains(site.id)) site.id,
    ];
    await setPref('ai_web_knowledge_disabled_sites', disabled.join(','));
    notifyListeners();
  }

  /// 实际要查的站点：启用的内置站（内置顺序）+ 启用的自定义站（添加顺序）。
  @override
  List<WebKnowledgeSite> get aiWebKnowledgeSites {
    final Set<String> enabled = aiWebKnowledgeEnabledSiteIds;
    return <WebKnowledgeSite>[
      for (final WebKnowledgeSite site in <WebKnowledgeSite>[
        ...kBuiltinWebKnowledgeSites,
        ...aiWebKnowledgeCustomSites,
      ])
        if (enabled.contains(site.id)) site,
    ];
  }

  /// 刮削完成后，自动为**仍缺字幕**的视频补一条在线字幕。默认开。
  ///
  /// 为什么默认开：下载流水线的字幕阶段本来就默认 `bestEffort`（自动配字幕一直
  /// 是开着的），只是从来没有名字、没有开关、失败只落在任务行一句英文里，用户
  /// 无从知道这个能力存在。给它一个名字放进设置页（可被设置搜索命中），是这个
  /// 能力第一次变得可发现。
  ///
  /// 只在配好了在线字幕来源（Jimaku key / OpenSubtitles）时才有任何动作；
  /// 且**绝不覆盖**任何已有字幕。
  // ── tags & card export ───────────────────────────────────────────────

  String get savedTags => getPref('saved_tags', defaultValue: '') as String;

  void setSavedTags(String value) async {
    await setPref('saved_tags', value);
  }

  bool get autoAddBookNameToTags =>
      getPref('auto_add_book_name_to_tags', defaultValue: true) as bool;

  void toggleAutoAddBookNameToTags() async {
    await setPref('auto_add_book_name_to_tags', !autoAddBookNameToTags);
    notifyListeners();
  }

  /// 小说阅读器制卡时是否给卡片追加「制卡所在字符数」标签（`chars_12345`，全书绝对
  /// 学习字数位置，countStudyChars 口径）。默认关（2026-09-26 用户要求砍掉这个
  /// 默认标签：每张卡多一个无意义的数字 tag）；需要的人在 Anki 设置里自己打开。
  bool get autoAddCharPositionToTags =>
      getPref('auto_add_char_position_to_tags', defaultValue: false) as bool;

  void toggleAutoAddCharPositionToTags() async {
    await setPref('auto_add_char_position_to_tags', !autoAddCharPositionToTags);
    notifyListeners();
  }

  // TODO-1650 制卡图片/GIF 清晰度档（0..3，见 [MiningMediaCompression.imageTiers]）。
  // 替代旧的单一「压缩」开关。未显式设过时从旧 `compress_mining_media` 布尔迁移：
  // 开(默认)→标准档 1（= TODO-646 现状，零行为破坏）；关→高清档 2。读写都夹到 0..3，
  // 防止损坏/越界值进到底层编码。
  int get miningImageQuality {
    final int? explicit =
        getPref('mining_image_quality', defaultValue: null) as int?;
    if (explicit != null) {
      return explicit.clamp(0, MiningMediaCompression.imageTierCount - 1);
    }
    final bool oldCompress =
        getPref('compress_mining_media', defaultValue: true) as bool;
    return oldCompress
        ? MiningMediaCompression.defaultImageTier
        : 2; // 旧「关闭压缩」= 高保真档 = 图片高清档 2
  }

  void setMiningImageQuality(int tier) async {
    await setPref('mining_image_quality',
        tier.clamp(0, MiningMediaCompression.imageTierCount - 1));
    notifyListeners();
  }

  // TODO-1650 制卡音频质量档（0..2，见 [MiningMediaCompression.audioTiers]）。未显式设过时
  // 从旧「压缩」开关迁移：开(默认)→标准档 0（单声道 64k，现状）；关→高音质档 1（立体声
  // 128k）。Android 句子音频本就无损 re-mux，不受此档影响。
  int get miningAudioQuality {
    final int? explicit =
        getPref('mining_audio_quality', defaultValue: null) as int?;
    if (explicit != null) {
      return explicit.clamp(0, MiningMediaCompression.audioTierCount - 1);
    }
    final bool oldCompress =
        getPref('compress_mining_media', defaultValue: true) as bool;
    return oldCompress
        ? MiningMediaCompression.defaultAudioTier
        : 1; // 旧「关闭压缩」= 高保真档 = 音频高音质档 1
  }

  void setMiningAudioQuality(int tier) async {
    await setPref('mining_audio_quality',
        tier.clamp(0, MiningMediaCompression.audioTierCount - 1));
    notifyListeners();
  }

  // 互联「制卡到服务端」开关：开启后所有 app 内制卡（查词/阅读器/视频）不落本地 Anki，
  // 而是把制卡内容 + 全部媒体字节转发给已配对主机，用主机的 Anki 后端 + 配置落卡。
  // 默认 false=本地制卡（现状零破坏）。目标主机复用互联客户端（远程查词的同一配对目标）。
  bool get mineToServer =>
      getPref('mine_to_server', defaultValue: false) as bool;

  Future<void> setMineToServer(bool value) async {
    await setPref('mine_to_server', value);
    notifyListeners();
  }

  // 复习模块（SRS）的「挖词目标」：'anki' / 'srs'（见 SrsMiningTarget；存量 'both'
  // 读成 'anki'）。只有复习模块开着时才被读取；模块关着时制卡链路不看它。
  //
  // 没设过时取本安装的出厂默认 [srsMiningTargetInstallDefaultKey]（所有者 2026-10-16：
  // 新装默认 Fushi 复习、老用户继续发 Anki，由 [settleSrsMiningTargetInstallDefault]
  // 一次性判定）。判定还没跑过（标记缺失：升级后主进程尚未启动过的 :popup 进程、
  // 刚整层恢复了一份老备份）一律按 'anki'——宁可照旧发 Anki，也不把老用户的卡误送进
  // 复习。
  String get srsMiningTarget {
    final Object? stored = getPref(srsMiningTargetKey, defaultValue: null);
    if (stored is String) return stored;
    final Object? installDefault = getPref(
      srsMiningTargetInstallDefaultKey,
      defaultValue: null,
    );
    return installDefault is String ? installDefault : 'anki';
  }

  Future<void> setSrsMiningTarget(String wire) async {
    await setPref(srsMiningTargetKey, wire);
    notifyListeners();
  }

  // 复习页评分栏只留「重来 / 良好」（对齐 AnkiDroid hideHardAndEasy）。默认 false。
  bool get srsReviewHideHardEasy =>
      getPref('srs_review_hide_hard_easy', defaultValue: false) as bool;

  Future<void> setSrsReviewHideHardEasy(bool value) async {
    await setPref('srs_review_hide_hard_easy', value);
    notifyListeners();
  }

  // 复习页卡面缩放倍率。默认 1.0。
  double get srsReviewZoom =>
      (getPref('srs_review_zoom', defaultValue: 1.0) as num).toDouble();

  Future<void> setSrsReviewZoom(double value) async {
    await setPref('srs_review_zoom', value);
    notifyListeners();
  }

  /// 复习自动备份开关（默认开）。设备本地。
  static const String srsBackupAutoKey = 'srs_backup_auto';

  /// 复习自动备份的间隔与保留份数（JSON，缺省 = Anki 默认）。设备本地。
  static const String srsBackupLimitsKey = 'srs_backup_limits';

  bool get srsBackupAuto =>
      getPref(srsBackupAutoKey, defaultValue: true) as bool;

  Future<void> setSrsBackupAuto(bool value) async {
    await setPref(srsBackupAutoKey, value);
    notifyListeners();
  }

  SrsBackupLimits get srsBackupLimits =>
      srsBackupLimitsFromJson(getPref(srsBackupLimitsKey, defaultValue: ''));

  Future<void> setSrsBackupLimits(SrsBackupLimits value) async {
    await setPref(srsBackupLimitsKey, srsBackupLimitsToJson(value));
    notifyListeners();
  }

  static const String srsMiningTargetKey = 'srs_mining_target';

  /// 本安装「挖词目标」的出厂默认（'anki' / 'srs'），兼一次性判定的已跑标记。
  ///
  /// 设备本地（`SyncRepository.installScopedPrefKeys`）：它描述的是**本安装**属于老用户
  /// 还是新用户，不进 Profile 快照 / 分享。
  /// 用它而不是把判定结果写进 `srs_mining_target` 本身，是因为 Profile 快照里**没有**
  /// 某键时，切 Profile 会把 live 键删掉（`ProfileRepository.applyProfile` 的 prune）——
  /// 老用户切到一份 SRS 之前建的快照、或导入一份旧的 Profile 分享，键一删就回落默认；
  /// 回落值取这里，老用户落回 'anki'，新用户落回 'srs'，不会被新默认误切。
  ///
  /// 也不随备份 / 推荐包走：导出时剔除（维护者用装了新版的机器打推荐包会带上 'anki'，
  /// 新用户一导入就会被误判成老 Anki 用户）。导入设置的恢复会把它清掉（外来值、本机
  /// 旧值都不留），下次启动按恢复后的数据重判——新装后恢复老 Anki 用户的完整备份会
  /// 判回 'anki'，引导里导入推荐包仍只认制卡数据信号；显式设过的 [srsMiningTargetKey]
  /// 随设置恢复、不受影响。判定前读取按 'anki'（见 [srsMiningTarget]）。
  static const String srsMiningTargetInstallDefaultKey =
      'srs_mining_target_install_default';

  /// 启动时（`AppModel.initialise()`）跑一次：判定本安装是老用户还是新用户，定下
  /// 「挖词目标」与复习模块的出厂默认（所有者 2026-10-16「默认就是 fushi srs」+
  /// 「老用户继续发 Anki、不提醒」）。
  ///
  /// 老用户信号（任一即是）：
  /// - `first_time_setup` / `onboarding_completed` 已落过盘——首页首帧会写前者，向导
  ///   结束会写后者；全新安装第一次走到这里时两者都不存在（本方法先于首页跑）。
  /// - `last_selected_deck` / `last_selected_model` 已落过盘（选过 Anki 牌组 / 笔记类型）。
  /// - 有制卡历史（`mined_sentences`）或待发 Anki 的卡（`pending_mine_queue`）。
  ///
  /// [freshOnboardingPackImport]：本安装是在新手引导里导入了推荐包后重启上来的（推荐包
  /// 是一份含设置类目的备份，导入会把 `preferences` 整层换成包里那份，前两类信号随包
  /// 而来、并不代表这台设备的用户用过 Anki）。此时只认制卡数据这一类信号。
  ///
  /// 老用户：出厂默认记 'anki'；复习模块的开关若从没设过，显式写成关——升级上来**完全
  /// 静默**，不出新 tab、不弹任何提示，只有自己去设置里打开才看得到 Fushi 复习。
  /// 新用户：出厂默认记 'srs'，模块按 [ModuleId.defaultEnabled]（开）。
  ///
  /// 例外：`srs_mining_target` 显式为 'srs' 时按「在用 Fushi 复习」处理，模块从没设过就
  /// 写成开（老用户也一样）。
  ///
  /// 已显式选过的 `srs_mining_target` 与模块开关一概不改。标记已在则直接返回（幂等）；
  /// 标记与模块开关同一次 [setPrefs] 落盘。
  Future<void> settleSrsMiningTargetInstallDefault({
    bool freshOnboardingPackImport = false,
  }) async {
    if (getPref(srsMiningTargetInstallDefaultKey, defaultValue: null) != null) {
      return;
    }
    bool stored(String key) => getPref(key, defaultValue: null) != null;
    final bool prefSignal = stored('first_time_setup') ||
        stored('onboarding_completed') ||
        stored('last_selected_deck') ||
        stored('last_selected_model');
    final bool existingUser = (!freshOnboardingPackImport && prefSignal) ||
        await _hasAnkiMiningData();
    // 模块开关经与 [setModuleEnabled] 同一组按 [ModuleId] 的存储原语写入：这里是存储层
    // 的一次性落盘，只问「落没落过盘」、不读用户意愿；门控一律问模块可见性。
    final bool moduleUnset = !_moduleStored(ModuleId.srs);
    // 显式选过「发往 Fushi 复习」= 在用复习（常见于恢复一份老用户备份：挖词目标随设置
    // 恢复，而模块开关是设备本地键、新设备上没设过）。此时不论判成老用户与否都不能关
    // 模块——关着就不读挖词目标，卡实际仍发 Anki；模块没设过就显式写成开。
    final bool explicitSrs =
        getPref(srsMiningTargetKey, defaultValue: null) == 'srs';
    await setPrefs(<String, dynamic>{
      srsMiningTargetInstallDefaultKey: existingUser ? 'anki' : 'srs',
      if (moduleUnset && explicitSrs)
        ..._moduleEntry(ModuleId.srs, true)
      else if (moduleUnset && existingUser)
        ..._moduleEntry(ModuleId.srs, false),
    });
  }

  /// 模块开关是否显式落过盘（没落过 = 读出厂默认 / 判定规则）。
  bool _moduleStored(ModuleId module) =>
      getPref(module.prefKey, defaultValue: null) != null;

  /// 模块开关的一条待写记录（与 [setModuleEnabled] 同一个键），供批量 [setPrefs]。
  Map<String, dynamic> _moduleEntry(ModuleId module, bool value) =>
      <String, dynamic>{module.prefKey: value};

  Future<bool> _hasAnkiMiningData() async {
    return (await _db
            .customSelect(
              'SELECT EXISTS(SELECT 1 FROM mined_sentences) '
              'OR EXISTS(SELECT 1 FROM pending_mine_queue) AS used',
            )
            .getSingle())
        .read<bool>('used');
  }


  // 首页 dashboard 面板显示档（JSON map，见 models/home_dashboard_panel.dart）。
  // 空串 = 全部面板按各自的默认判据（auto）。
  String get homeDashboardPanels =>
      getPref('home_dashboard_panels', defaultValue: '') as String;

  Future<void> setHomeDashboardPanels(String json) async {
    await setPref('home_dashboard_panels', json);
    notifyListeners();
  }

  // 复习卡面外观（JSON，见 SrsCardAppearance）。空串 = 模板默认外观。
  String get srsCardAppearance =>
      getPref('srs_card_appearance', defaultValue: '') as String;

  Future<void> setSrsCardAppearance(String json) async {
    await setPref('srs_card_appearance', json);
    notifyListeners();
  }

  // 挖词目标 = Fushi 复习时，卡落进哪个 SRS 牌组 / 用哪个笔记类型（SRS 实体 id；
  // 空串 = 默认牌组 / 内置 Fushi 卡片）。id 自带 profileUid，随 Profile 快照走。
  String get srsMiningDeckId =>
      getPref('srs_mining_deck_id', defaultValue: '') as String;

  Future<void> setSrsMiningDeckId(String id) async {
    await setPref('srs_mining_deck_id', id);
    notifyListeners();
  }

  String get srsMiningNoteTypeId =>
      getPref('srs_mining_note_type_id', defaultValue: '') as String;

  Future<void> setSrsMiningNoteTypeId(String id) async {
    await setPref('srs_mining_note_type_id', id);
    notifyListeners();
  }

  // 非 Lapis 笔记类型的字段映射：JSON `{noteTypeId: {fieldId: 模板}}`（模板与 Anki
  // 字段映射同一套 handlebar）。坏 JSON / 形状不对的项当没映射过。
  Map<String, Map<String, String>> get srsMiningFieldMappings {
    final String raw =
        getPref('srs_mining_field_mappings', defaultValue: '') as String;
    if (raw.isEmpty) return const <String, Map<String, String>>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, Map<String, String>>{};
      return <String, Map<String, String>>{
        for (final MapEntry<Object?, Object?> e in decoded.entries)
          if (e.key is String && e.value is Map)
            e.key! as String: <String, String>{
              for (final MapEntry<Object?, Object?> f
                  in (e.value! as Map).entries)
                if (f.key is String && f.value is String)
                  f.key! as String: f.value! as String,
            },
      };
    } on FormatException {
      return const <String, Map<String, String>>{};
    }
  }

  Future<void> setSrsMiningFieldMappings(
    Map<String, Map<String, String>> mappings,
  ) async {
    await setPref('srs_mining_field_mappings', jsonEncode(mappings));
    notifyListeners();
  }

  // 制卡句子音频的头/尾 padding（毫秒）。对齐 asbplayer 的 audio padding：字幕 cue 的
  // 时间窗通常比实际发声短，尾音/助词/呼吸直接被硬切。视频字幕与有声书两条制卡链共用
  // 这一对值（同一个人听同一种语言，句首/句尾余量的需求不随媒体种类变），裁剪时都走
  // [padSentenceRange] 夹相邻 cue 边界，所以填大了也不会把下一句混进来。
  // 默认值 = 原有声书硬编码常量（头 120 / 尾 200，[kMiningHeadPadMs]/[kMiningTailPadMs]），
  // 有声书用户行为零变化；视频链此前完全没 padding，默认即获得余量。
  int get miningAudioHeadPadMs =>
      (getPref('mining_audio_head_pad_ms', defaultValue: kMiningHeadPadMs)
              as int)
          .clamp(0, kMiningPadMaxMs);

  void setMiningAudioHeadPadMs(int ms) async {
    await setPref('mining_audio_head_pad_ms', ms.clamp(0, kMiningPadMaxMs));
    notifyListeners();
  }

  int get miningAudioTailPadMs =>
      (getPref('mining_audio_tail_pad_ms', defaultValue: kMiningTailPadMs)
              as int)
          .clamp(0, kMiningPadMaxMs);

  void setMiningAudioTailPadMs(int ms) async {
    await setPref('mining_audio_tail_pad_ms', ms.clamp(0, kMiningPadMaxMs));
    notifyListeners();
  }

  /// 有声书倍速制卡：句子音频是否跟随当前播放倍速（变速不变调）。默认开——用户开着
  /// 1.5× 听书，卡片里的句子音频就是 1.5× 的，与阅读时听到的一致；关掉则一律裁原速。
  /// 只对小说有声书制卡链生效（视频链没有「播放倍速」这个制卡语境，不读它）。
  bool get miningAudioFollowPlaybackSpeed =>
      getPref('mining_audio_follow_playback_speed', defaultValue: true)
          as bool;

  void toggleMiningAudioFollowPlaybackSpeed() async {
    await setPref(
      'mining_audio_follow_playback_speed',
      !miningAudioFollowPlaybackSpeed,
    );
    notifyListeners();
  }

  bool get deduplicatePitchAccents =>
      getPref('deduplicate_pitch_accents', defaultValue: true) as bool;

  void toggleDeduplicatePitchAccents() async {
    await setPref('deduplicate_pitch_accents', !deduplicatePitchAccents);
    notifyListeners();
  }

  bool get harmonicFrequency =>
      getPref('harmonic_frequency', defaultValue: true) as bool;

  void toggleHarmonicFrequency() async {
    await setPref('harmonic_frequency', !harmonicFrequency);
    notifyListeners();
  }

  bool get showExpressionTags =>
      getPref('show_expression_tags', defaultValue: false) as bool;

  void toggleShowExpressionTags() async {
    await setPref('show_expression_tags', !showExpressionTags);
    notifyListeners();
  }

  bool get collapseDictionaries =>
      getPref('collapse_dictionaries', defaultValue: true) as bool;

  void toggleCollapseDictionaries() async {
    await setPref('collapse_dictionaries', !collapseDictionaries);
    notifyListeners();
  }

  // 对齐 Hoshi Reader Android 的 "Compact Glossaries"：释义列表由每条一行改成
  // inline + ` | ` 分隔的紧凑排版（popup.js createDictionaryBlock 的 compactCss）。
  // 渲染器早就支持 window.compactGlossaries，只是从来没有偏好写入它。默认 false =
  // 保持现状（Android 那边默认 true，但改默认会让所有存量用户的弹窗观感突变）。
  bool get compactGlossaries =>
      getPref('popup_compact_glossaries', defaultValue: false) as bool;

  void toggleCompactGlossaries() async {
    await setPref('popup_compact_glossaries', !compactGlossaries);
    notifyListeners();
  }

  // 词典样式统一：查词弹窗把导入词典自带的颜色（styles.css / 结构化内容 inline
  // style）按语义重映射到当前 ColorScheme（M3E）。默认 false（用户 10-09：统一着色会盖掉
  // 词典自带配色，改为显式开启；存量用户写过的偏好值原样保留）；关掉 = 保留词典原样式。
  // popup.js 读 window.__fushiDictUnifiedStyle。
  bool get dictionaryUnifiedStyle =>
      getPref('popup_dictionary_unified_style', defaultValue: false) as bool;

  void toggleDictionaryUnifiedStyle() async {
    await setPref('popup_dictionary_unified_style', !dictionaryUnifiedStyle);
    notifyListeners();
  }

  // ── custom CSS ───────────────────────────────────────────────────────

  Map<String, String> get customDictCSS {
    final raw = getPref('custom_dict_css', defaultValue: '') as String;
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e, stack) {
      ErrorLogService.instance
          .log('PreferencesRepository.customDictCSS.decode', e, stack);
    }
    return {};
  }

  String getCustomCSSForDict(String dictName) => customDictCSS[dictName] ?? '';

  Future<void> setCustomCSSForDict(String dictName, String css) async {
    final map = customDictCSS;
    if (css.isEmpty) {
      map.remove(dictName);
    } else {
      map[dictName] = css;
    }
    await setPref('custom_dict_css', jsonEncode(map));
  }

  String get globalDictCSS =>
      getPref('global_dict_css', defaultValue: '') as String;

  Future<void> setGlobalDictCSS(String css) async {
    await setPref('global_dict_css', css);
  }

  // ── 可视化样式规则（结构化真相源 + CSS 编译产物缓存）────────────────
  //
  // 与上面的手写 CSS **分开存**：可视化面板改规则表，手写框改 CSS 文本，注入时
  // 拼接。共用一份文本就得反向解析手写 CSS 才能回填面板，往返编辑必坏。

  String get dictStyleRulesRaw =>
      getPref(dictStyleRulesPrefKey, defaultValue: '') as String;

  Future<void> setDictStyleRulesRaw(String raw) async {
    await setPref(dictStyleRulesPrefKey, raw);
  }

  /// 规则表的 CSS 编译产物缓存。
  ///
  /// 供跑不了 Dart 编译器的消费方直接读（Android 独立弹窗 Activity 直连 prefs
  /// 表）。Dart 侧一律走 `AppModel.effective*DictCSS` 现算，不读这个缓存——
  /// 冗余数据只由同一个编译函数产出：`AppModel.saveDictStyleRules`（保存时）与
  /// `AppModel.refreshCompiledDictStyleCssCache`（启动时按当前编译器对齐），一类读者。
  String get dictStyleRulesCss =>
      getPref(dictStyleRulesCssPrefKey, defaultValue: '') as String;

  Future<void> setDictStyleRulesCss(String css) async {
    await setPref(dictStyleRulesCssPrefKey, css);
  }

  // ── audio sources ────────────────────────────────────────────────────

  /// 已退役的内置远端音频源 URL。曾经随新装默认写入用户的音频源列表；2026-09-13
  /// 用户拍板不再依赖任何第三方网络音频库，内置默认远端源整个删掉。老用户列表里
  /// 残留的这些 URL 在读取时剔除——只删默认值而不清持久化，就等于只对新装生效。
  /// 消费方一律经 [audioSourceConfigs] 读，这里是唯一咽喉。
  static const Set<String> retiredAudioSourceUrls = <String>{
    'https://fushi-reader.manhhaoo-do.workers.dev/?term={term}&reading={reading}',
  };

  /// Anki 本地音频服务器（local-audio-yomichan，默认端口 5050）的内置预设 URL。
  /// 用户装了该服务器后，在「管理音频来源」里打开开关即用；默认关闭——本地第三方
  /// 服务不经用户同意不参与查词发音（与 fushiRemote 同策）。
  /// 由 [_withDefaultAudioSources] 对所有用户「缺则补」为一条 disabled 源。
  static const String ankiLocalAudioUrl =
      'http://localhost:5050/?term={term}&reading={reading}';

  /// legacy `audio_sources`（只存已启用的远端 URL）。无内置默认远端源，未写过即空。
  List<String> get audioSources {
    final result = getPref('audio_sources', defaultValue: const <String>[]);
    if (result is List<String>) return result;
    if (result is List) return result.cast<String>();
    return <String>[];
  }

  List<AudioSourceConfig> get audioSourceConfigs {
    final result = getPref('audio_source_configs', defaultValue: null);
    if (result is List) {
      final configs = result
          .whereType<Map>()
          .map((Map json) => AudioSourceConfig.fromJson(
                Map<String, dynamic>.from(json),
              ))
          .where((AudioSourceConfig source) =>
              source.kind != AudioSourceKind.remoteAudio ||
              (source.url?.isNotEmpty ?? false))
          .toList();
      if (configs.isNotEmpty) return _withDefaultAudioSources(configs);
    }
    // 没写过 typed config 就按 legacy audio_sources 装配（fromLegacyUrls 默认
    // enabled，保留老用户已启用的 URL）；纯新装两个 pref 都空，走同一条路。
    return _withDefaultAudioSources(
      AudioSourceConfig.fromLegacyUrls(audioSources),
    );
  }

  List<AudioSourceConfig> _withDefaultAudioSources(
    List<AudioSourceConfig> sources,
  ) {
    // 已退役的内置远端源（见 [retiredAudioSourceUrls]）从老用户列表里剔除。
    final List<AudioSourceConfig> result = <AudioSourceConfig>[
      for (final AudioSourceConfig source in sources)
        if (source.kind != AudioSourceKind.remoteAudio ||
            !retiredAudioSourceUrls.contains(source.url))
          source,
    ];

    // fushiRemote 恒在列首（缺则补），历史行为不变。
    final bool hasFushiRemote = result.any(
      (AudioSourceConfig source) => source.kind == AudioSourceKind.fushiRemote,
    );
    if (!hasFushiRemote) {
      result.insert(0, AudioSourceConfig.fushiRemote());
    }

    // Anki 本地音频服务器（5050）内置预设：对所有用户「缺则补」为一条 disabled 源，
    // 追加在列尾。用户装了服务器打开开关即用；删掉后下次读取会 disabled 重生，与
    // fushiRemote 恒补策略一致（TODO-083 范式）。
    final bool hasAnki = result.any((AudioSourceConfig source) =>
        source.kind == AudioSourceKind.remoteAudio &&
        source.url == ankiLocalAudioUrl);
    if (!hasAnki) {
      result.add(AudioSourceConfig.remoteAudio(
        url: ankiLocalAudioUrl,
        label: 'Anki',
        enabled: false,
      ));
    }

    return result;
  }

  void setAudioSources(List<String> sources) async {
    await setPref('audio_sources', sources);
    notifyListeners();
  }

  Future<void> setAudioSourceConfigs(List<AudioSourceConfig> sources) async {
    await setPref(
      'audio_source_configs',
      sources.map((AudioSourceConfig source) => source.toJson()).toList(),
    );
    await setPref(
      'audio_sources',
      sources
          .where((AudioSourceConfig source) =>
              source.kind == AudioSourceKind.remoteAudio && source.enabled)
          .map((AudioSourceConfig source) => source.url ?? '')
          .where((String url) => url.isNotEmpty)
          .toList(),
    );
    notifyListeners();
  }

  // ── UI visibility ────────────────────────────────────────────────────

  bool get showMediaNotification =>
      getPref('show_media_notification', defaultValue: true) as bool;

  void toggleShowMediaNotification() async {
    await setPref('show_media_notification', !showMediaNotification);
    notifyListeners();
  }

  Future<void> setShowMediaNotification(bool value) async {
    await setPref('show_media_notification', value);
    notifyListeners();
  }

  bool get showFloatingLyric =>
      getPref('show_floating_lyric', defaultValue: false) as bool;

  Future<void> setShowFloatingLyric(bool value) async {
    await setPref('show_floating_lyric', value);
    notifyListeners();
  }

  double get floatingLyricFontSize =>
      getPref('floating_lyric_font_size', defaultValue: 20.0) as double;

  Future<void> setFloatingLyricFontSize(double value) async {
    await setPref('floating_lyric_font_size', value.clamp(8, 64).toDouble());
    notifyListeners();
  }

  // BUG-1095: galgame Hook 台词浮窗字号（逻辑 px）。以前这个值没有真值来源——native
  // 按浮窗高度对基准 30 做 0.9~2.5 倍缩放，于是「把浮窗拖高」和「把字放大」是同一个
  // 手势，用户「放不下想拖高」永远拖不出更多行。现在窗高只管窗高，字号是这条独立
  // 偏好。默认 30 == 旧基准在默认窗高（140dip）下的实际字号，没拖过窗的用户观感不变。
  static const double galHookTextFontSizeMin = 12.0;
  static const double galHookTextFontSizeMax = 72.0;
  static const double galHookTextFontSizeDefault = 30.0;
  static const double galHookTextLetterSpacingMin = -2.0;
  static const double galHookTextLetterSpacingMax = 12.0;
  static const double galHookTextLetterSpacingDefault = 0.0;
  static const double galHookTextLineHeightMin = 0.8;
  static const double galHookTextLineHeightMax = 2.0;
  static const double galHookTextLineHeightDefault = 1.0;
  static const double galHookTextOutlineWidthMin = 0.0;
  static const double galHookTextOutlineWidthMax = 6.0;
  static const double galHookTextOutlineWidthDefault = 1.6;
  static const double galHookTextPaddingMin = 0.0;
  static const double galHookTextPaddingMax = 80.0;
  static const double galHookTextPaddingDefault = 20.0;
  static const double galHookTextCornerRadiusMin = 0.0;
  static const double galHookTextCornerRadiusMax = 40.0;
  static const double galHookTextCornerRadiusDefault = 14.0;
  static const int galHookTextColorDefault = 0xFFFFFFFF;
  static const int galHookTextBackgroundColorDefault = 0xFF000000;
  static const int galHookTextOutlineColorDefault = 0xE0000000;
  static const double galHookTextBackgroundOpacityDefault = 0.0;

  double _galHookDouble(
    String key, {
    required double fallback,
    required double min,
    required double max,
  }) {
    final Object? stored = getPref(key, defaultValue: fallback);
    final double value = stored is num ? stored.toDouble() : fallback;
    return value.clamp(min, max);
  }

  int _galHookColor(String key, int fallback) {
    final Object? stored = getPref(key, defaultValue: fallback);
    return ((stored is num ? stored.toInt() : fallback) & 0xFFFFFFFF).toInt();
  }

  double get galHookTextFontSize {
    final Object? stored = getPref(
      'gal_hook_text_font_size',
      defaultValue: galHookTextFontSizeDefault,
    );
    final double value =
        stored is num ? stored.toDouble() : galHookTextFontSizeDefault;
    return value.clamp(galHookTextFontSizeMin, galHookTextFontSizeMax);
  }

  Future<void> setGalHookTextFontSize(double value) async {
    await setPref(
      'gal_hook_text_font_size',
      value.clamp(galHookTextFontSizeMin, galHookTextFontSizeMax).toDouble(),
    );
    notifyListeners();
  }

  double get galHookTextLetterSpacing => _galHookDouble(
        'gal_hook_text_letter_spacing',
        fallback: galHookTextLetterSpacingDefault,
        min: galHookTextLetterSpacingMin,
        max: galHookTextLetterSpacingMax,
      );

  Future<void> setGalHookTextLetterSpacing(double value) async {
    await setPref(
      'gal_hook_text_letter_spacing',
      value
          .clamp(galHookTextLetterSpacingMin, galHookTextLetterSpacingMax)
          .toDouble(),
    );
    notifyListeners();
  }

  double get galHookTextLineHeight => _galHookDouble(
        'gal_hook_text_line_height',
        fallback: galHookTextLineHeightDefault,
        min: galHookTextLineHeightMin,
        max: galHookTextLineHeightMax,
      );

  Future<void> setGalHookTextLineHeight(double value) async {
    await setPref(
      'gal_hook_text_line_height',
      value
          .clamp(galHookTextLineHeightMin, galHookTextLineHeightMax)
          .toDouble(),
    );
    notifyListeners();
  }

  bool get galHookTextBold =>
      getPref('gal_hook_text_bold', defaultValue: true) == true;

  Future<void> setGalHookTextBold(bool value) async {
    await setPref('gal_hook_text_bold', value);
    notifyListeners();
  }

  String get galHookTextAlignment {
    final Object? value =
        getPref('gal_hook_text_alignment', defaultValue: 'center');
    return value == 'left' ? 'left' : 'center';
  }

  Future<void> setGalHookTextAlignment(String value) async {
    await setPref(
        'gal_hook_text_alignment', value == 'left' ? 'left' : 'center');
    notifyListeners();
  }

  /// BUG-1890：台词浮窗**垂直**对齐。与水平对齐同形的白名单二值收敛
  /// （'center' / 'top'），非法值一律回落 'center'（= 修前的唯一行为，
  /// 老配置读出来还是老样子）。
  ///
  /// 'top' 不只是「不居中」：native 侧此前已有 NEAR（顶对齐）分支，但只在文字**溢出**
  /// 窗口时才走，放得下就强制居中。长短句交替时台词会上下跳，这个偏好让用户把它钉死
  /// 在顶部。
  String get galHookTextVerticalAlignment {
    final Object? value =
        getPref('gal_hook_text_vertical_alignment', defaultValue: 'center');
    return value == 'top' ? 'top' : 'center';
  }

  Future<void> setGalHookTextVerticalAlignment(String value) async {
    await setPref(
        'gal_hook_text_vertical_alignment', value == 'top' ? 'top' : 'center');
    notifyListeners();
  }

  int get galHookTextColor =>
      _galHookColor('gal_hook_text_color', galHookTextColorDefault);

  Future<void> setGalHookTextColor(int value) async {
    await setPref('gal_hook_text_color', value & 0xFFFFFFFF);
    notifyListeners();
  }

  int get galHookTextBackgroundColor => _galHookColor(
        'gal_hook_text_background_color',
        galHookTextBackgroundColorDefault,
      );

  Future<void> setGalHookTextBackgroundColor(int value) async {
    await setPref('gal_hook_text_background_color', value & 0xFFFFFFFF);
    notifyListeners();
  }

  double get galHookTextBackgroundOpacity => _galHookDouble(
        'gal_hook_text_window_bg_opacity',
        fallback: galHookTextBackgroundOpacityDefault,
        min: 0.0,
        max: 1.0,
      );

  Future<void> setGalHookTextBackgroundOpacity(double value) async {
    await setPref(
      'gal_hook_text_window_bg_opacity',
      value.clamp(0.0, 1.0).toDouble(),
    );
    notifyListeners();
  }

  int get galHookTextOutlineColor => _galHookColor(
        'gal_hook_text_outline_color',
        galHookTextOutlineColorDefault,
      );

  Future<void> setGalHookTextOutlineColor(int value) async {
    await setPref('gal_hook_text_outline_color', value & 0xFFFFFFFF);
    notifyListeners();
  }

  double get galHookTextOutlineWidth => _galHookDouble(
        'gal_hook_text_outline_width',
        fallback: galHookTextOutlineWidthDefault,
        min: galHookTextOutlineWidthMin,
        max: galHookTextOutlineWidthMax,
      );

  Future<void> setGalHookTextOutlineWidth(double value) async {
    await setPref(
      'gal_hook_text_outline_width',
      value
          .clamp(galHookTextOutlineWidthMin, galHookTextOutlineWidthMax)
          .toDouble(),
    );
    notifyListeners();
  }

  double get galHookTextPadding => _galHookDouble(
        'gal_hook_text_padding',
        fallback: galHookTextPaddingDefault,
        min: galHookTextPaddingMin,
        max: galHookTextPaddingMax,
      );

  Future<void> setGalHookTextPadding(double value) async {
    await setPref(
      'gal_hook_text_padding',
      value.clamp(galHookTextPaddingMin, galHookTextPaddingMax).toDouble(),
    );
    notifyListeners();
  }

  double get galHookTextCornerRadius => _galHookDouble(
        'gal_hook_text_corner_radius',
        fallback: galHookTextCornerRadiusDefault,
        min: galHookTextCornerRadiusMin,
        max: galHookTextCornerRadiusMax,
      );

  Future<void> setGalHookTextCornerRadius(double value) async {
    await setPref(
      'gal_hook_text_corner_radius',
      value
          .clamp(galHookTextCornerRadiusMin, galHookTextCornerRadiusMax)
          .toDouble(),
    );
    notifyListeners();
  }

  /// 「游戏内查词」（KiriKiri in-game lookup）默认**开**。
  ///
  /// 代价只在真发生命中时才付：注入侧的传感器要等 `lookup_enabled=1` **且**引擎
  /// 导出表里查得到那几个 TJS 入口才装，装不上就整条链静默不启动；卡片层也是延迟到
  /// 第一帧才建。所以对非 KiriKiri 或不具备入口的游戏，开着与关着的运行期开销一致。
  /// 反过来默认关的代价是实打实的：用户不知道有这个功能，知道了也要先退出这一局、
  /// 去设置里翻开关、再重开一局才生效。
  static const bool galIngameLookupEnabledDefault = true;

  /// hook 台词浮窗「单击查词」。native 侧一直支持（`clickLookupEnabled`），Dart
  /// 侧此前写死 true，于是设置里根本没有这个开关。用户「至少开启穿透的时候我不是
  /// 很想单击点到单词，还是习惯用侧键查」。
  static const bool galHookClickLookupDefault = true;

  bool get galHookClickLookup =>
      getPref('gal_hook_click_lookup',
          defaultValue: galHookClickLookupDefault) ==
      true;

  Future<void> setGalHookClickLookup(bool value) async {
    await setPref('gal_hook_click_lookup', value);
    notifyListeners();
  }

  /// 查词触发方式：0 = 左键单击（默认）/ 1 = 鼠标中键 / 2 = 鼠标侧键。
  ///
  /// 与 [galHookClickLookup] **正交**：前者决定「查不查」，本项决定「用哪个键查」。
  /// 两者都关 = 浮窗上完全不查词，只用工具条。
  static const int galHookLookupTriggerDefault = 0;

  int get galHookLookupTrigger {
    final Object? stored = getPref('gal_hook_lookup_trigger',
        defaultValue: galHookLookupTriggerDefault);
    final int value =
        stored is num ? stored.toInt() : galHookLookupTriggerDefault;
    // 值域收在读这一层：越界值直接退回默认，别让一个坏值把 native 的分派打成
    // 「哪个键都不触发」。
    return value >= 0 && value <= 2 ? value : galHookLookupTriggerDefault;
  }

  Future<void> setGalHookLookupTrigger(int value) async {
    await setPref('gal_hook_lookup_trigger', value.clamp(0, 2));
    notifyListeners();
  }

  /// 工具条自动隐藏（LunaHook 式）：平时整条隐藏，鼠标进入台词框才现身。
  static const bool galHookToolbarAutoHideDefault = true;

  bool get galHookToolbarAutoHide =>
      getPref('gal_hook_toolbar_auto_hide',
          defaultValue: galHookToolbarAutoHideDefault) ==
      true;

  Future<void> setGalHookToolbarAutoHide(bool value) async {
    await setPref('gal_hook_toolbar_auto_hide', value);
    notifyListeners();
  }

  /// 工具条每个按钮图标下显示短文字说明（默认开）。浮窗比整排窄时 native 自动
  /// 退回纯图标，悬停提示照常。
  static const bool galHookToolbarLabelsDefault = true;

  bool get galHookToolbarLabels =>
      getPref('gal_hook_toolbar_labels',
          defaultValue: galHookToolbarLabelsDefault) ==
      true;

  Future<void> setGalHookToolbarLabels(bool value) async {
    await setPref('gal_hook_toolbar_labels', value);
    notifyListeners();
  }

  /// 穿透态下浮窗是否仍拦截落在**文字行盒**上的鼠标（默认 true = 拦截，点字查词才
  /// 成立）。关掉后整窗对游戏彻底透明——用户原话「穿透不彻底等于彻底不穿透」。
  static const bool galHookPassThroughBlocksMouseDefault = true;

  bool get galHookPassThroughBlocksMouse =>
      getPref('gal_hook_passthrough_blocks_mouse',
          defaultValue: galHookPassThroughBlocksMouseDefault) ==
      true;

  Future<void> setGalHookPassThroughBlocksMouse(bool value) async {
    await setPref('gal_hook_passthrough_blocks_mouse', value);
    notifyListeners();
  }

  /// 折叠「同一句台词的多次快照」（Zato 症状：一句台词分多次点击显示，工作台里
  /// 第二句出现两次）。默认开——引擎逐段重绘是 galgame 常态；留开关是给「某个引擎的
  /// 两句不同台词真的构成前缀关系」这种情形一个不改代码就能退回旧行为的逃生口。
  static const bool galHookFoldProgressiveLinesDefault = true;

  bool get galHookFoldProgressiveLines =>
      getPref(
        'gal_hook_fold_progressive_lines',
        defaultValue: galHookFoldProgressiveLinesDefault,
      ) ==
      true;

  Future<void> setGalHookFoldProgressiveLines(bool value) async {
    await setPref('gal_hook_fold_progressive_lines', value);
    notifyListeners();
  }

  /// 游戏内查词总开关（仅 Windows 生效）。
  bool get galIngameLookupEnabled =>
      getPref(
        'gal_hook_ingame_lookup_enabled',
        defaultValue: galIngameLookupEnabledDefault,
      ) ==
      true;

  Future<void> setGalIngameLookupEnabled(bool value) async {
    await setPref('gal_hook_ingame_lookup_enabled', value);
    notifyListeners();
  }

  bool get floatingLyricClickLookup =>
      getPref('floating_lyric_click_lookup', defaultValue: true) as bool;

  Future<void> setFloatingLyricClickLookup(bool value) async {
    await setPref('floating_lyric_click_lookup', value);
    notifyListeners();
  }

  // TODO-370: 悬浮字幕「按钮底色透明度」+「文字透明度」自定义。两值都是 0..100 的
  // 百分比，作用于基础 ARGB 的 alpha 通道——100 = 保持各主题原有观感（默认），调小变更
  // 透明。按钮底色基色按主题（深色白/浅色黑）随明暗变，故用百分比缩放其原 alpha 保证
  // 默认 100 时与历史像素一致；文字 alpha 默认满（100）。

  static int normalizeFloatingLyricOpacity(num value) =>
      value.round().clamp(0, 100).toInt();

  int get floatingLyricButtonBgOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_button_bg_opacity', defaultValue: 100) as int,
      );

  Future<void> setFloatingLyricButtonBgOpacity(int value) async {
    await setPref(
      'floating_lyric_button_bg_opacity',
      normalizeFloatingLyricOpacity(value),
    );
    notifyListeners();
  }

  int get floatingLyricTextOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_text_opacity', defaultValue: 100) as int,
      );

  Future<void> setFloatingLyricTextOpacity(int value) async {
    await setPref(
      'floating_lyric_text_opacity',
      normalizeFloatingLyricOpacity(value),
    );
    notifyListeners();
  }

  // TODO-576: 悬浮字幕/歌词条「背景透明度」自定义（0..100 百分比），作用于条本身的
  // 背景 ARGB alpha 通道。用户反馈默认背景太不透明、挡视野，故默认下调到 70（≈背景
  // 230/220 alpha ×0.7），既明显更透又保持可读；调小更透，调大更实。
  int get floatingLyricBgOpacity => normalizeFloatingLyricOpacity(
        getPref('floating_lyric_bg_opacity', defaultValue: 70) as int,
      );

  Future<void> setFloatingLyricBgOpacity(int value) async {
    await setPref(
      'floating_lyric_bg_opacity',
      normalizeFloatingLyricOpacity(value),
    );
    notifyListeners();
  }

  // TODO-708 P2: 悬浮字幕/歌词条「圆角半径」自定义（逻辑 dp）。0 = 直角；两端都按该
  // dp 值渲染背景与按钮圆角。上界 48 足够覆盖胶囊化诉求。默认 24 = M3E 大号容器圆角
  // （用户 2026-10-14：默认样式改 M3E）。
  static const int floatingLyricCornerRadiusDefault = 24;
  static const int floatingLyricCornerRadiusMax = 48;

  static int normalizeFloatingLyricCornerRadius(num value) =>
      value.round().clamp(0, floatingLyricCornerRadiusMax).toInt();

  int get floatingLyricCornerRadius => normalizeFloatingLyricCornerRadius(
        getPref(
          'floating_lyric_corner_radius',
          defaultValue: floatingLyricCornerRadiusDefault,
        ) as int,
      );

  Future<void> setFloatingLyricCornerRadius(int value) async {
    await setPref(
      'floating_lyric_corner_radius',
      normalizeFloatingLyricCornerRadius(value),
    );
    notifyListeners();
  }

  // TODO-708 P2: 悬浮字幕/歌词条「宽度」自定义（逻辑 dp）。0 = 平台原生默认宽度
  // （Android 撑满屏宽 MATCH_PARENT / Windows 720dip 起始宽 + 可拖拽），默认不改动时
  // 视觉与历史一致；>0 时两端都按该 dp 值设窗口宽（居中）。范围 200..1200 覆盖窄条到
  // 宽横幅。
  static const int floatingLyricWidthDefault = 0;
  static const int floatingLyricWidthMin = 200;
  static const int floatingLyricWidthMax = 1200;

  /// 归一悬浮窗宽度：0 保持为「自动/平台默认」哨兵，其余夹到 [min, max]。
  static int normalizeFloatingLyricWidth(num value) {
    final int rounded = value.round();
    if (rounded <= 0) return 0;
    return rounded.clamp(floatingLyricWidthMin, floatingLyricWidthMax).toInt();
  }

  int get floatingLyricWidth => normalizeFloatingLyricWidth(
        getPref(
          'floating_lyric_width',
          defaultValue: floatingLyricWidthDefault,
        ) as int,
      );

  Future<void> setFloatingLyricWidth(int value) async {
    await setPref(
      'floating_lyric_width',
      normalizeFloatingLyricWidth(value),
    );
    notifyListeners();
  }

  // TODO-708 P4: 悬浮字幕/歌词条「上下文行数」——在当前行上下各显示 N 行前后文
  // （对称单值）。0 = 只当前行 = 今天的单行观感（默认），确保默认不改动时逐字节一致；
  // 1..3 时 Dart 端组装多行文本推给原生渲染（路线 A）。上界 3 足够铺满一小条上下文而
  // 不喧宾夺主；per-Profile 自动快照（不加排除集）。
  static const int floatingLyricContextLinesDefault = 0;
  static const int floatingLyricContextLinesMax = 3;

  static int normalizeFloatingLyricContextLines(num value) =>
      value.round().clamp(0, floatingLyricContextLinesMax).toInt();

  int get floatingLyricContextLines => normalizeFloatingLyricContextLines(
        getPref(
          'floating_lyric_context_lines',
          defaultValue: floatingLyricContextLinesDefault,
        ) as int,
      );

  Future<void> setFloatingLyricContextLines(int value) async {
    await setPref(
      'floating_lyric_context_lines',
      normalizeFloatingLyricContextLines(value),
    );
    notifyListeners();
  }

  // 悬浮字幕「同时显示句数」（取代上面的对称上下文 N）。1..15 = 固定显示这么多句，
  // 当前句居中（偶数时下文多一句，与歌词模式「往下看」的阅读方向一致）；0 = 自动：
  // 前后各送 12 句（`floatingLyricVisibleSpan`），原生窗把当前句滚到视口中央、超出
  // 窗高的裁掉——拖高窗口就看到更多句（Windows）。新键没写过、旧 N 键**显式写过**
  // （含显式 0）时按 2N+1 换算（0 → 1 句），改过这项的老用户观感不变；两个键都没写
  // 过就用默认 3 句。偏好默认值从不落库，所以从没动过这项的老用户也会从 1 句变成
  // 3 句（圆角同理从 0 变 24）——所有者 2026-10-15 拍板接受这一变化，不另做老用户判别。
  static const int floatingLyricVisibleLinesAuto = 0;
  static const int floatingLyricVisibleLinesDefault = 3;
  static const int floatingLyricVisibleLinesMax = 15;

  static int normalizeFloatingLyricVisibleLines(num value) =>
      value.round().clamp(0, floatingLyricVisibleLinesMax).toInt();

  int get floatingLyricVisibleLines {
    final Object? stored = getPref('floating_lyric_visible_lines');
    if (stored is num) return normalizeFloatingLyricVisibleLines(stored);
    final Object? legacy = getPref('floating_lyric_context_lines');
    if (legacy is num) {
      return normalizeFloatingLyricVisibleLines(
          normalizeFloatingLyricContextLines(legacy) * 2 + 1);
    }
    return floatingLyricVisibleLinesDefault;
  }

  Future<void> setFloatingLyricVisibleLines(int value) async {
    await setPref('floating_lyric_visible_lines',
        normalizeFloatingLyricVisibleLines(value));
    notifyListeners();
  }

  // 悬浮字幕排版（Windows 原生窗 DirectWrite；Android TextView 只吃其中能表达的
  // 几项）。字段与 galgame hook 台词浮窗同一套原生 Style，取值区间也与之对齐。
  static const double floatingLyricLineHeightDefault = 1.25;
  static const double floatingLyricLineHeightMin = 0.8;
  static const double floatingLyricLineHeightMax = 2.0;
  static const double floatingLyricLetterSpacingMin = -2.0;
  static const double floatingLyricLetterSpacingMax = 12.0;
  static const double floatingLyricOutlineWidthMax = 6.0;
  static const int floatingLyricTextPaddingDefault = 16;
  static const int floatingLyricTextPaddingMax = 60;
  static const int floatingLyricContextOpacityDefault = 55;

  /// 竖排（Windows 原生窗：字从上往下、行从右往左，与竖排歌词同向）。默认横排。
  bool get floatingLyricVertical {
    final Object? stored = getPref('floating_lyric_vertical');
    return stored is bool && stored;
  }

  Future<void> setFloatingLyricVertical(bool value) async {
    await setPref('floating_lyric_vertical', value);
    notifyListeners();
  }

  bool get floatingLyricBold {
    final Object? stored = getPref('floating_lyric_bold');
    return stored is bool ? stored : true;
  }

  Future<void> setFloatingLyricBold(bool value) async {
    await setPref('floating_lyric_bold', value);
    notifyListeners();
  }

  double get floatingLyricLineHeight {
    final Object? stored = getPref('floating_lyric_line_height');
    final double value =
        stored is num ? stored.toDouble() : floatingLyricLineHeightDefault;
    return value.clamp(floatingLyricLineHeightMin, floatingLyricLineHeightMax);
  }

  Future<void> setFloatingLyricLineHeight(double value) async {
    await setPref('floating_lyric_line_height',
        value.clamp(floatingLyricLineHeightMin, floatingLyricLineHeightMax));
    notifyListeners();
  }

  double get floatingLyricLetterSpacing {
    final Object? stored = getPref('floating_lyric_letter_spacing');
    final double value = stored is num ? stored.toDouble() : 0.0;
    return value.clamp(
        floatingLyricLetterSpacingMin, floatingLyricLetterSpacingMax);
  }

  Future<void> setFloatingLyricLetterSpacing(double value) async {
    await setPref(
        'floating_lyric_letter_spacing',
        value.clamp(
            floatingLyricLetterSpacingMin, floatingLyricLetterSpacingMax));
    notifyListeners();
  }

  /// 描边宽（逻辑 px）。默认 0：M3E 卡片底上的字不需要描边；底板调透明后
  /// 想要桌面歌词式描边再打开。
  double get floatingLyricOutlineWidth {
    final Object? stored = getPref('floating_lyric_outline_width');
    final double value = stored is num ? stored.toDouble() : 0.0;
    return value.clamp(0.0, floatingLyricOutlineWidthMax);
  }

  Future<void> setFloatingLyricOutlineWidth(double value) async {
    await setPref('floating_lyric_outline_width',
        value.clamp(0.0, floatingLyricOutlineWidthMax));
    notifyListeners();
  }

  /// 水平对齐：0 = 居中（默认），1 = 左对齐。
  int get floatingLyricTextAlignment {
    final Object? stored = getPref('floating_lyric_text_alignment');
    return stored is num && stored.round() == 1 ? 1 : 0;
  }

  Future<void> setFloatingLyricTextAlignment(int value) async {
    await setPref('floating_lyric_text_alignment', value == 1 ? 1 : 0);
    notifyListeners();
  }

  int get floatingLyricTextPadding {
    final Object? stored = getPref('floating_lyric_text_padding');
    final int value =
        stored is num ? stored.round() : floatingLyricTextPaddingDefault;
    return value.clamp(0, floatingLyricTextPaddingMax);
  }

  Future<void> setFloatingLyricTextPadding(int value) async {
    await setPref('floating_lyric_text_padding',
        value.clamp(0, floatingLyricTextPaddingMax));
    notifyListeners();
  }

  /// 多行时非当前句的不透明度（0..100，相对文字色）。
  int get floatingLyricContextOpacity {
    final Object? stored = getPref('floating_lyric_context_opacity');
    return normalizeFloatingLyricOpacity(
        stored is num ? stored : floatingLyricContextOpacityDefault);
  }

  Future<void> setFloatingLyricContextOpacity(int value) async {
    await setPref(
        'floating_lyric_context_opacity', normalizeFloatingLyricOpacity(value));
    notifyListeners();
  }

  /// 悬浮字幕四色（ARGB）。键缺省或存 [floatingLyricColorFollowTheme] = 跟随主题
  /// （M3E 配对色，见 `floating_lyric_style.dart`）；其余值 = 用户自选色。
  ///
  /// 哨兵取 -1 而不是 0：ARGB 经 `Color.toARGB32()` 恒落在 0..0xFFFFFFFF，-1 永远
  /// 不会与合法颜色撞值；0 是合法的「完全透明黑」（描边色开了 alpha 通道，用户
  /// 真能选到它），若拿 0 当哨兵，选完全透明会被误判成跟随主题。
  static const int floatingLyricColorFollowTheme = -1;

  int floatingLyricColor(FloatingLyricColorRole role) {
    final Object? stored = getPref(role.prefKey);
    return stored is num ? stored.toInt() : floatingLyricColorFollowTheme;
  }

  Future<void> setFloatingLyricColor(
      FloatingLyricColorRole role, int argb) async {
    await setPref(role.prefKey, argb);
    notifyListeners();
  }

  /// Windows 悬浮字幕窗口矩形（物理 px JSON，`{left,top,width,height}`）；空 =
  /// 平台默认位置。用户拖动 / 拖角缩放后由原生 `windowRectChanged` 回写。
  String get floatingLyricWindowRect {
    final Object? stored = getPref(kFloatingLyricWindowRectPrefKey);
    return stored is String ? stored : '';
  }

  Future<void> setFloatingLyricWindowRect(String json) async {
    await setPref(kFloatingLyricWindowRectPrefKey, json);
  }

  // ── update preferences ───────────────────────────────────────────────

  /// P2P（torrent）传输的代理档位：`direct`（**默认**，直连）/ `proxy`
  /// （peer/tracker/DNS 全代理，可能降速，且不少代理服务商禁止 BT 流量：
  /// 限速/警告/封号）/ `mixed`（tracker 经代理、DHT 与 peer 直连——节点获取
  /// 范围最大，但真实 IP 暴露给 DHT/peer/tracker，只是连通性工具）。
  /// 只对内置引擎生效（外接 qBittorrent 自管）。
  ///
  /// 三态键未写过时沿用旧布尔开关 `network_proxy_p2p_enabled`（冻结，
  /// PR#1051 引入）的语义：true → 全代理。
  String get p2pProxyMode {
    final String raw =
        getPref('network_proxy_p2p_mode', defaultValue: '') as String;
    if (raw == 'direct' || raw == 'proxy' || raw == 'mixed') return raw;
    final bool legacyEnabled =
        getPref('network_proxy_p2p_enabled', defaultValue: false) as bool;
    return legacyEnabled ? 'proxy' : 'direct';
  }

  Future<void> setP2pProxyMode(String mode) async {
    assert(mode == 'direct' || mode == 'proxy' || mode == 'mixed');
    await setPref('network_proxy_p2p_mode', mode);
    // 写穿旧布尔键：降级回老版本后语义一致（mixed 按「开」处理）。
    await setPref('network_proxy_p2p_enabled', mode != 'direct');
    notifyListeners();
  }

  /// 全局公网出口模式：auto = 环境/系统代理自动探测；direct = 强制直连；
  /// manual = 使用 [updateCustomProxy]。旧安装没有本键时，已有手填地址自动沿用
  /// manual，否则沿用历史 auto 语义。
  String get networkProxyMode {
    final String? stored =
        getPref('network_proxy_mode', defaultValue: null) as String?;
    if (stored == kProxyModeAuto ||
        stored == kProxyModeDirect ||
        stored == kProxyModeManual) {
      return stored!;
    }
    // 迁移判据是「这个存量地址归一得出来吗」，不是「非空吗」。设置页对非法地址只
    // 弹 SnackBar 但仍存原串，非空判据会把这类值推成 manual，而 manual 归一失败
    // 时硬走 DIRECT —— 存量用户升级即断网。只有「显式选了 manual」才该 fail-closed。
    return normalizeUserProxyHostPort(updateCustomProxy) == null
        ? kProxyModeAuto
        : kProxyModeManual;
  }

  Future<void> setNetworkProxyMode(String value) async {
    final String normalized =
        value == kProxyModeDirect || value == kProxyModeManual
            ? value
            : kProxyModeAuto;
    await setPref('network_proxy_mode', normalized);
    notifyListeners();
  }

  String get networkProxyUsername =>
      getPref('network_proxy_username', defaultValue: '') as String;

  Future<void> setNetworkProxyUsername(String value) async {
    await setPref('network_proxy_username', value);
    notifyListeners();
  }

  String get networkProxyPassword =>
      getPref('network_proxy_password', defaultValue: '') as String;

  Future<void> setNetworkProxyPassword(String value) async {
    await setPref('network_proxy_password', value);
    notifyListeners();
  }

  bool get updateNeverRemind =>
      getPref('update_never_remind', defaultValue: false) as bool;

  Future<void> setUpdateNeverRemind(bool value) async {
    await setPref('update_never_remind', value);
    notifyListeners();
  }

  bool get updateAutoInstall =>
      getPref('update_auto_install', defaultValue: false) as bool;

  Future<void> setUpdateAutoInstall(bool value) async {
    await setPref('update_auto_install', value);
    notifyListeners();
  }

  bool get updateBetaChannel =>
      getPref('update_beta_channel', defaultValue: false) as bool;

  Future<void> setUpdateBetaChannel(bool value) async {
    await setPref('update_beta_channel', value);
    notifyListeners();
  }

  bool get updateDebugChannel =>
      getPref('update_debug_channel', defaultValue: false) as bool;

  Future<void> setUpdateDebugChannel(bool value) async {
    await setPref('update_debug_channel', value);
    notifyListeners();
  }

  /// 用户手填的「自定义更新代理」（`host:port`，空串=未设）。fake-ip/TUN 模式下系统
  /// 代理只写注册表、Dart HttpClient 读不到时的兜底入口（TODO-871/862）：非空时检查/下载
  /// 直接走它，优先于 env/GUI 系统代理。空串=清除（回退默认 env>GUI>DIRECT 逻辑）。
  String get updateCustomProxy =>
      getPref('update_custom_proxy', defaultValue: '') as String;

  Future<void> setUpdateCustomProxy(String value) async {
    await setPref('update_custom_proxy', value);
    notifyListeners();
  }

  /// 更新资产首选下载源。auto = 既有智能顺序；r2 / github / proxy:<prefix>
  /// 只改变首选顺序，失败时仍保留完整回退链。
  String get updateDownloadSource =>
      getPref('update_download_source', defaultValue: 'auto') as String;

  Future<void> setUpdateDownloadSource(String value) async {
    await setPref('update_download_source', value);
    notifyListeners();
  }

  /// 外部 mokuro CLI 可执行路径（漫画 OCR 后备；空串=未设）。内置 ONNX 引擎在本平台不可用
  /// 或用户偏好外部工具时，OCR 导入向导据此调用系统 mokuro（见 [ExternalMokuroRunner]）。
  /// 空串=未指定，运行时退回 `FUSHI_MOKURO` 环境变量 / PATH 探测。
  String get asrTranscribeLanguage =>
      getPref('asr_transcribe_language', defaultValue: 'ja') as String;

  Future<void> setAsrTranscribeLanguage(String value) async {
    await setPref('asr_transcribe_language', value);
    notifyListeners();
  }

  /// 只有音频的有声书下载完成后是否自动转录入库（默认开）。
  bool get audiobookAutoTranscribe =>
      getPref('audiobook_auto_transcribe', defaultValue: true) as bool;

  Future<void> setAudiobookAutoTranscribe({required bool value}) async {
    await setPref('audiobook_auto_transcribe', value);
    notifyListeners();
  }

  String get mangaSpreadPreference =>
      getPref('manga_spread_preference', defaultValue: 'auto') as String;

  Future<void> setMangaSpreadPreference(String value) async {
    await setPref('manga_spread_preference', value);
    notifyListeners();
  }

  String get mangaReadingDirection =>
      getPref('manga_reading_direction', defaultValue: 'rtl') as String;

  Future<void> setMangaReadingDirection(String value) async {
    await setPref('manga_reading_direction', value);
    notifyListeners();
  }

  /// 在线漫画封面磁盘缓存的保留天数（BUG-2450，默认 180）。
  int get mangaCoverCacheMaxAgeDays {
    final int days = getPref(
      'manga_cover_cache_max_age_days',
      defaultValue: kMangaCoverCacheDefaultMaxAgeDays,
    ) as int;
    return days.clamp(kMangaCoverCacheMinDays, kMangaCoverCacheMaxDays);
  }

  Future<void> setMangaCoverCacheMaxAgeDays(int value) async {
    await setPref(
      'manga_cover_cache_max_age_days',
      value.clamp(kMangaCoverCacheMinDays, kMangaCoverCacheMaxDays),
    );
    notifyListeners();
  }

  int get mangaZoomPercent => normalizeStoredMangaZoomPercent(
      getPref('manga_zoom_percent', defaultValue: 100) as int);

  Future<void> setMangaZoomPercent(int value) async {
    await setPref(
      'manga_zoom_percent',
      value.clamp(kMangaZoomMinPercent, kMangaZoomMaxPercent),
    );
    notifyListeners();
  }

  /// 滚轮/捏合缩放灵敏度倍率（百分比，100 = 基准）。
  int get mangaZoomSensitivity => getPref('manga_zoom_sensitivity',
      defaultValue: kMangaZoomSensitivityDefault) as int;

  Future<void> setMangaZoomSensitivity(int value) async {
    await setPref(
      'manga_zoom_sensitivity',
      value.clamp(kMangaZoomSensitivityMin, kMangaZoomSensitivityMax),
    );
    notifyListeners();
  }

  /// 翻页动画样式（[PageTurnAnimation.key]：`none` / `slide` / `cover` / `fade`）。
  ///
  /// 这是漫画阅读器翻页动画的**唯一真相源**；
  /// [MangaReaderPreferences.animateTransitions] 只是它的只读投影（见
  /// [mangaReaderPreferences]），为旧数据 / 备份 / Profile 兼容保留。键从未写过时
  /// （早于本键的安装 / 只恢复了 JSON 的备份）按旧 JSON 里的 `animateTransitions`
  /// 迁移：显式关过过渡 = `none`，其余回落默认 `slide`。落盘值不认识时同样回落
  /// `slide`，读出值恒为合法 key。
  String get mangaPageAnimation {
    final Object? stored = getPref('manga_page_animation');
    if (stored is String) return mangaPageAnimationFromKey(stored).key;
    return _legacyMangaAnimateTransitions() == false
        ? PageTurnAnimation.none.key
        : kMangaPageAnimationDefault.key;
  }

  Future<void> setMangaPageAnimation(String value) async {
    await setPref('manga_page_animation', mangaPageAnimationFromKey(value).key);
    notifyListeners();
  }

  /// 旧 `manga_reader_preferences` JSON 里的 `animateTransitions`（没有 / 解析
  /// 失败 = null）。
  bool? _legacyMangaAnimateTransitions() {
    final Object? raw = getPref('manga_reader_preferences');
    if (raw is! String || raw.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map && decoded['animateTransitions'] is bool) {
        return decoded['animateTransitions'] as bool;
      }
    } on FormatException {
      // 坏 JSON 等价于没有旧值。
    }
    return null;
  }

  /// 翻页动画速度（[PageTurnAnimationSpeed.key]，默认 `normal`）。
  String get mangaPageAnimationSpeed => PageTurnAnimationSpeed.fromKey(
        getPref('manga_page_animation_speed') as String?,
      ).key;

  Future<void> setMangaPageAnimationSpeed(String value) async {
    await setPref(
      'manga_page_animation_speed',
      PageTurnAnimationSpeed.fromKey(value).key,
    );
    notifyListeners();
  }

  /// 单 / 双页模式滑动翻页「拖动跟手」（默认开）。
  bool get mangaPageTurnFollowDrag => getPref('manga_page_turn_follow_drag',
      defaultValue: kMangaPageTurnFollowDragDefault) as bool;

  Future<void> setMangaPageTurnFollowDrag(bool value) async {
    await setPref('manga_page_turn_follow_drag', value);
    notifyListeners();
  }

  /// 音量键翻页（漫画阅读器）。默认开：与 EPUB 阅读器的音量键翻页一致。
  bool get mangaVolumeKeyPaging =>
      getPref('manga_volume_key_paging', defaultValue: true) as bool;

  Future<void> setMangaVolumeKeyPaging(bool value) async {
    await setPref('manga_volume_key_paging', value);
    notifyListeners();
  }

  /// 漫画阅读器顶栏是否悬浮（默认开，与 EPUB 阅读器「点空白隐藏控制栏」同默认）。
  /// 悬浮 = 顶栏不占布局、默认收起、点页面中央 / 顶边悬停唤出并自动收起；
  /// 关 = 顶栏常驻并占 48px 布局高，页图在它下方排布。
  bool get mangaChromeFloating =>
      getPref('manga_chrome_floating', defaultValue: true) as bool;

  Future<void> setMangaChromeFloating(bool value) async {
    await setPref('manga_chrome_floating', value);
    notifyListeners();
  }

  /// 点击页面左右边缘翻页。默认开：触屏此前完全没有点击翻页手段。
  bool get mangaTapZonePaging =>
      getPref('manga_tap_zone_paging', defaultValue: true) as bool;

  Future<void> setMangaTapZonePaging(bool value) async {
    await setPref('manga_tap_zone_paging', value);
    notifyListeners();
  }

  bool get mangaPanelNavigation => getPref(
        'manga_panel_navigation',
        defaultValue: kMangaPanelNavigationDefault,
      ) as bool;

  Future<void> setMangaPanelNavigation(bool value) async {
    await setPref('manga_panel_navigation', value);
    notifyListeners();
  }

  bool get mangaPanelNavigationEnabled => mangaPanelNavigation;

  /// 一键制卡的卡图默认裁到所在分镜（只在分镜模型可用且非条漫时生效）。
  bool get mangaMiningCropToPanel => getPref(
        'manga_mining_crop_to_panel',
        defaultValue: kMangaMiningCropToPanelDefault,
      ) as bool;

  Future<void> setMangaMiningCropToPanel(bool value) async {
    await setPref('manga_mining_crop_to_panel', value);
    notifyListeners();
  }

  Future<void> setMangaPanelNavigationEnabled(bool value) =>
      setMangaPanelNavigation(value);

  /// 点击翻页的热区布局（[MangaTapZoneLayout] 的字符串键）。默认 `left_right`
  /// = 旧行为（左右各一条 25% 竖条）。只在 [mangaTapZonePaging] 开启时有意义。
  String get mangaTapZoneLayout =>
      getPref(
            'manga_tap_zone_layout',
            defaultValue: kMangaTapZoneLayoutDefault,
          )
          as String;

  Future<void> setMangaTapZoneLayout(String value) async {
    await setPref('manga_tap_zone_layout', value);
    notifyListeners();
  }

  /// 漫画阅读器底色（[MangaBackground] 的字符串键）。默认 `black` = 旧行为。
  String get mangaBackground =>
      getPref('manga_background', defaultValue: kMangaBackgroundDefault)
          as String;

  Future<void> setMangaBackground(String value) async {
    await setPref('manga_background', value);
    notifyListeners();
  }

  /// 双页模式的跨页偏移：1 = 封面独占单页后再两两配对（日漫惯例，旧行为）；
  /// 0 = 从第一页起就配对。扫描来源不同，封面算不算「第 0 页」并不统一，选错会让
  /// 整卷左右页全反。
  int get mangaSpreadOffset =>
      getPref('manga_spread_offset', defaultValue: kMangaSpreadOffsetDefault)
          as int;

  Future<void> setMangaSpreadOffset(int value) async {
    await setPref('manga_spread_offset', value);
    notifyListeners();
  }

  /// Existing individual keys stay authoritative for shared legacy controls.
  /// This prevents an older settings surface from being shadowed by JSON.
  MangaReaderPreferences get mangaReaderPreferences {
    Map<String, Object?> values = <String, Object?>{};
    final Object? raw = getPref('manga_reader_preferences');
    if (raw is String && raw.isNotEmpty) {
      try {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) values = decoded;
      } on FormatException {
        // A malformed optional value is equivalent to absent defaults.
      }
    }
    if (!values.containsKey('mode') && !values.containsKey('autoMode')) {
      final String legacyMode = mangaSpreadPreference;
      values = <String, Object?>{
        ...values,
        'autoMode': legacyMode == 'auto',
        if (legacyMode == 'spread' || legacyMode == 'webtoon')
          'mode': legacyMode,
      };
    }
    return MangaReaderPreferences.fromJson(<String, Object?>{
      ...values,
      'direction': mangaReadingDirection,
      'background': mangaBackground,
      'zoomStart': mangaZoomPercent,
      'animateTransitions': mangaPageAnimation != 'none',
      'tapZones': !mangaTapZonePaging
          ? 'disabled'
          : mangaTapZoneLayout == 'left_right'
          ? 'right_left'
          : mangaTapZoneLayout,
      'volumeKeys': mangaVolumeKeyPaging,
      'spreadOffset': mangaSpreadOffset,
    });
  }

  Future<void> setMangaReaderPreferences(MangaReaderPreferences value) async {
    await setPref('manga_reader_preferences', jsonEncode(value.toJson()));
    await setPref(
      'manga_spread_preference',
      value.autoMode ? 'auto' : value.mode.storageKey,
    );
    await setPref('manga_reading_direction', value.direction);
    await setPref('manga_background', value.background);
    await setPref('manga_zoom_percent', value.zoomStart);
    await setPref(
      'manga_tap_zone_paging',
      value.tapZones != MangaTapZonePreset.disabled,
    );
    await setPref(
      'manga_tap_zone_layout',
      value.tapZones == MangaTapZonePreset.rightAndLeft
          ? 'left_right'
          : value.tapZones.key,
    );
    await setPref('manga_volume_key_paging', value.volumeKeys);
    await setPref('manga_spread_offset', value.spreadOffset);
    // `manga_page_animation` 不再从 animateTransitions 反写：翻页动画只由四选一
    // （[setMangaPageAnimation]）决定，animateTransitions 只是读出时的投影。反写会
    // 让任何拿着旧对象整份写回的调用方把刚选的「淡入淡出 / 覆盖」打回成 slide。
    notifyListeners();
  }

  /// 宽页（见开き）自动独占一屏。默认开：宽页被塞进半个槽既缩成一半宽，又会把
  /// 它之后所有页的配对错开一位。
  bool get mangaWidePageSolo =>
      getPref('manga_wide_page_solo', defaultValue: kMangaWidePageSoloDefault)
          as bool;

  Future<void> setMangaWidePageSolo(bool value) async {
    await setPref('manga_wide_page_solo', value);
    notifyListeners();
  }

  /// 在线漫画重新打开时回到哪里（`MangaResumeTarget` 的字符串键）。默认
  /// `furthest` = 旧行为（读完过的章算过去了，按进度往前推）；`last` = 和书一样
  /// 回到最后停下的那一页。
  String get mangaResumeTarget =>
      getPref('manga_resume_target', defaultValue: kMangaResumeTargetDefault)
          as String;

  Future<void> setMangaResumeTarget(String value) async {
    await setPref('manga_resume_target', value);
    notifyListeners();
  }

  /// 漫画章节列表（作品页 + 阅读器章节抽屉共用）的排序：true = 新→旧（源顺序，
  /// 旧行为），false = 第 1 话在前。用户切一次两处都记住。
  bool get mangaChapterListNewestFirst =>
      getPref('manga_chapter_list_newest_first', defaultValue: true) as bool;

  Future<void> setMangaChapterListNewestFirst(bool value) async {
    await setPref('manga_chapter_list_newest_first', value);
    notifyListeners();
  }

  /// 作品页「完成后自动识别」：章节下载任务入队时的 `auto_ocr` 取值（设计稿
  /// 2026-09-12 §5）。默认关——自动 OCR 要么占本机算力要么走已配对主机，
  /// 不该在用户没点过的情况下悄悄开始。
  bool get mangaDownloadAutoOcr =>
      getPref('manga_download_auto_ocr', defaultValue: false) as bool;

  Future<void> setMangaDownloadAutoOcr(bool value) async {
    await setPref('manga_download_auto_ocr', value);
    notifyListeners();
  }

  // 旧版单框 Gemini 云端识别的三对 getter/setter（`manga_cloud_ocr_enabled` /
  // `manga_cloud_ocr_api_key` / `manga_cloud_ocr_model`）随 PR#474 删掉框选补扫
  // 实现后已零消费方，本轮一并清掉（BUG-1164）。
  //
  // ⚠️ 存量设备的 Drift `preferences` 行**不删**（没有迁移方案就别动持久化数据），
  // 而 `manga_cloud_ocr_api_key` 仍然留在
  // `sync/pref_redaction_policy.dart` 的 `sensitiveKeys` 里 —— 老用户库里已经写
  // 过的那个 key 必须继续被备份/Profile 快照/Profile 分享三条出境通道剔除。
  // 删代码不等于删数据，脱敏名单不能跟着删。

  // galgame 窗口超分**不再有全局偏好**（BUG-1191）。原来的
  // `galgame_magpie_upscaling_mode` 是个一刀切开关，而超分该不该开完全取决于**这个
  // 游戏**的原生分辨率：同一个人手上既有 800×600 的老 gal，也有本身就 1080p 的新作。
  // 档位已改为每游戏一档，存在 galgame 库那一行（`galgames.upscaling_mode`）。
  //
  // v63 精确删除存量 `galgame_magpie_upscaling_mode` live 行及其 pref Profile
  // 副本，不迁移到任何游戏；旧 Profile apply/JSON import 也会拒绝它复活。全局值
  // 无法映射成「每个游戏各自开不开」，新结构仍一律从关闭起步，用户按游戏自己开。

  // 下载域曾有独立的代理三态（`download_network_proxy_mode` /
  // `download_custom_proxy`），2026-08-29 合并进唯一的全局代理项
  // [updateCustomProxy]；存量行由 schema v90 迁移归并后删除，这里不再有读写器。

  /// TODO-1961：内置下载引擎的下载根（新任务落点）。空串 = 未设置 → 用默认根
  /// `<documents>/anime_downloads/content`（与本 key 出现之前逐字节一致）。
  /// 设备本地路径，不进 Profile 快照（见 `ProfileKeys._excludedPrefKeys`）。
  /// 发现页「全部源」聚合默认排除的源 id（逗号分隔）。默认排除 sukebei
  /// （18+ 源只在用户于源下拉里**显式单选**时使用，不进默认聚合）。
  String get discoveryDisabledSources =>
      getPref('discovery_disabled_sources', defaultValue: 'sukebei') as String;

  Future<void> setDiscoveryDisabledSources(String value) async {
    await setPref('discovery_disabled_sources', value);
    notifyListeners();
  }

  /// 发现页隐藏 0 做种的种子条目。**默认开**（用户 2026-09-08 拍板；调研里
  /// 交互式 UI 的通行做法是只沉底不隐藏，记录为反对意见）。
  bool get discoveryHideZeroSeeders =>
      getPref('discovery_hide_zero_seeders', defaultValue: true) as bool;

  Future<void> setDiscoveryHideZeroSeeders(bool value) async {
    await setPref('discovery_hide_zero_seeders', value);
    notifyListeners();
  }

  /// 发现页隐藏疑似漫画（只隐藏 `DiscoveryContentHint.manga` 档，undecided
  /// 保留）。默认开。
  bool get discoveryHideSuspectedManga =>
      getPref('discovery_hide_suspected_manga', defaultValue: true) as bool;

  Future<void> setDiscoveryHideSuspectedManga(bool value) async {
    await setPref('discovery_hide_suspected_manga', value);
    notifyListeners();
  }

  /// 发现页 Nyaa 过滤三态（0 全部 / 1 排除 remake / 2 仅 trusted），透传为
  String get downloadSaveRoot =>
      getPref('download_save_root', defaultValue: '') as String;

  Future<void> setDownloadSaveRoot(String value) async {
    await setPref('download_save_root', value);
    notifyListeners();
  }

  /// 有声书素材库目录（JSON 字符串数组）。库里放按作品身份命名的字幕/正文，
  /// 下载完成后据此自动配齐「正文 + 字幕 + 音频」；解码见
  /// `decodeAudiobookMaterialDirs`。
  String get audiobookMaterialDirs =>
      getPref('audiobook_material_dirs', defaultValue: '') as String;

  Future<void> setAudiobookMaterialDirs(String value) async {
    await setPref('audiobook_material_dirs', value);
    notifyListeners();
  }

  /// TODO-1961：用过的历史下载根（JSON 字符串数组，新的在前，见
  /// `encodeSaveRootHistory`）。**只**用于让改目录之前的旧任务在下载页仍被认出，
  /// 永不作为写入目标。旧任务不迁移是刻意的：迁移=移动几十 GB 且掐断做种。
  String get downloadSaveRootHistory =>
      getPref('download_save_root_history', defaultValue: '') as String;

  Future<void> setDownloadSaveRootHistory(String value) async {
    await setPref('download_save_root_history', value);
    notifyListeners();
  }

  /// TODO-1024 / BUG-479：上次更新检查结果缓存（解码后；无/畸形 → null）。检查时先读它
  /// 乐观即时反馈，网络刷新在后台跑完再写回——不再每次冷查 GitHub 才知道结果（恒快）。
  UpdateCheckCacheEntry? get updateCheckCache => UpdateCheckCacheEntry.decode(
        getPref(updateCheckCachePrefKey, defaultValue: '') as String,
      );

  /// 写回更新检查结果缓存（落 `preferences` 表单 key）。不 `notifyListeners`——缓存是
  /// 后台静默刷新的产物，不驱动 UI 重建，避免无谓 rebuild。
  Future<void> setUpdateCheckCache(UpdateCheckCacheEntry entry) =>
      setPref(updateCheckCachePrefKey, entry.encode());

  // ── anki deck/model selection ────────────────────────────────────────

  String get lastSelectedDeckName =>
      getPref('last_selected_deck', defaultValue: 'Default') as String;

  Future<void> setLastSelectedDeck(String deckName) async {
    await setPref('last_selected_deck', deckName);
  }

  String? get lastSelectedModel => getPref('last_selected_model');

  Future<void> setLastSelectedModelName(String modelName) async {
    await setPref('last_selected_model', modelName);
    notifyListeners();
  }

  // ── low memory mode (raw pref only; side effect in AppModel) ─────────

  bool get lowMemoryMode =>
      getPref('low_memory_mode', defaultValue: false) as bool;

  // ── reading goals (TODO-1046) ────────────────────────────────────────
  // Daily/weekly reading targets measured in characters. 0 = unset/off,
  // which the statistics page treats as "no goal" (goal card hidden). Read
  // and write clamped so a corrupt/out-of-range stored value can never reach
  // the progress UI as an absurd goal. Per-Profile (not excluded in
  // ProfileKeys), so each profile keeps its own targets.

  /// v90 阅读空闲门（分钟）：这么久没有翻页 / 滚动 / 查词等输入就视为没在读，
  /// 之后的时长不入账。只对阅读面（小说 / PDF / 漫画）生效，视频以播放态为准
  /// （用户拍板）。偏好键与 fushi_audio 的 [kStudyIdleTimeoutPrefKey] 同名。
  static const int readingIdleTimeoutMinutesMin = 1;
  static const int readingIdleTimeoutMinutesMax = 120;

  int get readingIdleTimeoutMinutes => (getPref(kStudyIdleTimeoutPrefKey,
          defaultValue: kDefaultReadingIdleTimeout.inMinutes) as int)
      .clamp(readingIdleTimeoutMinutesMin, readingIdleTimeoutMinutesMax);

  Future<void> setReadingIdleTimeoutMinutes(int value) async {
    await setPref(
      kStudyIdleTimeoutPrefKey,
      value.clamp(readingIdleTimeoutMinutesMin, readingIdleTimeoutMinutesMax),
    );
    notifyListeners();
  }

  /// 小说阅读器阅读计时的开始方式（手动 / 打开即开始 / 翻页后开始），默认打开即
  /// 开始。普通偏好（随 Profile 快照）；下次打开书生效。
  ReaderStudyClockStartMode get readerStudyClockStartMode =>
      ReaderStudyClockStartMode.parse(
          getPref(kReaderStudyClockStartModePrefKey) as String?);

  Future<void> setReaderStudyClockStartMode(
      ReaderStudyClockStartMode mode) async {
    await setPref(kReaderStudyClockStartModePrefKey, mode.storageValue);
    notifyListeners();
  }

  /// 统计「今日」重置时刻（整点 0..23，默认 0 = 本地午夜）：写入时把 dateKey 前移
  /// 该小时数（凌晨 2 点读的书在重置 = 4 时记到「昨日」）。全局唯一入口是
  /// [FushiDatabase.statDayResetHour]，AppModel 在偏好加载后与变更时镜像过去；
  /// 历史段不重分桶（用户改设置只影响之后写入）。
  static const int statDayResetHourMin = 0;
  static const int statDayResetHourMax = 23;

  int get statDayResetHour =>
      (getPref(kStatDayResetHourPrefKey, defaultValue: 0) as int).clamp(
        statDayResetHourMin,
        statDayResetHourMax,
      );

  Future<void> setStatDayResetHour(int value) async {
    await setPref(
      kStatDayResetHourPrefKey,
      value.clamp(statDayResetHourMin, statDayResetHourMax),
    );
    notifyListeners();
  }

  int get readingGoalDailyChars =>
      (getPref('reading_goal_daily_chars', defaultValue: 0) as int)
          .clamp(0, 1000000);

  Future<void> setReadingGoalDailyChars(int value) async {
    await setPref('reading_goal_daily_chars', value.clamp(0, 1000000));
    notifyListeners();
  }
}

/// [AiKeyHealthStore] 的偏好表实现（[PreferencesRepository.loadFromDb] 装配）。
/// 读走偏好缓存（同步，请求热路径上不等 IO）；更新在缓存里同步生效、后台按条
/// 合并落库（见 [PreferencesRepository.updateAiKeyHealth]），失败只记日志——
/// 丢一次冷却记录只等于那把 key 下次照常再试，不该打断这次 AI 请求。
class _PrefsAiKeyHealthStore implements AiKeyHealthStore {
  _PrefsAiKeyHealthStore(this._prefs);

  final PreferencesRepository _prefs;

  @override
  AiKeyHealth? read(String fingerprint) => _prefs.aiKeyHealth[fingerprint];

  @override
  void update(String fingerprint, AiKeyHealthUpdate update) {
    _prefs.updateAiKeyHealth(fingerprint, update).catchError(
          (Object e, StackTrace stack) => ErrorLogService.instance
              .log('PreferencesRepository.updateAiKeyHealth', e, stack),
        );
  }
}

/// 随机 UUID v4（usage stats 安装身份的本地回退种子）。
String _randomUuidV4() {
  final Random rng = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  String group(int start, int end) =>
      bytes.sublist(start, end).map(hex).join();
  return '${group(0, 4)}-${group(4, 6)}-${group(6, 8)}-${group(8, 10)}-${group(10, 16)}';
}
