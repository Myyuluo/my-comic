# 09: 用户可见品牌与 Windows 身份

**What to build:** 把用户可见身份和 Windows 安装/运行身份改为 MyComic：窗口标题、通知、About、安装器、图标、快捷方式、CI 产物、Release/Issue 元数据和更新检查；保留 GPL 来源署名。

**Blocked by:** 08

**Status:** resolved

- [x] 窗口标题、任务栏、通知、错误日志、诊断信息和 About 中的应用名改为 MyComic。
- [x] 安装器：显示名、默认目录、程序组、桌面/开始菜单快捷方式、卸载图标、向导插画改为 MyComic；保持同一个 AppId GUID。
- [x] 应用图标、启动图、安装器图标与 Windows ico 使用 MyComic M 标识；移除旧 Fushi 图片资源引用。
- [x] About/版本页增加“基于 Fushi v3.0.0（GPL-3.0）”；版权行同时保留上游版权与 MyComic 版权。
- [x] 删除/替换 fushi.moe 反馈、排行榜、统计、User-Agent 等运营端点；更新检查只查 `Myyuluo/my-comic`。
- [x] 更新资产前缀值改为 `mycomic-`；CI 产物名改为 `mycomic-<版本>-windows-setup.exe`；不保留旧 `fushi-` 前缀兼容。
- [x] 更新 Windows 单实例窗口查找/互斥量/安装器进程清理，使其与新窗口标题和 exe 名一致。
- [x] 清理 GitHub FUNDING、Issue 模板、Release 标题中的上游指向；只保留 fork 仓库。
- [x] 验证：Inno 静态校验通过（本机无 ISCC，未实际编译）；冷启动冒烟窗口标题为 MyComic；About/通知/诊断文案为 MyComic；Fushi 用户可见文案只剩 allowlist。
- [x] 本 ticket 不做包名、目录、类名、channel 的整体重命名（由 10 处理）；必要时只改运行时值，符号名留给 10。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。干净切换：旧 `fushi://` 深链与旧 `fushi-` 更新资产不兼容。

## 实现记录（2026-11-12）

- Worktree: `e:/tmp/mycomic-wt/ticket-09`
- Branch: `ticket/09-user-visible-branding`（基于 `380fd9cb`）
- Toolchain: Flutter 3.47.6 / Dart 3.13.5（`D:/ProgramData/flutter_3.47.6`），Windows 10 Pro 19045
- Bootstrap：`pwsh` 不在 PATH，按 fallback 用 PowerShell 5.1；`FUSHI_FLUTTER` 在单次命令内覆盖为 `D:\ProgramData\flutter_3.47.6\bin\flutter.bat`。

### 用户可见身份

- Windows runner：主窗标题 `MyComic`（dev 并存 `MyComic Dev`），单实例 `FindWindowW` 标题、互斥量值与调试输出全部改为 `MyComicSingleInstanceMutex` / `MyComic`；热重启等待逻辑不变。
- 通知：`AppModel.systemNotifier` 的 `appName` 改为 `MyComic`。
- 错误 / 诊断：所有 `[Fushi]` 日志 tag 改为 `[MyComic]`；DB 打开/降级/旧 schema 异常、更新器用户文案改为 MyComic；分享/保存的日志文件名改为 `mycomic_error_log.txt` / `mycomic_debug_log.txt`；crash/hang/present watchdog 目录改为 `%LOCALAPPDATA%\MyComic\...`，并同步 WebView2 回退目录与 `.dmp` 定位测试。
- About：系统与关于 › 通用新增只读 `system.about` 行（`MyComic` + `about_based_on_fushi`），显示「基于 Fushi v3.0.0（GPL-3.0）」并同时保留 Fushi 贡献者与 MyComic 贡献者版权。四语言 key 通过 `tool/i18n_sync.dart --add/--set` 写入并 `dart run slang` 重新生成。
- 4 份 l10n 中所有用户可见 `Fushi` 值改为 `MyComic`；移除 `update_download_source_cloudflare`（无引用）。

### 更新、端点与资产

- User-Agent：`mycomic/<component> (https://github.com/Myyuluo/my-comic)`；更新下载 UA `MyComic/<version>`；Mihon 下载计数 UA `MyComic`。
- 官网/下载链接改为 fork：`https://github.com/Myyuluo/my-comic` 与 `/releases`。
- 删除上游官网 R2/Cloudflare 下载源：`officialR2UrlForUpdateAsset`、`_kOfficialUpdateMirrorHost`、`updateDownloadSourceCloudflare` 及 race/headless/test 相关分支；旧 `r2` 偏好安全回退自动顺序。更新候选只保留 GitHub 直连 + 公共 gh 代理。
- 更新资产前缀值 `kFushiAssetPrefix = 'mycomic-'`（常量名留给 ticket 10）；`synthesizeStableAssetNames` 与资产族判据同步。
- 删除已无消费者的反馈/排行榜运营端点：`services/leaderboard/`、`leaderboard-worker*.yml`、`feedback-link.yml`、`tool/feedback_link.mjs`、`tool/feedback_mark_released.sh`、`tool/r2_mirror_readiness.mjs`；release workflow 移除 feedback 回填步骤与触发路径。
- Release workflow：标题 `MyComic ...`；安装包 `mycomic-<version>-windows-setup.exe`；所有 glob / 签名 / 上传 / manifest `ASSET_GLOB` 同步。Issue 模板改为 Windows + 漫画域，只链接 fork；FUNDING 改为 `Myyuluo`。

### 安装器与图片

- 保持 `AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}` 不变，避免并存卸载项；`UsePreviousAppDir=no` 确保升级/重装也落在 `{localappdata}\MyComic`，不沿用旧 Fushi 目录。
- `AppName/AppPublisher/DefaultGroupName=MyComic`，`DefaultDirName={localappdata}\MyComic`，`OutputBaseFilename=mycomic-...`，`UninstallDisplayIcon` 继续使用带 M 图标的 exe。
- 快捷方式 / 程序组 / 启动项 / 可写性提示 / 捕获组件提示全部 MyComic；安装器同时清理旧 Fushi/Hibiki 快捷方式、程序组、`Fushi.Video` / `Fushi.Book` ProgId 与旧 `fushi` URL 协议键。
- 移除 `fushi://` URL protocol 注册（旧深链不兼容）；`MyComic.Video` / `MyComic.Book` 为可选「打开方式」候选。
- `AppMutex` 与 `[Code]` 同时识别 `MyComicSingleInstanceMutex`、旧 `FushiSingleInstanceMutex` 与 `HibikiSingleInstanceMutex`；进程清理识别 `mycomic.exe` / `fushi.exe` / `hibiki.exe`。
- Native 快捷方式图标同步改为桌面 `MyComic.lnk`、开始菜单 `Programs\MyComic\MyComic.lnk`、任务栏 `MyComic.lnk`。
- 安装器向导插画由 `generate_md3_assets.py` 用 `fushi/assets/meta/icon.png`（MyComic M 标记）重新生成；hero 文案 `MyComic`，不再有兔子 / Fushi 字样。`app_icon.ico` 与 splash/launcher 图标本身已是 M 标记，无需重画。
- 文档注明：干净切换，旧版本请先手动卸载；不迁移 Program state root，旧 `fushi://` 深链与旧 `fushi-` 更新资产不兼容。

### 验证

- `cd fushi && dart run slang`：通过（4 locale）。
- `flutter analyze --no-pub`：0 error（155 条既有 warning/info；基线 308，已随前序 ticket 降低）。
- 相关测试（全部通过，200 例）：新 `test/branding/user_visible_identity_test.dart`、`test/settings/about_attribution_test.dart`、Windows single-instance / shortcut 静态守卫、installer lifecycle、official links、outbound UA、资产前缀/正式命名、update checker manifest/selection/redirect/asset version/debug seq/version comparison/dialog/race/mirror fallback、crash dump/hang watchdog 路径、nav rail 品牌语义、i18n 排序与完整性、audit 扫描器。
- `flutter build windows --debug --no-pub`（NuGet 走 `e:/VibeCoding/ClaudeCode/MyComic/.dart_tool/nuget/nuget.exe`）：通过，243s。
- `flutter build windows --release --no-pub`：通过（首次构建通过；最终 native 文案/路径改动后增量重建 75.2s 再次通过）。
- 冷启动冒烟：启动 `build/windows/x64/runner/Debug/fushi.exe`，12s 后主窗标题为 `MyComic`，进程存活；随后结束，无工作树残留进程。
- exe 版本资源：`CompanyName/FileDescription/InternalName/ProductName=MyComic`，`LegalCopyright` 同时含 Fushi contributors 与 MyComic contributors（GPL-3.0）；`OriginalFilename=fushi.exe` 保留到 ticket 10。
- 安装器静态校验：AppId/AppName/DefaultDirName/Group/OutputBaseFilename/快捷方式/启动项/无 URL Protocol 全通过；18 个 wizard 资产与 3 个 `#include` 均存在。**本机没有 ISCC.exe（Inno Setup 未安装），未实际编译安装包**。
- Fushi 引用扫描器：用户可见文案只剩 allowlist 内的 About/README 来源署名与 exe 版权行；其余命中均为 ticket 10 负责的包/目录/类名/channel/环境变量/常量与 `fushi.exe`/`fushi.iss` 等机械命名。

### 已知 / 延后

- `BINARY_NAME=fushi.exe`、目录/包/类名/channel/环境变量/常量名、`fushi.iss` 文件名、manifest `-fushi` 后缀、rolling tag 仍按 ticket 10 处理。
- README/UPSTREAM/历史文档与仓库元数据（README 中的官网/上游链接、star/dev-activity 脚本默认仓库）按 ticket 11 处理。
- 既有失败（与本次改动无关）：`update_handoff_test` 的 "startup reconcile guard main schedules..."（main 中该调用点在更早 ticket 已移除）；`settings` 下 31 条引用已删除非漫画功能的静态/布局测试；`update_manifest_publish_race_test` 在本机因 `python3` 为 WindowsApps 存根而 exit 49；`fushi_cli` 的 22 条非漫画命令测试。ticket 12 需统一处置。
