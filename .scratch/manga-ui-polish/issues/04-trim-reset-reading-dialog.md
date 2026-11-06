# 04: 精简重置阅读状态对话框

**What to build:** 单卡与批量「重置阅读状态」共用的对话框只保留「同时撤销最近一次打开的记录」这一个可选勾选，删除「同时清除它的全部学习记录」。底层 `study_segments` 阅读统计写入、统计中心以及备份 / 同步路径保持不变。取消、确认、点外面关闭的原有行为不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 单卡与批量重置对话框不再显示「同时清除它的全部学习记录」。
- [x] 「同时撤销最近一次打开的记录」仍可勾选，并在确认后按原语义撤销最近一次会话。
- [x] 不勾选任何选项时，重置只影响阅读位置与完成标记，不动学习记录。
- [x] 取消、确认与点外面关闭行为不变。
- [x] `study_segments` 写入与统计中心不受影响。
- [x] 测试覆盖单卡与批量两条入口。

## Comments

- 2026-11-06: Resolved on `integration/manga-ui-polish` (ticket merge `df447520`; dual-axis review-fix merge `a0571b85`). The retained option now derives sessions directly from current-profile `study_segments` so it works on the 37-table schema.
