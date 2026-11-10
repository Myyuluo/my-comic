# 02: 书架批量与单卡菜单接入统一移出弹窗

**What to build:** 书架选择模式的批量删除与单卡长按菜单的删除都使用 01 的统一弹窗；批量操作补上在线 Manga 已下载章节的文件删除；逐作品独立处理并报告部分失败；继续提示被筛选隐藏的选中项。

**Blocked by:** 01（统一移出书架弹窗与单本删除语义）

**Status:** resolved

- [x] 书架选择模式点批量删除、单卡长按菜单点删除，都显示与 01 相同的弹窗与文案；批量文案包含选中的作品数量。
- [x] 批量弹窗的两个勾选项默认不勾选；统计数据删除应用于所有选中作品；本地文件删除同时覆盖在线已下载章节与本地原作。
- [x] 混合选择在线与本地 Manga 时，文件删除按作品类型分别处理；本地原作仅在勾选时删除。
- [x] 逐作品独立处理：部分文件删除失败时，失败作品保留在 Library，成功作品移出；结果报告成功与失败数量。
- [x] 被当前筛选隐藏的选中项继续显示现有提示，且不参与本次删除。
- [x] 在线 Manga 的排队中或下载中任务在移出前停止并取消。
- [x] 批量移出后 History 保留；Reading progress、Chapter 已读标记与 Tag 分配被删除。
- [x] 页面级测试覆盖批量与单卡、混合选择、部分失败与隐藏选中项提示。

## Answer

Implemented in `d15e6828`, merged as `9ca7c953`.

统一弹窗：书架批量删除 `_batchDeleteConfirm`（`reader_history/books.part.dart`）与漫画卡长按菜单「删除」`_confirmMangaShelfDelete`（`reader_fushi_history_page.dart`）都改走票 01 的 `showMangaShelfRemovalDialog`，标题、说明与两个默认不勾选的选项与作品页一致。批量说明改用 `manga_series_remove_confirm_batch(n: mediaCount)` 并携带选中数量；被当前搜索/标签筛选隐藏的选中项继续通过 `batch_hidden_by_filter_note` 提示，且不参与本次删除。

逐作品独立处理与部分失败：批量循环对每部作品单独调用 `removeMangaFromLibrary` 并独立 try/catch，失败作品保留在 Library（文件删除失败时服务内不删数据库行），成功与失败分别计数，结束时用 `local_source_batch_remove_done(success:, failed:)` 如实报告；「同时删除统计数据」对所有选中作品生效。混合选择时按作品来源分别删文件：在线 Manga 删 Download library 中的已下载章节，Local source 作品仅在勾选时删 root 内的原作文件夹/文件。

下载任务停止：`manga_shelf_removal_service.dart` 的 `removeMangaFromLibrary` 新增可选 `downloadService`；删除前对在线 Manga 用 `MangaDownloadService.remove` 停止 queued/running 状态的任务（等待正在执行的 worker 真正停下，而非只置取消标志），避免仍需写入的 worker 占用待删目录；本地 Manga 无下载任务，跳过。

文案与测试：新增 `delete_statistics_manga_batch_desc`、`manga_series_remove_confirm_batch` 等 17 个 locale 文案。合并时该统计说明 key 与集成分支的同名 key 冲突，已按票 02 的措辞解决。`fushi/test/pages/manga_shelf_batch_remove_test.dart` 覆盖批量/单卡、混合选择、部分失败、隐藏选中项与下载任务停止；合并后运行 `flutter test test/pages/manga_shelf_batch_remove_test.dart test/media/manga/manga_series_page_unified_removal_test.dart`，20 项测试全部通过。
