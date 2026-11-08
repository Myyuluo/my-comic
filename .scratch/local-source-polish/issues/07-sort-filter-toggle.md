# 07: 漫画页「排序与筛选」点击切换修复

**What to build:** 漫画书架页右上角的「排序与筛选」菜单：点击一次展开，再次点击同一按钮收起；点外部或 ESC 仍关闭；菜单内容与选项行为不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 第一次点击按钮展开菜单
- [x] 第二次点击同一按钮收起菜单（不再关了又开）
- [x] 点击菜单外部、按 ESC、选择排序/筛选项仍按原行为关闭
- [x] 标签菜单项保持原有的“不自动关闭”行为
- [x] Cupertino/legacy 工具栏路径与 MD3 浮动操作栏行为一致
- [x] widget 测试覆盖连续两次点击的展开/收起

## Answer

Implemented in `c4b7cf9f`, merged as `0c0efe71`. 排序按钮加入菜单 TapRegion，连续两次点击先开后关；点外部/ESC/选择项行为不变。
