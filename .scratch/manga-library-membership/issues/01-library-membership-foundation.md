# 01: Library membership 基础

**What to build:** 给 Manga 记录增加 Library membership，并把“书架归属”从“数据库里有这行”改为独立标志。现有行迁移为在书架；集中定义判据，让书架、Home 继续阅读、Tag 页签计数、订阅/自动追更、更新探测与备份「书架中的作品」只读取书架作品；阅读、History、下载、下载索引与重建仍读取所有 Manga 行。本 ticket 不创建非书架行，现有行为保持不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] Manga 记录有 Library membership 标志；现有记录迁移为在书架。
- [x] 集中定义 membership 判据，书架页、Home 继续阅读、Tag 页签与计数、订阅/自动追更、更新探测、备份「书架中的作品」、书架批量动作都按它过滤。
- [x] membership=false 的记录不会出现在书架、Home、Tag 计数、订阅/更新探测或「书架中的作品」导出中。
- [x] 阅读器、章节状态、History、下载、下载索引、重建索引仍能读取所有 Manga 行。
- [x] 页面级与服务测试覆盖上述过滤；现有书架/标签/备份/更新行为保持通过。
- [x] 本 ticket 不创建非书架行，也不改变移出/加入书架的现有行为。

## Answer

Implemented in `f1115834`, merged as `d4471b3a`.

Schema v5：`epub_books.in_library`（boolean，默认 `true`）。旧库升级时用 `addColumn` 补列，全部存量行迁移为在书架；新插入行默认也在书架。非书架行仍完整保留，供阅读进度、Chapter 已读、History、下载与下载索引使用。

判据集中在一处：`packages/fushi_core/lib/src/database/library_membership.dart` 的 `EpubBookRow.isInLibrary` / `EpubBookMeta.isInLibrary`；数据层提供 `FushiDatabase.getLibraryEpubBooks()`（书架成员）与 `watchLibraryEpubBookKeys()`（响应式书架键集），全部行仍由 `getAllEpubBooks()` / `getEpubBook()` 提供。

书架专属读取点全部改为 membership 过滤：书架页与 Home 继续阅读（`ReaderFushiSource.getBooksFromDb` / `fushiBooksProvider`）、Tag 页签计数、书架阅读快照与 Tag 批量动作剪枝、订阅 / 自动追更（`OnlineMangaLibraryService.setSubscription` 守卫 + 漫画详情页入口 + 更新探测）、备份「书架中的作品」、来源拥有数、本地图源浏览的「在书架」判定、远端混排去重、合集成员计数、清除数据库的书架 / 非书架分流。阅读器、章节状态、History、下载、下载索引与重建索引继续读取全部 Manga 行。本票不创建非书架行，加入 / 移出书架行为保持不变（详情页按钮仍按行存在判断，留给票 04/08）。

测试：`packages/fushi_core` 的 `dart test` 59 项全过（含新增 `library_membership_test.dart` 与 v1/v2/v3/v4→v5 迁移用例）；本票相关 Flutter 测试 93 项通过、1 项失败（`media_sources_test` 的 `video_books` 用例——my-comic 已移除 video 表，基线同样失败）。书架 / 标签 / 备份 / 更新相邻回归套件 235 项通过，7 项失败均为基线 `bd472b87` 已复现的既存问题。全量 `test/backup_import/ test/pages/ test/media/manga/` 运行结果为 3537 通过 / 224 失败 / 18 跳过；抽样失败（`manga_overlay_html_test`、`manga_chapter_switch_reload_guard_test`、`reader_shelf_batch_download_manga_test`、`shelf_entries_test` 的 video/audio/srt 用例）均已在合并前基线复现，与本票无关。
