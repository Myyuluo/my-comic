# 01: 历史页使用书架封面缓存

**What to build:** History 页的漫画封面改用与书架相同的 Program state shelf cover 缓存解析（本地 `cover.*` → 持久/生成封面 → 可用 Source 远程 URL → 占位），并在页面挂载期间响应封面 revision。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] `loadMangaHistory` 支持可选的 shelf cover cache 输入；现有调用方不传时行为不变。
- [ ] History 封面顺序：本地 `cover.*` → Program state 持久/生成封面 → 可用 Source 的 `series.coverUrl` → 占位；来源未安装/停用时跳过远程。
- [ ] `[darklust]…`（源未安装、只有第一页生成封面）的 History 卡片显示生成封面，不再是灰占位。
- [ ] History 页监听 `MangaShelfCoverRevision`（或等价 revision）；挂载期间封面写入成功后重新加载/刷新。
- [ ] 不改变 History 的排序、去重、History 记录与阅读进度语义。
- [ ] 测试覆盖：本地/持久/生成/远程/占位、来源缺失、revision 刷新；不新增 schema/Backup 变更。
- [ ] 遵守 ADR 0008/0023，不写 Content root / Download library。
