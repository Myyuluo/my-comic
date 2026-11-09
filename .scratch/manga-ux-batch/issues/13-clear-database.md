# 13: 清除数据库

**What to build:** 在设置「存储与下载 → 数据存储位置」新增破坏性的「清除数据库」行，删除全部历史、未入书架作品记录与孤儿阅读记录，保留书架作品及其进度、下载与本地文件。

**Blocked by:** 08（历史记录写入与历史页基础）

**Status:** ready-for-agent

- [ ] 在「清除缓存」之后追加「清除数据库」动作行，使用 destructive 红色样式。
- [ ] 删除全部 `media_open_history` 行（含未入书架作品的 snapshot 行）。
- [ ] 删除不在 Library 中的 Manga 记录及其级联的章级状态、阅读位置、阅读覆盖、下载任务、章节容器映射；只删记录，不删磁盘文件（复用 record-only 级联）。
- [ ] 删除无法对应任何作品的 `reader_positions` / `manga_chapter_states` 孤儿行。
- [ ] 保留 Library 作品及其 Reading progress、章节 `readAt`、书级完成标记。
- [ ] 保留 Download library 文件与索引、Local source 目录与文件、设置、源、扩展、搜索历史、Tracking 数据。
- [ ] 确认框显示将删除的数量（作品 X 部 / 历史 Y 条 / 阅读记录 Z 条）；执行时用进度框；删除在一个事务中完成；完成后 toast 结果；不需要重启。
- [ ] 页面级测试覆盖删除对象、保留对象、数量统计与事务行为。
- [ ] `flutter analyze`、定向测试、Windows 构建通过。
