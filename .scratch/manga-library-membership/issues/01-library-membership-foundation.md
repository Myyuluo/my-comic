# 01: Library membership 基础

**What to build:** 给 Manga 记录增加 Library membership，并把“书架归属”从“数据库里有这行”改为独立标志。现有行迁移为在书架；集中定义判据，让书架、Home 继续阅读、Tag 页签计数、订阅/自动追更、更新探测与备份「书架中的作品」只读取书架作品；阅读、History、下载、下载索引与重建仍读取所有 Manga 行。本 ticket 不创建非书架行，现有行为保持不变。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] Manga 记录有 Library membership 标志；现有记录迁移为在书架。
- [ ] 集中定义 membership 判据，书架页、Home 继续阅读、Tag 页签与计数、订阅/自动追更、更新探测、备份「书架中的作品」、书架批量动作都按它过滤。
- [ ] membership=false 的记录不会出现在书架、Home、Tag 计数、订阅/更新探测或「书架中的作品」导出中。
- [ ] 阅读器、章节状态、History、下载、下载索引、重建索引仍能读取所有 Manga 行。
- [ ] 页面级与服务测试覆盖上述过滤；现有书架/标签/备份/更新行为保持通过。
- [ ] 本 ticket 不创建非书架行，也不改变移出/加入书架的现有行为。
