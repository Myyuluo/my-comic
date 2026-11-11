# 02: 品牌图标与设置 GitHub 行指向 fork

**What to build:** 左侧导航栏顶部的品牌/猫猫图标点击改为打开 `https://github.com/Myyuluo/my-comic`，tooltip 说明打开 GitHub 仓库；设置里的 GitHub 行也改为同一 fork。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] `NavRailBrandButton` 的点击与键盘/手柄 Activate 都打开 `https://github.com/Myyuluo/my-comic`（默认浏览器），沿用现有外链 helper 的错误日志行为。
- [ ] 品牌图标 tooltip 使用「在 GitHub 查看仓库」文案，不再是「访问官网」。
- [ ] 设置 `system.github` 行打开同一 fork URL；`system.website` 的移除由 ticket 03 处理，不在此 ticket 重复。
- [ ] 桌面展开/收起布局都能点击；不改变图标视觉与导航布局。
- [ ] 更新 `nav_rail_brand_button_test`、`official_website_entry_test` 等相关断言。
- [ ] 不改变其他外部链接（下载页、更新检查）的行为。
