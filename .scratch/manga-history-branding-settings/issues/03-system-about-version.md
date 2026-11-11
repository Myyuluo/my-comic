# 03: 系统与关于清理、版本 1.0.0 与更新源

**What to build:** 从「系统与关于 → 通用」移除启动页、访问官网、GitHub Sponsors 三行；应用版本改为 1.0.0 并精确显示；更新检查指向 `Myyuluo/my-comic`，没有可用 release 时按「已是最新」处理。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 删除 `appearance.startup_default_dictionary_tab` 设置行与只服务于它的私有 helper；保留 `AppModel.setStartupModule`、偏好键、启动页回退与迁移，现有启动行为不变。
- [ ] 删除 `system.website` 与 `system.github_sponsors` 行；确认无其他生产消费者后清理对应 URL/常量与 i18n key。「访问官网」不再出现在设置页。
- [ ] `fushi/pubspec.yaml` 版本改为 `1.0.0+1355`；设置页「应用版本」显示精确 `1.0.0`（不显示 `(1355)`）；更新相关 version formatter 与测试。
- [ ] 更新检查源改为 `Myyuluo/my-comic`；没有 release、404 或空结果时按「已是最新」处理，不报错、不回退到上游 3.x。
- [ ] 保留「更新提醒」分组与手动检查更新入口；保留 `system.github` 行（URL 由 ticket 02 改为 fork）。
- [ ] 清理不再使用的 i18n key（启动页/官网/Sponsors），全部 17 locale 同步；不手动逐文件编辑，用 `i18n_sync` 与 `dart run slang`。
- [ ] 更新 `startup_default_dictionary_tab_settings_test`、`official_website_entry_test`、`settings_schema_coverage_test`、`app_version_display_format_test`、`settings_renderer_test` 与相关 CLI/guard。
- [ ] 不改变设置页视觉风格（ADR 0008），不新增 schema/Backup 变更。
