# 02: 品牌图标与设置 GitHub 行指向 fork

**What to build:** 左侧导航栏顶部的品牌/猫猫图标点击改为打开 `https://github.com/Myyuluo/my-comic`，tooltip 说明打开 GitHub 仓库；设置里的 GitHub 行也改为同一 fork。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] `NavRailBrandButton` 的点击与键盘/手柄 Activate 都打开 `https://github.com/Myyuluo/my-comic`（默认浏览器），沿用现有外链 helper 的错误日志行为。
- [x] 品牌图标 tooltip 使用「在 GitHub 查看仓库」文案，不再是「访问官网」。
- [x] 设置 `system.github` 行打开同一 fork URL；`system.website` 的移除由 ticket 03 处理，不在此 ticket 重复。
- [x] 桌面展开/收起布局都能点击；不改变图标视觉与导航布局。
- [x] 更新 `nav_rail_brand_button_test`、`official_website_entry_test` 等相关断言。
- [x] 不改变其他外部链接（下载页、更新检查）的行为。

## Answer

Implemented in `9bbc6be7`, merged as `c30447ed`（无冲突）。`official_links.dart` 新增 `kMyComicRepositoryUrl = https://github.com/Myyuluo/my-comic` 与 `openMyComicRepository()`（沿用 `ErrorLogService` 记录、失败返回 false 不抛）；`NavRailBrandButton` 的 tap 与 ActivateIntent 共用该 helper，tooltip 改为 `t.options_github`；`system.github` 行同步指向 fork。`system.website`、下载页、更新检查与赞助页 URL 保持不变。

测试（fushi/，slang 重新生成后）：`nav_rail_brand_button_test`、`official_website_entry_test`、`app_icon_guard_test`、`settings_schema_coverage_test`、`settings_cli_action_coverage_test` 全部通过（+22）。`settings_schema_coverage_test` 输出的 `system/Enable debug log FAIL — no change observed` 为既有诊断行、测试整体仍 PASS，与本 ticket 无关；无新增基线失败。
