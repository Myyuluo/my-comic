# 13: 清除数据库

**What to build:** 在设置「存储与下载 → 数据存储位置」新增破坏性的「清除数据库」行，删除全部历史、未入书架作品记录与孤儿阅读记录，保留书架作品及其进度、下载与本地文件。

**Blocked by:** 08（历史记录写入与历史页基础）

**Status:** resolved

- [x] 在「清除缓存」之后追加「清除数据库」动作行，使用 destructive 红色样式。
- [x] 删除全部 `media_open_history` 行（含未入书架作品的 snapshot 行）。
- [x] 删除不在 Library 中的 Manga 记录及其级联的章级状态、阅读位置、阅读覆盖、下载任务、章节容器映射；只删记录，不删磁盘文件（复用 record-only 级联）。
- [x] 删除无法对应任何作品的 `reader_positions` / `manga_chapter_states` 孤儿行。
- [x] 保留 Library 作品及其 Reading progress、章节 `readAt`、书级完成标记。
- [x] 保留 Download library 文件与索引、Local source 目录与文件、设置、源、扩展、搜索历史、Tracking 数据。
- [x] 确认框显示将删除的数量（作品 X 部 / 历史 Y 条 / 阅读记录 Z 条）；执行时用进度框；删除在一个事务中完成；完成后 toast 结果；不需要重启。
- [x] 页面级测试覆盖删除对象、保留对象、数量统计与事务行为。
- [x] `flutter analyze`、定向测试通过（按批量任务指令未运行完整 Windows 构建）。

## Comments

- 2026-11-09：实现完成。新增 `MangaDatabaseClearService`（真实 37 表库的服务层测试）与
  `settings_schema_database_clear.dart`（确认 / 进度 / toast 页面级测试）。Library 成员
  判据与漫画书架同源：书架只列 `format='manga'` 的 `epub_books` 行，其余 format 的
  记录视为「不在 Library 中」的遗留作品，按 `deleteEpubBook` 的记录级级联删除；磁盘
  文件从不触碰。删除在一个事务内完成，测试用注入异常验证中途失败全部回滚。历史页
  搜索 / 单本删除（ticket 09）与历史生命周期（ticket 10）未改动。
