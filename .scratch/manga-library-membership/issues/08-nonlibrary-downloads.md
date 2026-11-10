# 08: 非书架下载与删除下载

**What to build:** 让 membership=false 的在线作品支持下载章节、下载全部与删除已下载章节；下载 worker 与下载索引能解析非书架行/身份；下载任务出现在下载页；下载完成后触发可选的「加入书架？」提示。

**Blocked by:** 07（已下载状态脱离书架）

**Status:** resolved

- [x] 非书架作品可下载单个章节与全部章节。
- [x] 非书架作品的下载任务出现在下载页，支持暂停/恢复/取消/重试。
- [x] 下载 worker 与下载索引能解析非书架行或下载身份，不需要 Library 行。
- [x] 非书架作品可删除已下载章节并释放文件/映射。
- [x] 下载完成后显示可选「加入书架？」提示，不自动加入。
- [x] 下载与删除下载后详情页状态立即更新。
- [x] 页面级与服务测试覆盖非书架下载、任务、删除与提示。

## Answer

Implemented in `197180a3` (ticket branch `ticket/08-nonlibrary-downloads`; merged integration tip `9d2fc31c` cleanly, no conflicts).

- **入队解析真实身份**：`MangaDownloadService.enqueueChapter()` 先经共享下载身份 `OnlineMangaLibraryService.find()`（占位扩展包 / 规范化数字 sourceId 回退）复用已有 Manga 行；没有行时按票 02 的语义补一条 membership=false 的非书架行。任务始终使用真实 `bookKey`，worker 与下载索引不再依赖 Library membership，也不会因占位包/真实包差异产生孤儿任务。
- **详情页入口**：单章下载、重试下载、删除下载与「下载全部」不再要求页面预先加载 Library 行。入队后页面把任务真实行（`job.bookKey`）接回 `_row`，任务列表、已下载状态、删除与「加入书架？」提示共用同一身份；下载/删除后仍由任务表 watch 与 manifest 重扫立即刷新章节状态。
- **删除下载**：新增 `DownloadLibraryIndex.deleteChapterForEntry()`。有行且映射可解析时按映射删除；没有行或映射未覆盖时，按 entry 的 `pages.json` 下载身份在 `downloads` 根下找唯一能证明身份的漫画文件夹，删除该章的目录/CBZ 容器（多匹配不猜）。`local` 根不参与删除，避免误删用户原作文件；删除后同时清任务行、失效扫描缓存并立即把章节切回未下载。
- **提示**：复用票 05 的非模态「加入书架？」SnackBar；仅对 membership=false 行、每次打开作品页最多提示一次，点按钮才翻转同一行 membership，绝不自动加入。
- **下载页**：无需改 UI；任务表与作品行无关，非书架任务照常显示并支持全局暂停/继续、行内取消/重试。
- **测试**：合并 integration（票 11/12）后 `flutter test --no-pub` 覆盖 `test/media/manga/manga_download_service_test.dart`、`test/pages/manga_nonlibrary_downloads_test.dart`（新增：无行单章下载 + 提示、按身份删除、下载全部、下载页任务暂停/恢复/取消/重试）、`manga_series_page_downloaded_status_test`、`manga_nonlibrary_reading_test`、`downloads_page_test`、`download_library_index_test`、`online_manga_library_test`、`rebuild_download_index_service_test`、`settings_rebuild_download_index_test`、`backup_import/` 等 301 项全部通过；`flutter analyze --no-pub` 对改动文件无问题。
- **已知边界**：仅存在于 `local` manifest、没有映射的已下载章节会显示为已下载，但「删除下载」不会删除 `local` 原作文件（保持 spec 的本地文件安全语义）；重复/歧义目录按票 06/12 的「不猜」规则不删除。
