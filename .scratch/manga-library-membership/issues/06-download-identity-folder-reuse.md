# 06: 下载身份与文件夹复用

**What to build:** 统一在线漫画的下载身份为 `(runtime, 数字 sourceId, seriesKey)`，扩展包只作 tie-breaker；在目标来源目录下按 `pages.json` 身份复用已有漫画文件夹，包含 `.cbz` 内的 manifest。恰好一个匹配才复用；多个匹配不猜；无 manifest 保持现有 `(2)` 安全规则。复用后立即重建该作品的章节映射。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 统一下载身份为 runtime + 数字 sourceId + seriesKey；`mihon.unavailable` 与真实包视为同一身份。
- [ ] 目标来源目录下恰好一个 Manga 文件夹/章节 manifest 匹配时，复用该文件夹。
- [ ] 多个匹配时不随意选择，保持冲突/`(2)` 行为。
- [ ] 无 manifest 的现有文件夹仍按现有规则生成 `(2)`，不覆盖。
- [ ] `.cbz` 章节内部的 manifest 参与身份匹配。
- [ ] 复用后立即重建该作品的章节映射，详情页显示已下载。
- [ ] 不删除、不重命名已有文件或文件夹。
- [ ] 服务测试覆盖复用、无 manifest、歧义、CBZ、复用后映射。
