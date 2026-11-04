# 06: Backup Import：最小端到端

**What to build:** Settings → Import Backup 的最小端到端路径：选择 `.tachibk`，sidecar 解析 Library/Category/Reading progress，写入新 schema，Library 显示结果并给出汇总报告。

**Blocked by:** 05: 全新漫画-only DB schema

**Status:** resolved

- [x] Settings 有 Import Backup 入口，文件选择器接受 `.tachibk`
- [x] 解析 Mihon v0.21.3 备份（v1 Dart fallback；sidecar migration 后续，见 ADR-0007），返回 Library、Category、Reading progress
- [x] Import 以 Merge 方式写入现有 Library，按 Manga/Source 去重
- [x] Library 显示导入的 Manga/Category，Reading progress 正确
- [x] 导入结束后显示汇总报告（成功/跳过/失败及原因）
- [x] Backup 文件只在本地处理，不上传
- [x] sidecar seam 测试使用脱敏 fixture；真实 Backup 不入库

## Comments

- 真实备份计数：8634 entries → 5356 imported / 3278 skipped / 0 failed；3 categories；9496 chapter states；9 missing sources
- 合成 fixture 5/5 通过
- build/run/UI 验收通过
- 限制：缺失 source 不自动改写；封面不下载；约 90s；既有 settings 测试红与本 ticket 无关
