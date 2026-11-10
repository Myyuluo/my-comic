# 01: 书架封面缓存写入后立即刷新

**What to build:** 手动刷新或后台封面字节写入成功后，书架立即重新解析并显示新封面；从作品页返回书架时也重新解析，不需要重启或等待下一次无关刷新。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 封面字节服务能报告本次写入成功或失败；成功写入 Program state 的 shelf cover 缓存后 bump 一个进程级封面 revision。
- [ ] 书架数据 provider 监听该 revision；revision 变化后重新解析 `MediaItem`，卡片使用新的持久缓存封面。
- [ ] 从作品页返回书架时主动 invalidate/刷新书架 provider，而不是只刷新 shelf maps。
- [ ] 切换封面 URL 后，旧的失败图片缓存条目不会继续压制新封面；必要时清掉该 bookKey 的旧图片缓存。
- [ ] 失败或没有新字节时不产生无意义的 provider 重建。
- [ ] 测试覆盖：字节写入成功 → revision → 书架新封面；作品页返回 → 书架刷新；失败不触发重建。
- [ ] 不写 Content root / Download library，不改数据库 schema，遵守 ADR 0008。
