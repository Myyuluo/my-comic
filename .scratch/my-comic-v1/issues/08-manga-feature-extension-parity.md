# 08: 漫画功能与 Extension 兼容验收

**What to build:** 验收 my-comic 的漫画功能与 Extension 行为：用 Keiyoushi 和真实 Extension 走通安装/搜索/阅读/下载，逐项核对 Library、Category、Source、Reader、Download、History、Update、Tracking、Local source。

**Blocked by:** 04: 删除非漫画原生库并测量体积；05: 全新漫画-only DB schema；06: Backup Import：最小端到端；07: Backup Import：完整字段

**Status:** ready-for-agent

- [ ] 添加 Keiyoushi `index.pb` 并刷新 Extension store
- [ ] 安装一个真实 Extension，确认 Trust signer，Source 出现在 Browse
- [ ] Source 搜索、Manga 详情、Chapter 阅读、HTTP 下载正常
- [ ] Library、Category、History、Update、Tracking、Local source 验收通过
- [ ] Backup Import（06/07）验收通过
- [ ] 记录与 Fushi v3.0.0 的差异；Fushi 能跑而 my-comic 不能的记为回归；缺失功能产出后续 ticket
