# 10: 导入非书架行与 History 修复

**What to build:** 导入 `.tachibk` 时，`favorite=true` 创建书架行，`favorite=false` 创建非书架 Manga 行及其章节、阅读进度、已读与 History（不进入书架）。导入 History 写入 canonical `manga_online` 身份与完整快照；历史页兼容旧 `reader_manga` 裸快照；封面回退到快照 imageUrl / 来源 coverUrl；历史卡片不显示原始 bookKey，点击可打开书架或源作品页。

**Blocked by:** 01（Library membership 基础）、02（非书架行与在线阅读）

**Status:** ready-for-agent

- [ ] 导入 `favorite=true` 作品创建书架行；`favorite=false` 作品创建非书架行，不进入书架。
- [ ] `favorite=false` 行保留章节、阅读进度、已读与 History。
- [ ] 导入 History 写 canonical 身份与完整快照（title/author/imageUrl/online/bookKey/mihon_history）。
- [ ] 历史页兼容旧 `reader_manga` 裸快照，不显示原始 `fushi://book/...` 标题。
- [ ] 历史封面按本地 → 快照 imageUrl → 来源 coverUrl → 占位回退。
- [ ] 历史卡片点击可打开书架作品或在线源作品页。
- [ ] 导入报告包含书架/非书架/History 计数；重复导入幂等。
- [ ] 页面级与导入服务测试覆盖上述行为与旧数据兼容。
