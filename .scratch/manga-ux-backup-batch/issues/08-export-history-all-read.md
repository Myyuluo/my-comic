# 08: 导出历史与所有已读作品

**What to build:** 创建备份页增加「历史」「所有已读作品」两个勾选项；导出每部 Library Manga 的最近 History；把未加入 Library 但有阅读 History 的在线作品以 favorite=false 导出；两项受各自勾选项与「书架中的作品」依赖规则控制。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** ready-for-agent

- [ ] 创建备份页增加「历史」「所有已读作品」两个勾选项，默认勾选；取消「书架中的作品」时两者置灰。
- [ ] 勾选「历史」时，每部 Library Manga 导出最近一条 History（章节 URL、lastRead、readDuration）。
- [ ] 勾选「所有已读作品」时，未加入 Library 但有阅读 History 的在线作品以 favorite=false 导出，包含 Source ID、作品 URL、标题、作者、封面与可用历史。
- [ ] 快照没有章节 URL 时只导出作品元数据，不伪造章节或 History 链接。
- [ ] 关闭对应勾选项时不写入该类数据。
- [ ] 导出的 favorite=false 条目不会在导入时创建 Library 条目（与 14 联动）。
- [ ] 备份 seam 测试覆盖历史、favorite=false、缺章节 URL 与勾选依赖。
