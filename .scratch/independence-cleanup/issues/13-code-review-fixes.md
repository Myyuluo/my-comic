# 13: 独立化清理的代码评审修复

**What to build:** 修复 Standards + Spec 评审（`567abf04...dfa94bcd`）确认的遗留项：Windows-only 残留、非漫画原生面、依赖与死代码、扫描器门禁、stale 文档/路径、安装器验收。

**Blocked by:** 12

**Status:** resolved

## 修复范围

### A. Windows-only / ADR 0024

- 删除 macOS-only Dart：`macos_traffic_lights.dart`、`my_comic_macos_theme.dart`、`macos_fullscreen_state.dart`。
- 删除 `macos_ui` 依赖、`MacosScaffold` 分支、macOS 原生侧栏/交通灯/全屏 delegate、`MyComicDesignSystem.macos` 及其分支。
- `real_path_directory_picker.dart` 收敛为 Windows 桌面：删除 Android SAF / iOS security-scoped / 权限申请 / staging 拷贝分支。
- 删除 `integration_test/ffmpeg_selfbuilt_smoke_test.dart`。
- 删除非 Windows CI：`native-torrent-gate.yml`、`ffmpeg-min.yml`、`native-galgame-gate.yml`；`main.yml` 去掉 `my_comic_torrent` 跳过项。

### B. 非漫画原生面

- 删除 `native/galgame_hook` 整树（523 个文件）。
- Windows runner 只保留漫画必需面：窗口/标题栏、单实例、字体、IME、剪贴板图片、WebView2 插件、更新 launcher。删除屏幕 OCR、悬浮球/字幕、外部视频、HDR 视频、galgame 字符浮层、全局查词、窗口捕获/录制、游戏串流、音频回环、voice hook 的 C++ 与 CMake/test 入口。
- 删除 `tools/build_magpie_slim.ps1`、`tool/ffmpeg-min`、`third_party/ffmpeg-min`。
- `release-desktop.yml` / `build-multiplatform.yml` 删除 galgame helper、Magpie、ffmpeg-min 的构建/打包/签名提及；`native-store-names` 只保留 Mihon runtime。
- 安装器删除视频关联、epub/pdf/txt 关联、`MyComic.Video` ProgId、voice_hook/galgame helper 安装与删除块；保留 cbz/cbr/cb7/mokuro 漫画归档关联。

### C. 依赖、元数据与死代码

- `my_comic/pubspec.yaml` description 改为 Windows 漫画阅读器。
- 删除零引用依赖：`google_sign_in`、`extension_google_sign_in_as_googleapis_auth`、`googleapis`、`googleapis_auth`、`youtube_explode_dart`、`flutter_webrtc`、`bonsoir`、`workmanager`、`mobile_scanner`、`qr_flutter`、`ftpconnect`、`dartssh2`、`ffmpeg_kit_flutter`、`flutter_exit_app`、`external_path`、`macos_ui`、`basic_utils`、`carousel_slider`、`change_notifier_builder`、`characters`、`clipboard`、`cupertino_icons`、`crop_image`、`external_app_launcher`、`float_column`、`multi_value_listenable_builder`、`progress_indicators`、`sliver_tools`、`visibility_detector`、`web_socket_channel`、`flutter_html`、`html_unescape`、`flutter_staggered_grid_view`；同步删除根 `dependency_overrides` 中的死条目并重新生成 lock。
- 删除死查词代码 `reader_selection_scripts.dart`、`lookup/sentence_extraction.dart` 及对应测试/JS fixture。
- 删除 HomePage 死同步退出 UI（`HomeSyncExitScope`、`_SyncExitWarningDialog`、`shouldWarnOnExit`）。
- 删除死 TMDB 署名行、常量、i18n key 与 `tmdb_attribution_test.dart`。
- 简化 `provide-baked-secrets` 为只注入日志上传端点/token；删除 google/dandanplay/TMDB/OpenSubtitles 桩与脚本。

### D. 扫描器门禁与字符串

- `main.yml` 新增 `audit-scanners` job：`fushi_references.dart --fail-on-violations` + `unused_l10n_keys.dart --fail-if-unused`。
- `my_comic/tool/pre_push_check.dart` 同样运行两个扫描器。
- 删除清理后无引用的 l10n key（OCR、同步退出、TMDB、模块设置等）；`settings_destination_manga_summary` 改为漫画-only 文案；删除 `storage_category_ocr_models` 类目与文案；四种语言同步并重新 `dart run slang`。
- CLI `kLibraryKinds` 只保留 `manga`；`kLibrarySourceKinds` 只保留 `manga`；`CtlOpenKind` 只保留 `sourceUrl`；删除 CTL 查词命令/端点。
- 扫描器 allowlist 增加 CI / pre-push 门禁自身的豁免（仅门禁调用行）。

### E. Stale 文档、路径与元数据

- 更新 `packages/my_comic_core/CLAUDE.md`（schemaVersion=5、99 张表、测试路径）与 `packages/my_comic_platform/CLAUDE.md`（当前服务接口）。
- `ci/integration-test.sh` 目标清单收缩到仍存在的测试；删除 `ci/anki-integration-test.sh`、`ci/lib/provision-ankidroid.sh`、`integration_test/support/fake_ankimobile/`。
- 删除机器专属 `启动MyComic最新版.bat`；保留仓库相对路径的 `启动MyComic.bat`。
- 修正 `settings_schema_system.dart` 中首页 dashboard/四个工具栏入口的过时注释。
- `tests_for_changes` 仓库根判据从 `native/` 改为 `packages/`；更新相关守卫下界与合成语料。
- `check_release_policy.ps1` 删除 galgame/Magpie 必备项，改为禁止这些非漫画产物回归。

### F. Scope-creep 说明

见 ticket 12 的「Scope-creep 说明：上游 bug 工具链」：`docs/bugs` 删除后 `tool/bug.dart` / `bug-number-settle.yml` 变为死工具，ticket 12 删除它们是**有意清理**。

### G. 安装器验收

- 本机无 ISCC；尝试 `winget install JRSoftware.InnoSetup` 两次均失败（下载 `github.com/jrsoftware/issrc/.../innosetup-6.7.3.exe`，错误 `0x80072ee2` / `0x80072efd`），`curl https://github.com` 超时。未获得 ISCC，未编译安装包；安装器静态守卫保持并全部通过。

## 验证

- `flutter analyze`（my_comic）：**0 error**，142 warnings/info（低于清理前 156）。
- `dart analyze`：cli / engine / platform 0 issue；core 9 条既有 info。
- CLI 包测试：79 passed。core 59、engine 86、platform 1，全部通过。
- 全量 app 测试（`flutter test --no-pub --concurrency=4 --exclude-tags golden`）：
  **6725 passed / 9 failed / 10 skipped**（923 suites）。9 条失败全部是
  `update_manifest_publish_race_test` 的 python3 环境失败；ticket 12 已记录。
  默认高并发跑时另有若干并发/30s 超时导致的守卫假红，均已单独复跑通过。
- Windows golden：38 passed。
- `flutter build windows --debug --no-pub`：通过（28.1s 增量），产物
  `build/windows/x64/runner/Debug/MyComic.exe`；冷启动冒烟 `alive=True title=MyComic`。
- `flutter build windows --release --no-pub`：通过（232.1s），产物
  `build/windows/x64/runner/Release/MyComic.exe`；冷启动冒烟 `alive=True title=MyComic`。
- Fushi 扫描器（`--fail-on-violations`）：0 violations（4689 files）。
- 未使用 l10n 扫描器（`--fail-if-unused`）：0 unused。
- `tool/check_release_policy.ps1`：pass。
- 安装器生命周期静态守卫：10 passed；因无 ISCC，未实际编译安装包。
