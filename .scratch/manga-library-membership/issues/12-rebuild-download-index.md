# 12: 重建下载索引

**What to build:** 让「重建下载索引」真正成为强制扫描入口：扫描 `downloads` 与 `local`，按 `pages.json` 身份优先 re-link 所有已有 Manga 行（含 membership=false），身份不中再回退文件名；`local` manifest 可关联到在线 Manga；保留 orphan recovery；重复副本优先 recorded `extractDir`/最新完整副本，否则跳过并报告；不删除/重命名文件；完成后刷新已打开详情页。

**Blocked by:** 06（下载身份与文件夹复用）、07（已下载状态脱离书架）

**Status:** ready-for-agent

- [ ] 重建强制扫描 `downloads` 与 `local`，不扫描 `autobackup`。
- [ ] 按 manifest 身份优先 re-link 所有 Manga 行（含非书架）。
- [ ] 身份匹配不到时回退文件名匹配。
- [ ] `local` 中带 manifest 的文件可关联到在线 Manga。
- [ ] 保留 orphan recovery（为未索引内容补建条目）。
- [ ] 重复副本优先 recorded `extractDir`/最新完整副本，否则跳过并报告。
- [ ] 不删除、不重命名文件或映射。
- [ ] 完成后已打开的详情页刷新已下载状态。
- [ ] 报告匹配/跳过/歧义/失败数量。
- [ ] 服务与页面测试覆盖上述行为。
