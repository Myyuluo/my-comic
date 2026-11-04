# 06: Backup Import：最小端到端

**What to build:** Settings → Import Backup 的最小端到端路径：选择 `.tachibk`，sidecar 解析 Library/Category/Reading progress，写入新 schema，Library 显示结果并给出汇总报告。

**Blocked by:** 05: 全新漫画-only DB schema

**Status:** ready-for-agent

- [ ] Settings 有 Import Backup 入口，文件选择器接受 `.tachibk`
- [ ] sidecar 解析 Mihon v0.21.3 备份，返回 Library、Category、Reading progress
- [ ] Import 以 Merge 方式写入现有 Library，按 Manga/Source 去重
- [ ] Library 显示导入的 Manga/Category，Reading progress 正确
- [ ] 导入结束后显示汇总报告（成功/跳过/失败及原因）
- [ ] Backup 文件只在本地处理，不上传
- [ ] sidecar seam 测试使用脱敏 fixture；真实 Backup 不入库
