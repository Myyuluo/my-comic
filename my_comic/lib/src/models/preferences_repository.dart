import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:material_ui/material_ui.dart';
import 'package:my_comic_core/my_comic_core.dart';

import 'package:my_comic/src/utils/adaptive/nav_bar_style.dart';


import 'package:my_comic/src/media/discovery/opds_server_config.dart';
import 'package:my_comic/src/models/module_id.dart';
import 'package:my_comic/src/media/manga/mihon/mihon_cover_cache.dart'
    show
        kMangaCoverCacheDefaultMaxAgeDays,
        kMangaCoverCacheMaxDays,
        kMangaCoverCacheMinDays;

















import 'package:my_comic/src/reader/reader_control_layout.dart';










// 迁移判据要用「这个存量代理地址归一得出来吗」，与 applyAppProxy 同一份实现，
// 不在这里重写一遍（重写就会漂移，而漂移的后果是存量用户升级即断网）。
import 'package:my_comic_engine/utils/net/app_proxy.dart'
    show
        appUserProxyModeReader,
        appUserProxyPasswordReader,
        appUserProxyReader,
        appUserProxyUsernameReader,
        kProxyModeAuto,
        kProxyModeDirect,
        kProxyModeManual,
        normalizeUserProxyHostPort;
import 'package:my_comic/src/utils/misc/error_log_service.dart';
import 'package:my_comic/src/utils/misc/update_check_cache.dart';
import 'package:my_comic/src/media/manga/manga_view_prefs.dart';
import 'package:my_comic/src/media/manga/library/manga_resume_point.dart';
import 'package:my_comic/src/media/manga/manga_reader_preferences.dart';
import 'package:my_comic/src/media/manga/manga_reading_mode.dart';
import 'package:my_comic_engine/foundation/pref_store.dart';
import 'package:my_comic_engine/updates/update_feed_kind.dart'
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

/// 「保存为CBZ压缩包」：开启时新开始的在线章节下载写成
/// `downloads/{source}/{manga}/{chapter}.cbz`，关闭时沿用文件夹载体。
/// 默认 true（新安装与升级后的存量用户都开启）；只在任务开始运行时读取，
/// 已有章节不转换。见 `MangaDownloadService`。
const String kDownloadSaveAsCbzPrefKey = 'download_save_as_cbz';

/// bool（默认 true）：「本地图源」伪源是否启用。只控制图源列表里这一行的可进入
/// 状态；关闭不停止磁盘扫描，也不隐藏已登记作品。见
/// `PreferencesRepository.localSourceEnabled`。
const String kLocalSourceEnabledPrefKey = 'local_source_enabled';

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

class PreferencesRepository extends ChangeNotifier implements PrefStore {
  PreferencesRepository(this._db);

  /// TODO-855: persisted monotonic counter, the cross-process change signal the
  /// separate :popup process reads via [readPrefsVersionFromDb] to decide
  /// whether to reload its warm-reuse pref cache, instead of unconditionally
  /// re-scanning the whole preferences table on every lookup. The bump itself
  /// lives at the single lowest write choke point [MyComicDatabase.setPref], so
  /// EVERY writer (this repository, ThemeNotifier, MediaSource, profile switch,
  /// sync/backup restore) advances it automatically. This is an alias to that
  /// DB-layer key so app-layer call sites (ProfileKeys, tests) share one truth.
  /// Excluded from profile snapshots (see ProfileKeys) so it stays app-global
  /// and monotonic.
  static const String prefsVersionKey = MyComicDatabase.prefsVersionKey;

  final MyComicDatabase _db;
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
    // [MyComicDatabase.setPref] also bumps the persisted prefs-version (TODO-855)
    // for any key other than the version key itself; no explicit bump needed
    // here. The in-memory [prefsVersion] getter intentionally does NOT track
    // that same-process bump — change detection is cross-process and goes
    // through [readPrefsVersionFromDb] / a full [loadFromDb] reload.
    await _db.setPref(key, strVal);
  }

  /// 一个**逻辑设置**由多个 key 承载时（三态投影成两个 bool 键、值 + 判别键……）的写入
  /// 入口：全部 key 一次性进内存缓存、再走 [MyComicDatabase.setPrefs] 的**单事务**落盘。
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

  // ── 实验性：键盘/手柄焦点导航 ──────────────────────────────────────────
  // 整套自定义焦点导航（MyComicFocusRoot/Ring + 手柄/方向键焦点移动）默认关闭，
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
  // window.__myComicPopupInstantScroll{Wheel,Touch}Step；扩展经 theme
  // --mycomic-instant-scroll-wheel-step，触摸半边扩展侧不挂所以不下发）。
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
  // window.__myComicPopupWheelSpeed；浏览器扩展弹窗经查词响应 theme 的 --mycomic-wheel-speed 下发。
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
  /// 兼容保留：旧安装的 SRS 挖词目标出厂默认判定键。
  static const String srsMiningTargetInstallDefaultKey =
      'srs_mining_target_install_default';

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

  // ── reader chrome ────────────────────────────────────────────────────

  ReaderControlLayout get readerControlLayout => ReaderControlLayout.decode(
        getPref('reader_control_layout', defaultValue: '') as String,
      );

  Future<void> setReaderControlLayout(ReaderControlLayout layout) async {
    await setPref('reader_control_layout', layout.encode());
    notifyListeners();
  }

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

  /// 无痕阅读（默认 false = 记录 History）。
  bool get incognitoReading =>
      getPref(kIncognitoReadingPrefKey, defaultValue: false) as bool;

  Future<void> setIncognitoReading(bool value) async {
    await setPref(kIncognitoReadingPrefKey, value);
  }

  String get readerToolbarStyle {
    final String v =
        getPref('reader_toolbar_style', defaultValue: 'floating') as String;
    return v == 'docked' ? 'docked' : 'floating';
  }

  Future<void> setReaderToolbarStyle(String style) async {
    await setPref(
      'reader_toolbar_style',
      style == 'docked' ? 'docked' : 'floating',
    );
    notifyListeners();
  }

  static const String readerToolbarStyleFloatingMigratedKey =
      'reader_toolbar_style_floating_migrated';

  Future<void> _settlePrefAcrossProfiles(
    String key,
    Object value,
    String markerKey,
  ) async {
    if (getPref(markerKey, defaultValue: false) == true) {
      return;
    }
    await _db.customStatement(
      'UPDATE profile_settings SET value = ? WHERE category = ? AND key = ?',
      <Object>[PrefCodec.encode(value), 'pref', key],
    );
    await setPrefs(<String, dynamic>{key: value, markerKey: true});
  }

  Future<void> settleReaderToolbarStyleFloating() =>
      _settlePrefAcrossProfiles(
        'reader_toolbar_style',
        'floating',
        readerToolbarStyleFloatingMigratedKey,
      );

  static const String updatesNotifyMangaChapterDefaultOffMigratedKey =
      'updates_notify_manga_chapter_default_off_migrated';

  Future<void> settleUpdatesNotifyMangaChapterDefaultOff() =>
      _settlePrefAcrossProfiles(
        UpdateFeedKind.mangaChapter.enabledPrefKey,
        false,
        updatesNotifyMangaChapterDefaultOffMigratedKey,
      );

  /// 「功能模块」的用户排序（底栏 / 侧栏 tab 顺序）。与开关同为设备本地键
  /// （[ModuleId.devicePrefKeys]）；缺省空 = 枚举顺序。
  List<ModuleId> get moduleOrder => ModuleId.parseOrder(
        getPref(ModuleId.orderPrefKey, defaultValue: '') as String,
      );

  Future<void> setModuleOrder(List<ModuleId> order) async {
    await setPref(ModuleId.orderPrefKey, ModuleId.encodeOrder(order));
    notifyListeners();
  }

  /// 三步漫画版新手引导完成标志。缺省值 **false**：全新安装默认未完成。
  ///
  /// 已经有数据的用户不被打扰靠 `first_time_setup`：旧版本的 HomePage 首帧早已
  /// 把它写成 false，而 `onboarding_completed` 的显示门控要求两者同时满足
  /// （见 `src/onboarding/onboarding_steps.dart` 的 `shouldShowOnboarding`）。
  /// 备份合并的 insert-if-absent 天然不会覆盖本键（描述本库自身状态，同
  /// `first_time_setup`）。
  bool get onboardingCompleted =>
      getPref('onboarding_completed', defaultValue: false) as bool;

  /// 完成 / 跳过引导：`onboarding_completed=true`，同时把 `first_time_setup`
  /// 落为 false。
  ///
  /// 两个标记同一次 `setPrefs` 事务写入：完成即重启的场景下，不能出现「重启先
  /// 发生、其中一半还没落盘」的窗口，否则新装用户下次启动会被再弹一次。
  Future<void> setOnboardingCompleted({required bool value}) async {
    await setPrefs(<String, dynamic>{
      'onboarding_completed': value,
      if (value) 'first_time_setup': false,
    });
  }

  final int defaultMaximumDictionaryTermsInResult = 10;

  int get maximumTerms => getPref('maximum_terms',
      defaultValue: defaultMaximumDictionaryTermsInResult) as int;

  void setMaximumTerms(int value) async {
    await setPref('maximum_terms', value);
    notifyListeners();
  }

  /// 「下载」改名「浏览」的一次性搬迁提示是否已处理。
  bool get browseMovedNoticeHandled =>
      getPref('browse_moved_notice_handled', defaultValue: false) as bool;

  Future<void> setBrowseMovedNoticeHandled() async {
    await setPref('browse_moved_notice_handled', true);
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

  /// 一键制卡的卡图默认裁到所在分镜（只在分镜模型可用且非条漫时生效）。
  bool get mangaMiningCropToPanel => getPref(
        'manga_mining_crop_to_panel',
        defaultValue: kMangaMiningCropToPanelDefault,
      ) as bool;

  Future<void> setMangaMiningCropToPanel(bool value) async {
    await setPref('manga_mining_crop_to_panel', value);
    notifyListeners();
  }

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

  /// 内置「本地图源」是否启用（默认开）。它是图源列表里的伪源，不是
  /// `manga_online_sources` 行；开关只影响这一行的可进入状态，不影响磁盘扫描。
  bool get localSourceEnabled =>
      getPref(kLocalSourceEnabledPrefKey, defaultValue: true) as bool;

  Future<void> setLocalSourceEnabled(bool value) async {
    await setPref(kLocalSourceEnabledPrefKey, value);
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

  /// 「保存为CBZ压缩包」开关（默认 true）。下载服务在任务**开始运行时**现读本值：
  /// 排队任务按真正开始那一刻的格式落盘，运行中的任务保持开始时的格式。
  bool get downloadSaveAsCbz =>
      getPref(kDownloadSaveAsCbzPrefKey, defaultValue: true) as bool;

  Future<void> setDownloadSaveAsCbz(bool value) async {
    await setPref(kDownloadSaveAsCbzPrefKey, value);
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

  // ── low memory mode (raw pref only; side effect in AppModel) ─────────

  bool get lowMemoryMode =>
      getPref('low_memory_mode', defaultValue: false) as bool;

}
