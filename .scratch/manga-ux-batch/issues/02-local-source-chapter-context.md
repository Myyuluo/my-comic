# 02: 本地源章级阅读上下文与续读

**What to build:** 让本地图源进入与在线源等价的章级阅读上下文：记录当前章与章内进度、章节列表高亮当前章、重新打开时续读、书架进度与未读角标正确；无痕策略生效。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] `LocalSourceMetadata` 增加可选 `currentChapterKey`；章节相对路径作为 chapterKey；不新增表或列，不做数据库迁移。
- [x] 阅读器本地源路径填充章级上下文；打开与切换章节时更新 `currentChapterKey`；首页/历史等直接开书按它解析当前章与页码。
- [x] 每章写入 `manga_chapter_states`（`lastPage`、`lastFraction`、`pageCount`、`readAt`、`updatedAt`）。
- [x] 章节列表高亮当前章；多章作品重新打开时回到上次章节与页码。
- [x] 书架进度对本地源按章节计算；章节总数从 `chaptersJson` 推导；未读角标按 `readAt` 正确计数。
- [x] 无痕阅读保留章级位置、冻结 `reader_positions.updatedAt`、不自动写 `readAt` / `completedAt`；手动标记已读/未读不受影响。
- [x] 在线源行为与本地章节列表显示顺序不变。
- [x] 页面级测试覆盖当前章、续读、书架进度、未读角标与无痕策略。
- [x] `flutter analyze`、定向测试、Windows 构建通过。

## Answer

Merged as `a40b40bd`. 本地源写回 `currentChapterKey` 与章级状态，重新打开按章续读，书架进度与未读角标按 `chaptersJson` 章节数计算，无痕冻结书级 recency 且不自动写已读/完成标记。
