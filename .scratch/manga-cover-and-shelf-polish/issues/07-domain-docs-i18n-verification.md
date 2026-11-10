# 07: Domain docs、i18n 与全量验证

**What to build:** 收口本批领域文档、i18n 与验证：更新 GLOSSARY 与 ADR，确认全部 locale 完整，跑通本批相关测试且不新增历史失败。

**Blocked by:** 01（书架封面缓存写入后立即刷新）、02（缺失封面时从第一页生成封面）、03（重建下载索引预热第一页封面）、04（封面 URL 失败驱动自动续签）、05（继续阅读胶囊显示书名）、06（设置页合并备份索引并重排下载分组）

**Status:** ready-for-agent

- [ ] GLOSSARY 修订「Continue reading pill」：现在包含书名第二行，宽度受主标签约束，完整书名在 tooltip。
- [ ] GLOSSARY 增加/修订「Generated cover（生成封面）」：从本地 Chapter container 第一页生成、只存在于 Program state Cache、不是 Download library 内容。
- [ ] ADR 0023 修订：第一页生成封面、封面优先级、失败驱动自动续签与节流；明确封面仍不属于 Download library。
- [ ] ADR 0016 已由 ticket 05 修订；本 ticket 验证记录存在且与实现一致。
- [ ] 全部 locale 的新增/修改文案完整，无英文回退或空缺；i18n completeness/sorted/mojibake guard 通过。
- [ ] 本批相关测试全绿：书架封面解析/刷新、第一页生成、重建预热、自动续签、胶囊书名、设置分组。
- [ ] 不新增历史全量测试失败；已知的 manga-only schema/旧测试失败不在本批范围内，继续如实记录。
- [ ] 未新增数据库 schema、未改 Backup 格式、未写 Download library、未移动用户文件。
- [ ] ticket 07 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、剩余遗留）。
