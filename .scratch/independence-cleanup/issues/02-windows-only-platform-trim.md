# 02: Windows-only 平台裁剪

**What to build:** 把项目收窄为 Windows-only：删除 Android/iOS/macOS/Linux/Web 平台目录、打包配置、平台专用 Dart 分支/依赖/测试和对应 CI，只保留 Windows runner、Inno Setup、JVM sidecar 与 Windows 构建链。

**Blocked by:** 01

**Status:** resolved

- [x] 删除 `android/`、`ios/`、`macos/`、`linux/`、`web/` 平台目录与 apple 共享平台代码。
- [x] 删除仅移动端/非 Windows 使用的依赖、条件分支、platform channel 常量和测试；保留 Windows 需要的分支，并把剩余平台判断简化为 Windows-only。
- [x] 删除 Android release、macOS/iOS desktop release、multiplatform 非 Windows job、linux-server job；保留 Windows analyze/test/golden/debug/release/installer workflow。
- [x] 更新构建脚本、CI 和产物路径中的平台枚举；不删除 Windows 安装器。
- [x] 保留 JVM sidecar、Extension runtime、Windows WebView2 与 Windows 原生通道。
- [x] 不删除 `fushi_server` 或非漫画 workspace 包（由 03 处理）。
- [x] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；CI 只枚举 Windows。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。平台删除后，相关 README/文档中的平台表由 11 统一重写。

## Implementation notes (2026-11-12)

### 已删除的平台目标

- `fushi/android`、`fushi/ios`、`fushi/macos`、`fushi/linux`、`fushi/web`、`fushi/apple`（含 Runner / 打包配置 / 平台插件注册）。
- `packages/flutter_inappwebview_linux`（Linux WPE WebView）与 `packages/gamepads_android_stub`（Android 手柄 no-op stub），同时从根 pubspec 的 `workspace` 移除。
- `native/fushi_ios_umbrella`（iOS 静态库打包）。
- `fushi/flutter_native_splash.yaml`（移动端启动图配置）。
- 平台 Dart 实现：`lib/src/platform/android/*`（5 个 service）、`lib/src/platform/ios/*`（6 个文件）、`lib/src/platform/mobile/android_picture_in_picture.dart`、`lib/src/startup/android_view_lifecycle.dart`、`lib/src/platform/desktop/linux_external_open_channel.dart`。
- `main.dart` 的 Android/iOS/macOS 启动分支：Android launcher icon 恢复、`receive_intent` 初始/后续 intent、`FlutterLogs` 移动端日志、移动端 splash/朝向、Android 生命周期、iOS URL 事件订阅、macOS `WindowManipulator` 初始化、macOS 原生 shell（`MacosWindow`/`MacosTheme`）、macOS `AppLifecycleListener` 退出落点。桌面启动分支统一为 `Platform.isWindows`。
- `PlatformServices` 只保留 desktop service bundle；Android/iOS 的实现与 `androidClipboard` 接线删除。
- 下载保活：Android 前台服务实现删除，`createDownloadKeepAlive()` 恒返回 `NoopDownloadKeepAlive`；`FushiChannels.downloadKeepAlive` / `splash`-only mobile channel 常量按引用情况清理。
- 测试：`fushi/test/android`、`fushi/test/ios`、`fushi/test/macos` 目录；移动端/Apple 平台契约测试（Android PiP / SAF / intent / MainActivity、iOS Info.plist / import staging、macOS shell / fullscreen / entitlements / restart / TTS Linux、Apple 签名 / TestFlight、platform-specific integration tests 等），共 71 个 `test/` 文件 + 33 个 `integration_test/` 文件。
- 依赖：`receive_intent`、`flutter_logs`、`restart_app`、`permission_handler`、`flutter_native_splash`、`permission_handler_platform_interface`、`flutter_inappwebview_linux`；根 pubspec 的 `flutter_inappwebview_android` / `permission_handler_windows` override。
- 构建/发布脚本：`script/build_and_run.sh`（macOS）、`tool/notarize_submit.sh`、`tool/apple_signing_secrets.sh`；`tool/check_release_policy.ps1` 重写为 Windows-only，`tool/publish_update_manifest.sh` 的镜像资产白名单改为仅 Windows 安装包并移除对 `mirror-releases.yml` 的 dispatch，`tool/gen_dev_activity_svg.py` 改读 `release-desktop.yml`。
- CI：删除 `release.yml`（Android release）、`release-server.yml`、`mirror-releases.yml`、`ffmpeg-kit-mobile.yml`；`build-multiplatform.yml` 只保留 `changes`、`nightly-develop`、`windows`；`release-desktop.yml` 只保留 `windows` 与 `publish`；`native-cache-warm.yml` 只保留 `changes` 与 `windows`；`main.yml` 重写为 Windows analyze + package tests + 4 分片全量单测（并生成 `strings.g.dart`）；`supersede-develop-releases.yml` 不再点名已删除 workflow；`ci-config-gate.yml` 的守卫枚举下界按裁剪后的实测值调整。

### 保留 / 推迟到后续 ticket

- `fushi_server`、`fushi_cli`、`fushi_engine` 等非漫画 workspace 包与 server-gate workflow 未动（ticket 03）。
- JVM sidecar（`tool/mihon`、`native/.../build_desktop_runtime`）、Extension runtime、Windows WebView2、Windows 原生 channel / runner 保持原样。
- `third_party/` 与 `ci/patches/` 未修改；其中 Android/permission handler 相关 vendored 目录不再被引用，留给后续清理。
- 以下平台分支/依赖仍被 03-05 将删除的非漫画代码引用，本 ticket 只做了不破坏 Windows 编译的最小简化，未删除：
  - `macos_ui` 驱动的标题栏 / 自适应 UI（`fushi_desktop_title_bar.dart`、`global_navigation.dart`、`window_caption_channel.dart`、`macos_traffic_lights.dart`、`macos_fullscreen_state.dart`、`adaptive_*`）——保留 Fushi UI shell，避免在 03-05 前改动视觉。
  - `app_shortcuts.dart`（移动端 launcher shortcuts）与 `source_url_channel.dart`（macOS source links）仍被 `main.dart` 深链装配引用。
  - `image_picker`（creator/camera）、`external_path`（migration 页）、`flutter_exit_app`（sync 设置）、`device_info_plus`（feedback/updater）等移动端优先依赖仍被待删功能使用。
  - Anki / 词典 / 听书 / 反馈 / 同步 / popup dictionary / TTS 的测试中仍有读取已删除平台目录的守卫，由 03-05 删除对应功能时一并删除。
  - `native-*-gate.yml`、`ffmpeg-min.yml`、`server-gate.yml`、leaderboard/feedback 等非平台构建 workflow 未动，归 03-05。

### 验证

- `cd fushi && dart run slang`：通过。
- `flutter analyze`：0 errors；308 issues（303 warnings + 5 infos），与 ticket 01 基线完全一致。本 ticket 新增/修改文件无 analyze error。
- 相关测试（`flutter test --no-pub`）：
  - 通过：`test/tools/flutter_test_failure_workflow_guard_test.dart`、`test/tools/update_manifest_product_split_test.dart`、`test/tools/update_manifest_publish_race_test.dart`（需要真实 `python3`；本机 WindowsApps `python3` stub 退出 49，用 PATH 中的真实 Python 3 复跑通过）、`test/feedback/feedback_fix_progress_test.dart`、`test/integration/comprehensive_test_matrix_test.dart`、`test/dictionary/native_test_harness_guard_test.dart`、`test/platform/download_keep_alive_hub_test.dart`、`test/tools/dart_source_no_raw_nul_guard_test.dart`、`test/windows`（3 个文件）、`test/tools/powershell_51_compat_guard_test.dart`、`test/tools/test_file_shards_test.dart`。
  - 既有失败（与本 ticket 无关，ticket 01 已记录全量套件并非全绿）：`test/tools/test_source_path_exists_guard_test.dart`（video/game 页面路径已在漫画-only 裁剪中删除）、`test/tools/pre_push_selection_test.dart`（`test/build/prerelease_only_capability_guard_test.dart` 等已迁移/删除）、`test/tools/tests_for_changes_guard_test.dart`（被替掉的 9 条手写规则中有 4 条测试已在更早的裁剪中删除）。
- `flutter build windows --debug --no-pub`：通过（257.2s，产出 `build/windows/x64/runner/Debug/fushi.exe`）。本机 NuGet 从 ticket 01 的缓存路径注入（PATH + `MYCOMIC_NUGET`），未改仓库配置。
- CI 平台枚举：`build-multiplatform.yml` 只剩 `windows` job；`release-desktop.yml` 只剩 `windows` + `publish`（仅下载/发布 Windows 安装包）；`main.yml` 为 Windows analyze/test；`golden-tests.yml` 为 Windows；workflow YAML 全部通过 `package:yaml` 解析。
