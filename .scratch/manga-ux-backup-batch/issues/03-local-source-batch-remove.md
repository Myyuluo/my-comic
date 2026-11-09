# 03: 本地图源页批量移出接入统一弹窗

**What to build:** Local source 页选择模式的批量「移出书架」不再直接执行，改为显示 01 的统一弹窗；支持勾选删除本地原作文件与阅读统计；部分失败逐作品报告。

**Blocked by:** 01（统一移出书架弹窗与单本删除语义）

**Status:** resolved

- [x] Local source 页批量「移出书架」先显示统一弹窗，不再立即执行。
- [x] 弹窗文案、两个默认不勾选项与 01 一致；批量数量正确。
- [x] 勾选「同时删除本地文件」时删除选中作品的 Local source 原作；不勾选时文件保留。
- [x] 勾选「同时删除统计数据」时删除选中作品的阅读统计。
- [x] 逐作品独立处理；部分文件删除失败时保留该作品并报告。
- [x] 批量移出后 Library 条目、Reading progress、Chapter 已读标记与 Tag 分配被删除；History 保留。
- [x] 页面级测试覆盖确认弹窗、文件删除与保留、统计删除与部分失败。

## Answer

Implemented in `82469f45`, merged into the integration branch as `2fb182fc`.

统一弹窗：`fushi/lib/src/media/manga/local_source/local_source_browse_page.dart` 的批量「移出书架」不再直接执行，先调用票 01 的 `showMangaShelfRemovalDialog`；取消返回 null，不产生任何数据变化。弹窗标题、说明与两个默认不勾选项（同时删除本地文件 / 同时删除统计数据）与 01 一致，批量说明的 `count` 只统计本次真正适用（已入架）的作品数。新增 i18n key `manga_batch_remove_confirm` 与 `delete_statistics_manga_batch_desc`，覆盖全部 17 个语言文件。

逐作品处理：确认后对每个选中作品独立调用共享的 `removeMangaFromLibrary`（`fushi/lib/src/media/manga/library/manga_shelf_removal_service.dart`），删除 Library 条目、Reading progress、Chapter 已读标记与 Tag 分配，History 保留。勾选「同时删除本地文件」时先删 Local source root 中的原作文件夹/文件、成功后才删数据库行；文件删除失败的作品留在 Library 并计入失败数，其余作品继续处理。勾选「同时删除统计数据」时按作品删除阅读统计并写墓碑；移除后写 tombstone，作品可重新加入书架。

部分失败：批次不会因单部失败回滚，完成后 toast 报告成功/失败数量并退出选择模式，页面不崩。

测试：`fushi/test/media/manga/local_source_selection_batch_test.dart` 覆盖确认弹窗与取消、文件删除与保留、统计删除、部分文件删除失败、移出语义与 History 保留；`fushi/test/media/manga/local_source_browse_page_test.dart` 覆盖页面筛选/排序/搜索与批量入口的前置行为。合并后两个文件共 28 项测试全部通过。
