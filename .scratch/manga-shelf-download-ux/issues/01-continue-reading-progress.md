# 01: 继续阅读与「读完」语义修正

**What to build:** 修正书架在线漫画的进度、续读与「读完」判定，使读者读书架漫画的任意一章（包括存储数组旧章在前、单章作品、导入章状态）后，书架顶部继续阅读胶囊能正确出现并指向最近阅读的作品；只有显式标记读完或读到规范阅读顺序最后一章末页才算读完。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 存储数组旧章在前、当前停在第 1 话中间页的在线漫画被判定为「在读」，继续阅读胶囊出现并能打开该作品。
- [x] 单章作品打开但未读完时被判定为「在读」，胶囊可选中；读到该章最后一页后才判定为「读完」。
- [x] 读完多话作品的任一旧章只写该章已读，不写书级完成标记；只有读到规范阅读顺序最后一章的最后一页才写书级完成标记。
- [x] 显式「标记已读完 / 取消已读完」仍然直接写/清书级完成标记，不受自动写入条件限制。
- [x] 继续阅读胶囊只从书架成员中选择最近真正阅读过的在读作品；没有候选时隐藏；非书架漫画不参与。
- [x] 书架的「在读 / 读完」统计、「阅读状态」筛选与继续阅读胶囊使用同一分类口径。
- [x] 完成状态已知且未完成时，进度到 100% 不再自动判「读完」；没有完成状态信息的旧记录保留原有回退行为。
- [x] 导入备份恢复的章级阅读状态可参与进度与最近阅读判定，即使本机没有阅读位置记录。
- [x] 回归测试走真实书架数据管线（真实数据库行与章状态），不覆盖合成 `MediaItem.position / duration`；覆盖旧章在前、单章、完成旧章、完成最新章、非书架、导入章状态。
- [x] 设置与书架视觉保持不变，遵守 ADR 0008。

## Answer

- Merge commit: `94a24278adfa5b0634871fc56bfe9aa34b2a3c0d`（`Merge ticket 01: fix continue reading progress and completion semantics`），来源分支 `worktree-agent-a6b0ac7994143369e`（实现提交 `ad1018fc`，分支 tip `e67bc8e2`），无冲突；合并后 integration HEAD 即该 merge commit。
- 改动摘要：
  - `fushi/lib/src/media/manga/library/manga_adjacent_chapter.dart`：新增 `isLastMangaChapterInReadingOrder()`，按规范阅读顺序（在线源 `mangaReadingOrder`，本地图源 scan 自然顺序）判断是否最后一章。
  - `fushi/lib/src/media/manga/reader/manga_fushi_page.dart`：末页自动写书级 `completedAt` 只在规范阅读顺序最后一章的最后一页发生；读完旧章只写章级 `readAt`；无章上下文的本地卷保持旧行为；无痕期间仍不写。
  - `fushi/lib/src/media/sources/reader_fushi_source.dart`：在线漫画进度改由 `manga_chapter_states` + 规范阅读顺序推导（最近动过的章 + 章内页/千分比进度），不再用 `currentChapterIndex`；书架批量读取章状态；`bookLastReadAtProvider` 只在没有 `reader_positions` 行时用章状态 `updatedAt` 兜底（避免无痕阅读顶出最近阅读）。
  - `packages/fushi_core/lib/src/database/database_content_misc.part.dart`：新增 `getMangaChapterStatesForBookUids()`（按 500 本分块批量查）与 `getLatestMangaChapterStateUpdatedAtByBookUid()`。
  - `packages/fushi_engine/lib/media/collections/shelf_sort.dart`：`classifyShelfReadStatus` 新增 `completedKnown`（默认 false 保留旧进度回退）；完成状态已知且未完成时 100% 进度判在读；`tallyShelfProgress` 传 `isCompleted` 即视为完成状态已知。
  - `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart` 与 `home_dashboard_page.dart`：阅读状态筛选 / 继续阅读判定传入 `completedKnown`，与统计、胶囊同一口径。
  - 测试：新增 `test/pages/manga_shelf_continue_reading_progress_test.dart`（真实数据库行 + 章状态管线：旧章在前、单章、完成旧章/最新章、非书架、导入章状态）与 `test/media/manga/manga_completion_semantics_test.dart`；更新 `test/media/shelf_sort_test.dart`、`test/pages/incognito_continue_surfaces_test.dart`、`test/pages/manga_incognito_reading_test.dart`。UI 无变化，遵守 ADR 0008。
- 测试（在 `fushi/` 下，`PUB_HOSTED_URL=https://pub.dev`，Flutter `D:\ProgramData\flutter_3.47.6\bin\flutter.bat`；先 `dart run slang` 重新生成 gitignored 访问器）：

  ```
  flutter test test/pages/manga_shelf_continue_reading_progress_test.dart \
    test/media/manga/manga_completion_semantics_test.dart \
    test/media/shelf_sort_test.dart \
    test/pages/manga_library_continue_pill_test.dart \
    test/pages/manga_library_membership_test.dart \
    test/pages/incognito_continue_surfaces_test.dart \
    test/pages/manga_incognito_reading_test.dart
  ```

  结果：`+55 -1`，唯一失败为 `test/media/shelf_sort_test.dart` 的 `BUG-3347：书架排序键的名称取卡片显示名（改名覆盖层），不读 DB 原始列`。该守卫在合并前基线 `5c4f85fb` 上即失败：守卫测试已存在，而源码中 `ShelfSortKey _shelfGroupSortKey(` 在基线同样缺失（ticket 01 未改动该排序键实现），属基线既有失败，不是本次合并引入。其余 6 个测试文件全部通过。
