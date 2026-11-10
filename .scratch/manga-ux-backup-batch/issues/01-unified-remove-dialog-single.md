# 01: 统一移出书架弹窗与单本删除语义

**What to build:** 在线 Manga 作品页与本地 Manga 作品页的「移出书架」共用一个确认弹窗；移除粉/蓝说明块、「记住这些选择」与同步提示；提供两个默认不勾选的选项：同时删除本地文件、同时删除统计数据。本地 Manga 的原作文件可以在勾选后删除；文件删除先于数据库删除，失败时保留该 Manga 并报告；History 不被删除。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 在线 Manga 作品页与本地 Manga 作品页点「移出书架」显示同一个弹窗，标题为「移出漫画书架」。
- [x] 弹窗只保留标题、说明、两个勾选项与取消/删除按钮；不再出现粉/蓝说明块、「记住这些选择」与「未配置同步」提示。
- [x] 单本说明为「把这部作品移出书架？阅读进度与已读标记会一并删除。」。
- [x] 「同时删除本地文件」与「同时删除统计数据」每次打开都默认不勾选；此前保存的记住选择不再影响弹窗。
- [x] 勾选「同时删除本地文件」时，在线 Manga 删除 Download library 中该作品的已下载章节文件；本地 Manga 删除 Local source root 中该作品的原作文件夹或文件。
- [x] 文件删除先于数据库删除；文件删除失败时该 Manga 仍留在 Library 并显示失败提示；文件不存在视为已删除。
- [x] 勾选「同时删除统计数据」时，该作品的阅读统计与查词/制卡计数被移除，统计页不再计入；在线与本地 Manga 均生效。
- [x] 未勾选任何可选项时，只移出 Library，不删除本地文件与统计数据。
- [x] 移出后 Reading progress、Chapter 已读标记与 Tag 分配被删除，History 保留。
- [x] 取消弹窗不产生任何数据变化。
- [x] 页面级测试覆盖上述行为（真实数据库 + 临时目录），并覆盖文件删除失败与文件缺失。

## Answer

Implemented in `f1ebeeba`, merged as `7207f8b7`.

统一弹窗：新增 `fushi/lib/src/media/manga/library/manga_shelf_removal_dialog.dart`，在线与本地 Manga 作品页共用 `showMangaShelfRemovalDialog`，标题为「移出漫画书架」。弹窗只保留标题、说明、两个默认不勾选的选项（同时删除本地文件 / 同时删除统计数据）与取消/删除按钮；不再渲染粉/蓝披露块、「记住这些选择」或「未配置同步」提示，旧的记住选择偏好不再读取。`manga_series_page.dart` 的在线与 Local source 两条「移出书架」路径都改走它，取消返回 null 且不产生任何数据变化。

删除顺序：新增 `fushi/lib/src/media/manga/library/manga_shelf_removal_service.dart` 的 `removeMangaFromLibrary`。勾选「同时删除本地文件」时先删磁盘文件，只有文件删除成功（或文件本就不存在，视为已删除）后才通过 `ReaderFushiSource.deleteBook` 以 `deleteLocalFiles: false` 删数据库，固定级联 Library 条目、Reading progress、Chapter 已读标记、Tag 分配与下载索引，History 保留。文件删除失败（含 Local source 路径越界、无法定位根目录）或数据库删除失败时返回失败原因，作品仍留在 Library 并显示失败提示。

本地文件删除：在线作品调用 `EpubStorage.deleteBookDir(extractDir)` 删除 Download library 中的已下载章节；本地作品新增 `LocalSourceLibrary.deleteOriginalFilesBeforeLibraryRemoval`，只处理 Local source root 内的原作文件夹/文件（canonicalize + `isWithin` 越界防护），不删数据库行，由调用方在成功后再删 Library 行。

统计数据删除：勾选后 `deleteStatistics: true` 走 `deleteReadingStatisticsForTitle`；为适配 my-comic 漫画-only live schema（没有 `reading_statistics` / `lookup_mining_counters` / `statistics_tombstones` 旧投影表）加入 `hasTable` 守卫，避免「表不存在」异常回滚整个事务导致统计删除静默失效，并写入 study segment 墓碑，统计页不再计入。

测试：`fushi/test/media/manga/manga_series_page_unified_removal_test.dart`（在线/本地统一弹窗、默认不勾选、文件删除、统计删除、失败保留、文件缺失、取消、History 保留、zh-CN 文案）、`manga_series_page_remove_from_shelf_test.dart` 与 `manga_series_page_local_source_actions_test.dart`，共 21 项全部通过。
