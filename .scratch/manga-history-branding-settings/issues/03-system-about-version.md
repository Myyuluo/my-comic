# 03: 系统与关于清理、版本 1.0.0 与更新源

**What to build:** 从「系统与关于 → 通用」移除启动页、访问官网、GitHub Sponsors 三行；应用版本改为 1.0.0 并精确显示；更新检查指向 `Myyuluo/my-comic`，没有可用 release 时按「已是最新」处理。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 删除 `appearance.startup_default_dictionary_tab` 设置行与只服务于它的私有 helper；保留 `AppModel.setStartupModule`、偏好键、启动页回退与迁移，现有启动行为不变。
- [x] 删除 `system.website` 与 `system.github_sponsors` 行；确认无其他生产消费者后清理对应 URL/常量与 i18n key。「访问官网」不再出现在设置页。
- [x] `fushi/pubspec.yaml` 版本改为 `1.0.0+1355`；设置页「应用版本」显示精确 `1.0.0`（不显示 `(1355)`）；更新相关 version formatter 与测试。
- [x] 更新检查源改为 `Myyuluo/my-comic`；没有 release、404 或空结果时按「已是最新」处理，不报错、不回退到上游 3.x。
- [x] 保留「更新提醒」分组与手动检查更新入口；保留 `system.github` 行（URL 由 ticket 02 改为 fork）。
- [x] 清理不再使用的 i18n key（启动页/官网/Sponsors），全部 17 locale 同步；不手动逐文件编辑，用 `i18n_sync` 与 `dart run slang`。
- [x] 更新 `startup_default_dictionary_tab_settings_test`、`official_website_entry_test`、`settings_schema_coverage_test`、`app_version_display_format_test`、`settings_renderer_test` 与相关 CLI/guard。
- [x] 不改变设置页视觉风格（ADR 0008），不新增 schema/Backup 变更。

## Answer

Implemented in `89b998fe`, merged as `5b216752`（无冲突；ticket 分支已先合入 ticket 02 的 `6c3f501a`，ticket 04 缓存计量保持不变）。

`settings_schema_system.dart` 删除 `appearance.startup_default_dictionary_tab` 行及只服务于它的 `_startupModuleOptions` / `_startupModuleToken` / `_startupModuleOfToken` 私有 helper，保留 `AppModel.setStartupModule`、偏好键与启动回退；删除 `system.website` 与 `system.github_sponsors` 两行，`official_links.dart` 移除 `kGitHubSponsorsUrl`（官网下载页 URL 等仍保留），`system.github` 行继续指向 ticket 02 的 fork。`pubspec.yaml` 升到 `1.0.0+1355`；`formatAppVersionDisplay` 只显示精确版本名（`1.0.0`），不再拼 `(1355)`。`update_checker_release.dart` 的 `kGitHubRepo` 改为 `Myyuluo/my-comic`，回退链收敛为单一仓库；404 / 空 release 列表 / 无匹配通道走 `onUpToDate`（「已是最新」），不回退上游 3.x。17 个 locale 的 `options_github_sponsors`、`startup_module`、`startup_module_default`、`startup_module_hint` 已同步删除，并重新执行 `dart run slang`。

测试（`fushi/`，slang 重新生成后）：
- 通过：`startup_default_dictionary_tab_settings_test`、`official_website_entry_test`、`settings_schema_coverage_test`、`app_version_display_format_test`、`settings_renderer_test`（除下述 2 个既有失败）、`update_checker_manifest_test`、`update_checker_redirect_tag_test`、`update_checker_structure_guard_test`、`update_checker_release_selection_test`、`update_checker_404_reresolve_test`、`update_checker_all_releases_parse_test`、`update_checker_asset_version_test`、`nav_rail_brand_button_test`、`current_app_icon_test`、`app_icon_guard_test`；该批合计 +150。`test/i18n` 整套 +59 全部通过。附加 `manual_update_check_guard_test`、`update_settings_android_only_guard_test`、`update_notification_defaults_test`、`itest_settings_destination_identity_guard_test` 通过。
- 既有失败（与本次合并无关）：`settings_renderer_test.dart` 的 `lookup settings can edit the Yomitan API key` 与 `lookup settings exposes lookup audio volume slider` 因 `buildSettingsSchema` 已按 my-comic 漫画域裁剪（`ff3f2df0 feat(shell): restrict my-comic UI to manga-only domains`，早于本次合并）不再包含 `SettingsDestinationId.lookup`，测试内 `firstWhere` 抛 `Bad state: No element`；合并前后 schema 文件无差异、测试文件仅改动版本断言，属合并前既有失败。
- 既有失败（静态守卫，与本次合并无关）：`m3e_design_system_static_test.dart` 的 12 个用例扫描已随漫画域裁剪删除的非漫画源文件（如 `lib/src/pages/implementations/collections_page.dart`、`lib/src/media/video/*`、`assets/popup/popup.css`），抛 `PathNotFoundException`，非本 ticket 引入。
- 未改变设置页视觉风格，无新增 schema/Backup 变更（ADR 0008）。
