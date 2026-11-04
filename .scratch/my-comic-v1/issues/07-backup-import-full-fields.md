# 07: Backup Import：完整字段

**What to build:** 在最小导入之上补齐全部 Mihon 备份字段，并实现缺失 Source/Tracker 的处理。

**Blocked by:** 06: Backup Import：最小端到端

**Status:** resolved

- [x] Chapter、History、Tracking、Extension store、Source preferences 导入
- [x] 缺失 Source 标记为不可用并提示安装，不中止 Import
- [x] 缺失 tracker 跳过并报告，不中止 Import
- [x] Merge/去重覆盖所有字段
- [x] 汇总报告覆盖所有字段和跳过原因
- [x] Dart import service seam（ADR-0007 fallback）覆盖 missing Source/Tracker；用真实 Mihon v0.21.3 Backup 验证

## Comments

- 字段映射已覆盖：
  - Chapters：保留全部章节字段；合并 bookmark/dateFetch 用户标记；写逐章 state 与 book-level reader position
  - History：写入 `media_open_history`，保留 lastRead 时间戳与 duration
  - Tracking：Bangumi 映射到 `media_tracking_mappings`/outbox；不支持的 tracker 跳过并报告，不中止 Import
  - Extension stores：按 index URL merge，保留本地 sync state
  - Source preferences：解码 protobuf preference-value envelope，覆盖六种 value 类型，按 (package, source, key) merge；缺失 source 的 preferences 保留 placeholder
- 真实 Mihon v0.21.3 Backup：8634 entries → 5356 imported / 3278 skipped / 0 failed；3367 history；2 extension stores；96 source preferences；13 missing sources；tracking 0（真实备份无 tracking，由合成 fixture 覆盖）
- 测试：38/38 通过
- build/run/UI 导入报告通过
- 限制：缺失 source 不自动接管（条目显示不可用，待扩展安装后接管 placeholder preferences）；History 仅导入 library 条目；真实备份 tracking 为空，tracking 路径由合成 fixture 覆盖
