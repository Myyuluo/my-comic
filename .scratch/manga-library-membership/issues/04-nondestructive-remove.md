# 04: 非破坏移出书架

**What to build:** 移出书架只清 membership，保留 Manga/Chapter、阅读进度、已读标记、下载任务/映射、下载文件夹与 History；同时移除 Tag 分配与订阅。保留「同时删除本地文件」与「同时删除统计数据」选项：在线作品删文件但保留非书架行/状态；本地作品勾选删文件时连行/状态一起删除。弹窗文案与批量语义同步调整。

**Blocked by:** 01（Library membership 基础）、02（非书架行与在线阅读）

**Status:** resolved

- [x] 在线与本地作品移出书架后 membership=false，Manga/Chapter、阅读进度、已读、下载与 History 保留。
- [x] 移出后 Tag 分配与订阅/自动追更被移除。
- [x] 在线作品勾选「同时删除本地文件」时删除已下载文件与下载索引，但保留非书架行与阅读状态。
- [x] 本地图源作品勾选「同时删除本地文件」时删除 Manga 行及阅读/已读/下载状态。
- [x] 「同时删除统计数据」保持现有语义。
- [x] 移出弹窗文案说明“进度/已读/下载会保留”，两个删除选项仍为破坏性说明。
- [x] 不新增独立的“彻底删除漫画”动作。
- [x] 批量移出逐作品应用同一语义，部分失败保留并报告。
- [x] 页面级测试覆盖在线/本地、两个选项、Tag/订阅移除、行/状态保留与批量。

## Answer

非破坏移出已落地，核心是 `MangaLibraryRemovalService.removeMangaFromLibrary`（`fushi/lib/src/media/manga/library/manga_shelf_removal_service.dart`）统一驱动单卡、批量与本地图源批量流程。

- **Membership 翻转**：默认路径不再删除 Manga 行，只调用 `updateEpubBookInLibrary(bookKey, inLibrary: false)` 清书架归属；服务返回仍保留的 `EpubBookRow`（非书架行），在线作品页保持打开并显示非书架状态，本地图源页回到浏览网格并隐藏移出动作。重新加入复用同一行与文件夹。
- **状态保留**：Manga/Chapter 行、阅读进度、已读标记、下载任务、章目录映射、下载文件夹与 History 全部保留。行删除路径也以 `removeFromLibraryOnly: true` 调底层，避免 History 级联。
- **Tag / 订阅移除**：移出时 `deleteTagAssignmentsForHost` 删除 Tag 分配；在线描述符把 `subscribed` 与 `autoDownload` 写回 false 并持久化。
- **文件选项**：在线作品勾选「同时删除本地文件」时先停掉排队中/下载中的任务，再删除下载目录并清掉该作品的下载任务与章目录映射，但保留非书架行与阅读状态；文件删除失败则整体失败且不改 membership（避免「书架没有、文件还在」的中间态）。
- **统计选项**：「同时删除统计数据」沿用原有破坏性语义，改为在文件删除成功之后才执行，保持失败即不触碰书架外状态。
- **本地作品**：Local source 与受管本地卷勾选「同时删除本地文件」时，先删原作文件，成功后连 Manga 行及阅读/已读/下载状态一起删除（History 保留）；文件删除失败则作品留在 Library。Local source 根目录不可用返回明确失败原因；失败文案均经 Slang 本地化。
- **批量**：逐作品应用同一语义，部分失败保留成功项并报告失败；Local source 重新加入会把既有非书架行的 membership 恢复为 true（复用 ticket 03 的 `updateEpubBookInLibrary`，不再重复 setter）。
- **文案**：单部/批量移出确认文案改为「阅读进度、已读标记、已下载章节与 History 会保留」，两个可选项仍保持破坏性说明；en、zh-CN、zh-HK 已更新。
- **票 commit**：`fcac71d5`（后续 `9da824d9` 对齐 ticket 03 membership 实现并补充本地源重新加入覆盖）。
- **验证**：`manga_series_page_unified_removal_test`、`manga_series_page_remove_from_shelf_test`、`local_source_selection_batch_test`、`manga_shelf_batch_remove_test`、`reader_shelf_batch_actions_manga_schema_test`、`manga_series_page_add_to_library_tag_picker_test` 共 58 项全部通过（需先用 `dart run slang` 重新生成 `lib/i18n/strings.g.dart`）。

**Follow-up（文案缺口）**：其余 locale（ar、de、es、fr、id、it、ja、ko、nl、pt-BR、ru、th、tr、vi）的 `manga_series_remove_confirm`、`manga_series_remove_confirm_batch`、`manga_batch_remove_confirm` 仍是旧的「进度/已读会删除」说法；因 key 已存在不会回退到 en，需后续补齐翻译。
