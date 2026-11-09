# 11: 导入后自动匹配下载

**What to build:** `.tachibk` 导入成功后，自动对已导入 Manga 执行一次下载匹配：读取 `downloads` 与带 manifest 的 `local`，按下载身份复用文件夹并写入章节映射；不额外创建 Library 条目；报告匹配/跳过数量；重复导入幂等。

**Blocked by:** 06（下载身份与文件夹复用）、07（已下载状态脱离书架）、10（导入非书架行与 History 修复）

**Status:** ready-for-agent

- [ ] 导入成功后自动 re-link 已导入 Manga 的 `downloads` 文件。
- [ ] `local` 中带 manifest 的文件参与匹配。
- [ ] 匹配复用已有文件夹并写入章节映射，不产生 `(2)`。
- [ ] 导入自动匹配不额外创建 Library 条目。
- [ ] 导入报告显示下载匹配/跳过数量。
- [ ] 重复导入保持幂等。
- [ ] 页面级与导入服务测试覆盖自动匹配、复用、报告与幂等。
