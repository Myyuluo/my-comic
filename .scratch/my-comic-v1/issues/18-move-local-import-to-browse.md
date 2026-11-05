# 18: 把 Local import 从漫画搬到浏览

**What to build:** 漫画 tab 只保留书架；发现 / 在线源 / 导入从漫画 tab 移除。浏览 tab 的页签顺序改为 在线源 → 发现 → 导入 → 下载，打开浏览默认落在在线源。浏览 › 导入复用现有本地导入页的全部内容（快速导入、常驻扫描根、互联对端），不显示重复的页内「来源管理」标题；导入页签跟随浏览页显示。空书架保留现有提示，移除「去导入」按钮。完成后用户可以从浏览完成本地导入，漫画 tab 只剩书架。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 漫画 tab 不再显示发现 / 在线源 / 导入，只剩书架。
- [x] 浏览页签顺序为 在线源 → 发现 → 导入 → 下载，打开浏览默认落在在线源。
- [x] 浏览 › 导入可以使用快速导入、常驻扫描根和互联对端；没有重复的页内标题。
- [x] 导入页签只在浏览页可见时出现。
- [x] 空书架只显示现有提示，没有「去导入」按钮。
- [x] 受影响的现有守卫测试已更新；构建与测试通过。

## Comments

- 2026-11-05 实现完成并提交：`e4f3461c`（菜单搬迁主体）+ `117603f4`（单视图顶栏回归修复）。
- 漫画页只保留书架；浏览页签 在线源 → 发现 → 导入 → 下载，默认落在在线源；浏览 › 导入复用本地导入页并隐藏重复页内标题。
- 回归修复：单视图 `MediaLibraryShell` 原本走不画浮动工具栏的快捷分支，导致「漫画」标题 / 书架页签 / 右上角动作消失；新增 `alwaysShowChrome`，漫画页单视图仍画完整顶栏。用户已在本机确认恢复。
- 测试：`manga_library_page_split_test`、`media_library_shell_test`、`downloads_center_contract_guard_test`、`import_page_unification_guard_test`、`manga_sources_view_composition_test` 等定向测试通过；`flutter build windows --release` 成功。全量套件在本机有大量既存失败，未作为门禁。
