# 06: 标签移到视图页签位置并更新术语表

**What to build:** 漫画页不再显示只有「书架」一项的视图页签；Tag chips 出现在该页签原来的位置，与「漫画」标题、右上角动作同一行；标题下的独立标签行删除。标签的点击筛选、长按拖动排序、清除筛选 chip 保持不变，没有标签时该位置留空。普通书籍页（my-comic 中不可达）不受影响。同一 ticket 更新项目术语表：新增 Tag（标签），把 Category（分类）标注为仅 Mihon 备份兼容、v1 已无 UI，并统一使用「视图页签」这一说法。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 漫画页不再显示「书架」视图页签。
- [x] Tag chips 出现在原视图页签位置，与「漫画」标题、右上角动作同一行。
- [x] 标题下不再有独立标签行；没有标签时该位置留空。
- [x] 点击筛选、长按拖动排序、清除筛选的行为保持不变。
- [x] 普通书籍页（my-comic 中不可达）的视图页签与标签行为不受影响。
- [x] 项目术语表新增 Tag（标签），Category（分类）标注为仅 Mihon 备份兼容、v1 已无 UI，并统一使用「视图页签」。
- [x] 测试覆盖页签消失、标签位置、空标签与筛选 / 排序行为。

## Comments

- 2026-11-06: Resolved on `integration/manga-ui-polish` (ticket merge `9900831d`; dual-axis review-fix merge `a0571b85`). Review follow-up changed the manage-tags action icon to `FushiIcons.tag`.
