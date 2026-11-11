# 05: Docs、i18n 与全量验证

**What to build:** 收口本批领域文档、i18n 与验证：记录 fork 身份/版本/更新源决策，确认全部 locale 完整，跑通本批相关测试且不新增历史失败。

**Blocked by:** 01（历史页使用书架封面缓存）、02（品牌图标与设置 GitHub 行指向 fork）、03（系统与关于清理、版本 1.0.0 与更新源）、04（清除缓存只计量可清理内容）

**Status:** ready-for-agent

- [ ] 更新/补充 ADR：fork 身份、版本 1.0.0、GitHub 仓库与更新检查指向 `Myyuluo/my-comic`、无 release 时的「已是最新」语义（可修订 ADR 0004 或新增 ADR）。
- [ ] GLOSSARY 如涉及品牌/更新源/缓存计量术语，按需更新；避免 implementation details。
- [ ] 全部 locale 的新增/修改/删除文案同步完整；i18n completeness/sorted/mojibake 通过；不再使用的 key 已清理。
- [ ] 本批相关测试全绿：History 封面、品牌图标、设置系统与关于、版本显示、更新检查无 release、清除缓存计量。
- [ ] 不新增历史全量失败；已知 manga-only schema / `cover_write_sink_bug_2496` 等保持原记录。
- [ ] 未新增数据库 schema、未改 Backup、未移动用户文件。
- [ ] ticket 05 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、剩余遗留）。
