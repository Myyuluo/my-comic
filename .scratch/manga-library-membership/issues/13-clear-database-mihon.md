# 13: 清理数据库（Mihon 对齐）

**What to build:** 把「清除数据库」改为 Mihon 风格的「清理数据库」：列出有非书架记录的 Source 及数量，可多选；默认开启「保留有阅读记录的作品」；关闭时警告已读/进度会丢失。执行时删除所选 Source 的 membership=false Manga 行及其章节/进度/已读/下载索引；开关开启时保留有已读或阅读进度的非书架作品；只删除被清理作品的 History；保留书架作品/History、设置、源、扩展与磁盘文件。显示进度与结果，无需重启。

**Blocked by:** 01（Library membership 基础）、10（导入非书架行与 History 修复）

**Status:** resolved

- [x] 设置项显示为「清理数据库」。
- [x] 确认界面列出有非书架记录的 Source 及数量，可多选。
- [x] 默认开启「保留有阅读记录的作品」；关闭时显示明确警告。
- [x] 删除所选 Source 的 membership=false Manga 行及其章节/进度/已读/下载索引。
- [x] 开关开启时保留有已读或阅读进度的非书架作品。
- [x] 只删除被清理作品对应的 History，保留书架作品 History。
- [x] 保留书架作品、设置、源、扩展、磁盘下载文件与 Local source 文件。
- [x] 确认框显示将删除的作品/History 数量；执行时显示进度，完成后 toast 结果。
- [x] 不需要重启。
- [x] 页面级与服务测试覆盖 Source 选择、开关、删除/保留范围、History 范围与保留项。

## Answer

Ticket 13 已由 commit `eaa592b9`（`feat(settings): align clear database with Mihon (ticket 13)`）实现，并合入 `integration/manga-library-membership`（merge commit `d40320d0`）。

- **入口与文案**：设置 →「存储与下载」→「数据存储位置」的危险动作行改为「清理数据库」，沿用现有 Fushi 动作行、确认框、进度框与 toast（`buildClearDatabaseSettingsItem()` / `clearMangaDatabase()`，`fushi/lib/src/settings/settings_schema_database_clear.dart`）。
- **Source 选择**：`MangaDatabaseClearService.measureSources()` 只统计 `epub_books.in_library=false` 的 Manga 行并按 Source 分组：Mihon 在线源按规范化数字 sourceId 合并占位/真实扩展包，互联按 runtime + package + sourceId，Local source 与无来源的本地导入作品各为独立伪源。确认框列出 Source 名称与「$count 部非书架作品」，复选框多选、默认不选、未选中时确认按钮禁用；没有非书架作品时直接 toast「无需清理」。
- **保留开关**：`_keepRead` 默认开启。「有阅读记录」判据为任一章节 `read_at` 非空、章级 `last_page`/`last_fraction > 0`，或书级 `reader_positions` 的 section index / char offset > 0。关闭开关时显示「已读章节与阅读进度会随作品一起删除，且无法撤销」的警告；确认框按开关实时重算将删除的作品与 History 数量。
- **删除范围**：`run()` 在单个事务内删除所选 Source 中 `membership=false` 的作品（开关开启时跳过有阅读记录的作品）。每部作品复用 `FushiDatabase.deleteEpubBook` 的记录级级联，清理章节行、Chapter 已读/章级进度（`manga_chapter_states`）、书级阅读位置（`reader_positions`）、阅读覆盖、已读图片、下载任务（`manga_download_jobs`）、章目录映射与 Tag 分配，但不触碰磁盘文件。History 只删除被清理作品对应的 `media_open_history` 行，同时命中 canonical 身份与 ticket 10 之前的旧 `reader_manga` 裸身份；最后二次清理无任何作品行归属的 `reader_positions` / `manga_chapter_states` 孤儿行。
- **保留项**：书架作品及其阅读状态与 History、未选 Source 的非书架作品、开关开启时的已读/有进度作品、设置、源、扩展、搜索历史、Tracking、Download library 下载文件与 Local source 文件全部保留。整个删除在单事务内完成，任一阶段失败全部回滚；进度框分「移除非书架作品 → 清理作品历史 → 清理阅读记录」三阶段，完成后 toast 删除的作品与 History 数量，无需重启。
- **测试**：`flutter test test/storage/ test/settings/manga_database_clear_settings_test.dart test/media/manga/manga_history_write_test.dart test/pages/manga_history_page_test.dart test/backup_import/mihon_backup_import_test.dart test/i18n/i18n_keys_sorted_guard_test.dart` 共 203 项全部通过（需先用 Flutter SDK 的 `dart run slang` 重新生成 `lib/i18n/strings.g.dart`）。
- **票 commit**：`eaa592b9`。
