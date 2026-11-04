# 16: 恢复 Fushi v3.0.0 原版 UI shell/设计

**What to build:** 恢复 Fushi v3.0.0 的原版 UI shell 和视觉设计，删除 ticket 11 引入的简化版 `home_shell.dart`。保留 Fushi 的 MacosScaffold/ToolBar/Sidebar/自定义标题栏/glass chrome/主题和漫画页面原有布局；只隐藏或移除非漫画入口。任何进一步的 UI 改动必须先获得用户明确许可。

**Blocked by:** None（can start immediately；ticket 11 已完成）

**Status:** ready-for-agent

- [ ] 恢复原版 `home_page.dart`（以 ticket 02 的 `ff3f2df0` 版本为起点，适配 37 表/已删除模块）
- [ ] 删除 `home_shell.dart`，根入口改回原版 shell
- [ ] 保留 Fushi 的 MacosScaffold/ToolBar/Sidebar/标题栏/glass chrome/主题
- [ ] 只隐藏/移除非漫画入口，不重设计漫画页面
- [ ] 恢复/适配 `home_page_tabs_test` 等外壳测试
- [ ] 与 Fushi v3.0.0 截图对照，用户明确批准 UI 后才合并
- [ ] `flutter build windows --release --no-pub` 成功；启动后 UI 与 Fushi 一致
