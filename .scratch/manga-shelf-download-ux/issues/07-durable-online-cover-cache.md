# 07: 在线封面持久字节缓存

**What to build:** 通过 Extension runtime 获取在线漫画封面字节，按 bookKey 缓存在 Program state 的封面缓存中，使书架封面在签名 URL 过期、防盗链或需要 headers/cookies 时仍能稳定显示；缓存不写入 Download library。

**Blocked by:** 06（在线封面元数据刷新与 URL 合并）

**Status:** ready-for-agent

- [ ] 在线封面字节通过 Extension runtime 获取，复用 Extension 的 headers、cookies 与站点鉴权。
- [ ] 封面字节按 bookKey 缓存在 Program state 的封面缓存中，不写入 Content root、不写入 Download library、不创建下载目录。
- [ ] 书架封面解析顺序为：按 bookKey 的持久封面缓存 → 本地封面文件 → 已保存的远程封面 URL（现有 HTTP 图片缓存）→ 占位。
- [ ] 签名 URL 过期后，只要持久封面缓存存在，书架仍显示封面。
- [ ] 获得新的封面 URL 后后台刷新持久封面字节；刷新失败时保留旧缓存，不删除已有封面。
- [ ] 封面缓存有容量/数量上限与淘汰规则，并随「清除缓存」清理；清除后回退到远程 URL 或占位。
- [ ] 来源未安装/未启用时不做运行时封面抓取；已有本地封面或持久缓存仍显示，否则占位。
- [ ] 测试在书架封面解析 seam 上覆盖：过期 URL + 持久缓存、headers/cookies 场景、新 URL 后台刷新失败保留旧缓存、清除缓存回退、来源缺失不抓取、不产生 Download library 目录。
- [ ] 不改变 Backup 导出/导入格式，封面缓存不进入 Backup。
- [ ] 书架与作品页视觉保持不变，遵守 ADR 0008。
