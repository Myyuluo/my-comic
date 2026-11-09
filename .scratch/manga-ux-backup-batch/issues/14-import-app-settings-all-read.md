# 14: 导入：应用设置与未入书架已读作品

**What to build:** 导入 MyComic 自己的应用设置时只补齐本机缺失的已知键；导入 favorite=false 的已读作品时恢复 History 但不创建 Library 条目；导入汇总报告增加 Tag、应用设置与未入架 History 的计数。

**Blocked by:** 08（导出历史与所有已读作品）、11（导出应用设置与敏感设置过滤）

**Status:** ready-for-agent

- [ ] 导入包含 MyComic 应用设置的备份时，只导入 MyComic 已知键；本机已有键不被覆盖，缺失键被补齐。
- [ ] Mihon 原生键被跳过，不写入 MyComic 应用设置。
- [ ] favorite=false 的已读作品不创建 Library 条目；其 History（作品快照、标题、封面、最近阅读时间、可用章节 URL 与阅读时长）被恢复。
- [ ] 恢复的 History 出现在历史页，不增加书架作品数。
- [ ] 导入汇总报告包含 Tag、应用设置与未入架 History 的计数与跳过原因。
- [ ] 重复导入幂等；Merge 语义与其他导入行为保持不变。
- [ ] 与 08、11 的导出往返测试通过：MyComic 导出后重新导入，应用设置与未入架 History 一致。
