# 01: 下载页标题与浏览页一致

**What to build:** 下载页的标题从固定展开的外壳大标题改为浏览页同款的页内浮动标题胶囊：不显示视图页签；鼠标向下滚动时标题随工具区隐藏，向上滚动或回到顶部时重新显示；列表初始从标题实测高度下方开始，首张任务卡片不被遮挡，标题隐藏后内容可继续上移。逐设计系统对齐浏览页：MD3 宽窗口显示标题胶囊，MD3 窄窗口不显示页面标题，Apple/玻璃设计使用外壳大标题的收起行为。任务列表、空态、展开详情与页面保活保持不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 下载页标题使用浏览页同款页内浮动标题胶囊，不显示视图页签。
- [x] 向下滚动隐藏标题，向上滚动或回到顶部重新显示；阈值与动画与浏览页一致。
- [x] 下载列表初始从标题下方开始，首张任务卡片完整可见；标题隐藏后内容继续上移，不留空白条。
- [x] MD3 窄窗口与浏览页一样不显示页面标题；Apple/玻璃设计使用外壳大标题的收起行为。
- [x] 任务列表、空态、展开详情、入口动画与保活行为保持不变。
- [x] 仅下载页标题行为变化，浏览页、书架、设置等其它页面不受影响。
- [x] ADR 0010、上一版 spec 与 GLOSSARY 中「标题固定展开」的旧决策已更新。
- [x] 相关测试已新增/更新，`flutter analyze` 与定向测试通过。

## Comments

- Implemented and merged into `integration/reading-behavior-and-privacy` at merge commit `1893f8ee` (dual-axis review fixes included).
- 上一版 gitignored spec 与 ticket 02 的标题描述已同步修正；下载页的 chrome 骨架与浏览页一起抽成了共享 host。
