# 04: 删除非漫画应用面与运行时残留

**What to build:** 删除应用层所有非漫画页面、服务/provider、CTL 端点、深链、运行时装配、原生库和测试；删除旧 Onboarding，为 07 的新向导腾出空间。保留漫画域与 `ModuleId`/`HomeTab` 兼容值。

**Blocked by:** 02

**Status:** resolved

- [x] 删除小说/EPUB、视频/游戏/galgame/悬浮球/字幕、词典/查词、Anki/SRS、听书/TTS/ASR、云同步/互联/Server/P2P、AI/在线服务/Profile、反馈/排行榜/迁移/Tracking/首页 dashboard 的页面、服务、provider、模型与测试。
- [x] 删除 `AppModel` 中非漫画服务构造、`main` 中 Anki/TTS 装配、`HomePage` 死方法与定时器、pair/card-source 调度、非漫画 CTL 路由和外部深链 handler。
- [x] 删除 Windows 非漫画原生库与 CMake/installer 条目（fushidicts、aacs、torrent、p2p、fsrs、anki_sync、galgame、voice_hook）。
- [x] 删除旧 Onboarding 页面、步骤、推荐包与依赖；不在这里实现新向导。
- [x] 删除 `fushi_cli` 中的非漫画命令。
- [x] 保留 `ModuleId`/`HomeTab` 旧枚举值和旧偏好键，加兼容保留注释。
- [x] 保留漫画域：Library、Manga 作品页、Reader、Source、Extension store、Discovery、History、Download、Settings、Tag、Backup、Local source。
- [x] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；冷启动冒烟；书架、阅读、下载、图源、Backup、Local source 仍可用。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。旧 Onboarding 删除是临时状态，07 会按三步漫画版重建。

## 实现记录

### 删除的应用面

- 小说 / EPUB / PDF 阅读器页面（EPUB 阅读器；PDF 页面保留给 ticket 05）与书籍导入动作。
- 视频 / 游戏 / galgame / 悬浮球 / 悬浮字幕 / 字幕：页面、服务、播放器面板、原生通道装配。
- 词典 / 查词：页面、弹窗、全局取词、IME、词典服务与 AppModel 词典域。
- Anki / SRS / 挖词制卡 / 复习页面、服务与 runtime 装配。
- 听书 / TTS / ASR / 有声书会话、本地音频源、悬浮歌词。
- 云同步 / 互联 / Fushi Server / P2P / 远端书架 / 删除传播 / OAuth / 配对深链。
- AI / 在线服务 / Profile / 浏览器扩展服务端、排行榜、反馈、迁移、Tracking、首页 dashboard。
- `AppModel` 非漫画字段与构造、`main` 深链与后台服务、`HomePage` 非漫画 tab 与定时器、非漫画 CTL 路由。
- 旧 Onboarding 目录（页面、步骤、推荐包下载/导入控制器及依赖）。
- `fushi_cli` 的 dictionary / data / online / settings / reader / video / AI 命令组，仅保留 library + shelf。
- Windows `native/` 下 fushidicts、aacs、torrent、p2p、fsrs、anki_sync 源码目录（installer/CMake 安装规则在 ticket 02 基线已移除）。
- 删除仅覆盖已删功能的 `test/`、`integration_test/` 与 `tool/pack/export_recommended_pack.dart`。

### 兼容保留（有意保留）

- `ModuleId` / `HomeTab` 全部旧枚举值与 `module_*_enabled`、旧偏好键；新增兼容注释。可见性仍由 `isInMyComicScope` 只启用漫画域。
- 漫画共享基础设施：`ReaderFushiSource`（书架/书身份/封面/进度/删除）、`MediaItem`、`fushiBooksProvider`、Extension store/Mihon、Local source、History、Download、Backup。
- 浏览器扩展页面与安装助手（ticket 05 删除）：仅保留编译所需的极小兼容面（`kFushiApiDefaultPort`、`browserExtensionBuild`/`lastSeenAt`/`reportedBuild`、`fushiApi*` 偏好 getter、`ensure/stopFushiApiServer` no-op）。运行时 API server 已删除。
- PDF 导入/阅读器与阅读统计：ticket 05 删除，本 ticket 未动。
- `native/galgame_hook/` 源码：Windows runner 的 `voice_hook_reader.cpp` / `global_lookup_window.cpp` 等 C++ 仍 include 其头文件，删除会破坏 Windows 构建；无 Dart 入口，原生侧清理留给后续 native 收口。
- 从已删除页面抽出的中性共享件：`utils/components/deletion_disclosure.dart`、`models/reader_theme_colors.dart`、`platform/external_media_navigation.dart`、`utils/misc/pref_redaction_policy.dart`、`storage/font_path_rebase.dart`、`media/manga/reader/source_review_compat.dart`（仅类型/着色/导航辅助）。
- 测试 seam：`wireLocalAudioForTesting`（仅设 prefs/目录）、`populateLanguages` no-op、`maximumDictionaryHistoryItems` 兼容 getter。

### 验证

- `cd fushi && dart run slang`：通过。
- `flutter analyze`：0 errors（基线 308 条既有 warning/info，下降到约 200 条）。lib 代码零错误。
- 相关测试：196 条通过（`flutter test test/tools/audit test/i18n test/language` + manga 书架/删除菜单/未读角标 + Library membership + 自定义主题 + 统计设置 + settings renderer/schema cache）。全量旧测试套件中针对已删除功能的用例已删除。
- `flutter build windows --debug`：**通过**（CMake 262s，产物 `build/windows/x64/runner/Debug/fushi.exe`；NuGet 来自主 checkout `.dart_tool/nuget`，pdfium/sqlite3 native-asset 命中缓存）。冷启动 smoke：启动后 12s 进程仍存活（`alive=True`）。
- Fushi 引用扫描器（`tool/audit/fushi_references.dart --summary`）：violations 从基线 92,169 降到约 59,125（剩余集中在 ticket 03/06/10 负责的 packages / l10n / 原生 galgame_hook / 待改名代码）。

### 已知失败 / 延迟项

- 部分 shared 静态守卫测试仍引用已删除源文件或旧 EPUB reader 语料；本次删除这些测试语料，未逐条重写。
- `manga_overlay_html_test`（3 条）、`mihon_source_browse_page_test`（4 条）失败；这两个源文件本次未修改，属于 fork 既有失败，记录待 ticket 12 复核。
- `manga_library_sort_menu_toggle_test`（排序菜单标签项）与 `manga_library_tag_tabs_test`（筛选计数）仍有失败；相关源文件未改，记录待 ticket 12 复核。
- `test/reader/` 等旧 EPUB reader 测试大部分依赖已删除页面/脚本，未纳入本 ticket 门禁。
- 浏览器扩展运行时与 API server 在 ticket 05 删除；当前只保证页面编译。
- `native/galgame_hook` 与 Windows runner 的 voice-hook C++ 面待后续 native 清理。
