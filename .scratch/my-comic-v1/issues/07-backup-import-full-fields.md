# 07: Backup Import：完整字段

**What to build:** 在最小导入之上补齐全部 Mihon 备份字段，并实现缺失 Source/Tracker 的处理。

**Blocked by:** 06: Backup Import：最小端到端

**Status:** ready-for-agent

- [ ] Chapter、History、Tracking、Extension store、Source preferences 导入
- [ ] 缺失 Source 标记为不可用并提示安装，不中止 Import
- [ ] 缺失 tracker 跳过并报告，不中止 Import
- [ ] Merge/去重覆盖所有字段
- [ ] 汇总报告覆盖所有字段和跳过原因
- [ ] sidecar seam 测试覆盖 missing Source/Tracker；用真实 Mihon v0.21.3 Backup 验证
