# 10: 导入非书架行与 History 修复

**What to build:** 导入 `.tachibk` 时，`favorite=true` 创建书架行，`favorite=false` 创建非书架 Manga 行及其章节、阅读进度、已读与 History（不进入书架）。导入 History 写入 canonical `manga_online` 身份与完整快照；历史页兼容旧 `reader_manga` 裸快照；封面回退到快照 imageUrl / 来源 coverUrl；历史卡片不显示原始 bookKey，点击可打开书架或源作品页。

**Blocked by:** 01（Library membership 基础）、02（非书架行与在线阅读）

**Status:** resolved

- [x] 导入 `favorite=true` 作品创建书架行；`favorite=false` 作品创建非书架行，不进入书架。
- [x] `favorite=false` 行保留章节、阅读进度、已读与 History。
- [x] 导入 History 写 canonical 身份与完整快照（title/author/imageUrl/online/bookKey/mihon_history）。
- [x] 历史页兼容旧 `reader_manga` 裸快照，不显示原始 `fushi://book/...` 标题。
- [x] 历史封面按本地 → 快照 imageUrl → 来源 coverUrl → 占位回退。
- [x] 历史卡片点击可打开书架作品或在线源作品页。
- [x] 导入报告包含书架/非书架/History 计数；重复导入幂等。
- [x] 页面级与导入服务测试覆盖上述行为与旧数据兼容。

## Answer

Ticket 10 已由 commit `aa2ce05b` 实现（`feat(import): restore non-library rows and canonical History (ticket 10)`），并合入 `integration/manga-library-membership`。

- **非书架导入行**：`favorite=false` 条目现在插入持久的 `epub_books` 行（`in_library=false`），包含章节、阅读进度、已读标记、当前章与 History，但永不出现在书架。已存在的同一身份行改为就地合并（`nonLibraryEntriesMerged`），不会重复插入；`favorite=true` 命中已有非书架行时翻转为书架行。无 URL 的条目仍计为失败，并按 noHistory/missingUrl 归因 History 跳过。
- **Canonical History/快照**：导入 History 使用 `mangaHistoryIdentityForBook(row)` 的 canonical 身份（在线作品即 `manga_online`）写入 `media_open_history`，快照为完整 `MangaHistorySnapshot`（title/author/imageUrl/bookKey/online/mihon_history），只取 `lastRead > 0` 的最新一条；若已有 canonical 行不早于备份时间则跳过（`alreadyNewer`），重复导入幂等。
- **旧数据兼容**：`MangaHistorySnapshot.tryParse` 识别无 `mangaHistory` marker 的 legacy 裸快照（`{title,author,imageUrl,mihon_history}`）；历史页将旧 `reader_manga` + `fushi://book/<bookKey>` 身份按 bookKey 解析回对应 Library 行，并把 snapshot bookKey 匹配也纳入查找。原始 `fushi://book/...` 永不作为标题展示（回退到 `srs_stats_source_untitled`）。
- **封面回退**：本地落盘封面 → 快照 imageUrl（`file://` 仅本地已存在时使用）→ 来源 `sourceMetadata` 的 series coverUrl → 快照 online coverUrl → 占位（null）。
- **点击打开**：快照优先提供 `MangaHistoryOnlineRef`；缺失时从命中的 Library 行推导，因此行被删除后仍可回到源作品页，有书架行则打开书架作品。
- **导入报告**：新增 `nonLibraryEntriesImported` / `nonLibraryEntriesMerged`，History 计数覆盖书架与非书架条目；报告对话框把非书架计数作为正常计数展示，不再作为 `notInLibrary` 跳过原因。
- **测试**：`flutter test test/backup_import/ test/pages/manga_history_page_test.dart test/media/manga/manga_history_write_test.dart test/pages/manga_library_membership_test.dart test/pages/manga_nonlibrary_reading_test.dart` 全部 122 项通过。

**已知风险：** 旧版本导入写入的 legacy `reader_manga` History 行不会被迁移或删除；重新导入修复后的备份会同时留下 legacy 与 canonical 两条 `media_open_history` 记录。历史页已按 Manga 去重为一张卡片（保留最新 `openedAt`），且导出逻辑应只读 canonical 行，但数据库层面仍存在重复行，后续清理 ticket 可考虑一次性迁移/删除 legacy 行。
