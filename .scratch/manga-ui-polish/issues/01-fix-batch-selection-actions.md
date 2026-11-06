# 01: 修复批量选择栏的失效动作

**What to build:** 用户在漫画页点「选择」进入多选并勾选漫画后，底部批量栏的全选 / 反选 / 标签 / 重置进度 / 删除全部可用，不再因 my-comic 的 37 表 schema 缺少 `srt_books` / `audiobooks` 等非漫画表而静默失败。该 ticket 打通从页面点击、选中项存在性检查、批量动作到数据库写入的完整路径，并建立真实 37 表数据库的回归测试。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 在 37 表 schema 下选中漫画后，批量标签、重置进度、删除分别能打开对应流程并完成。
- [x] 全选与反选会更新「已选 N」，并作用于当前可见的漫画。
- [x] 批量路径对不存在的非漫画表按空集合处理；表存在时行为不变。
- [x] 单卡菜单与批量栏共用的选中项存在性检查路径都有回归测试。
- [x] `flutter analyze` 与定向测试通过。

## Comments

- 2026-11-06: Resolved on `integration/manga-ui-polish` (ticket merge `6b619423`; dual-axis review-fix merge `a0571b85`).
