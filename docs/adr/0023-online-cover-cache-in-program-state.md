---
status: accepted
---

# 在线封面以 bookKey 缓存在 Program state，不属于 Download library 或 Backup

在线源返回的封面地址常带时效签名。书架只保存导入或上次刷新时的 URL，而书架自身不刷新元数据，签名过期后封面请求失败，卡片退回占位；源搜索结果因为每次拿到新 URL 仍能显示。现有 HTTP 图片缓存按 `item.uniqueKey` 缓存字节，但不携带 Extension 的 headers、cookies 与站点鉴权，遇到防盗链同样失败。封面不是下载内容（见 ADR 0011 / ADR 0012 / ADR 0019）：它不能写入 Content root，不应出现在 Download library，也不进入 Backup。我们决定把在线封面作为可再生的 Program state 缓存处理：

- **解析顺序**：按 bookKey 的持久封面缓存 → 本地封面文件 → 已保存的远程封面 URL（现有 HTTP 图片缓存）→ 占位。
- **持久缓存位置**：Program state root 的 cache 下（`<programState>/cache/shelf_covers`），文件名为 `sha256(bookKey).cover`，同名 `.url` 侧车记录产生该字节的源 URL。缓存绝不写入 Content root 或 Download library，不创建下载目录，不产生 Download index 条目，也不进入 Backup。
- **字节来源与刷新**：封面字节通过 Extension runtime 获取，复用 Extension 的 headers、cookies 与站点鉴权；新封面 URL 落库后后台刷新字节，刷新失败只记录日志并保留旧字节。来源未安装或未启用时不发起运行时封面请求；书架有本地或持久缓存封面时继续显示，否则占位。
- **失败驱动自动续签**：封面字节获取失败（403 / 404 / 5xx、签名过期、解码失败）且来源已安装 / 启用时，书架后台做一次**详情-only**刷新：详情阶段的系列描述与 `series.coverUrl` 落库，章节列表为空或抓取失败时保留旧章节；随后用新 URL 刷新持久字节并让书架重算。续签按书节流：每次应用启动最多一次，并持久化 24 小时冷却（尝试时间写在 Program state 封面缓存目录的 `.renew` 侧车，失败也算一次）；来源未安装 / 停用、平台不支持或网络不可用时跳过，失败保留旧缓存或占位、不删除已有字节。手动「刷新漫画」与 24 小时更新探针的既有行为不变，自动续签只是额外的失败驱动恢复路径。
- **容量与淘汰**：默认上限 512 条 / 64 MiB，写入后按文件 mtime 升序淘汰最旧条目，连同 `.url` 侧车一起删除；写盘使用临时文件 + rename，空字节不覆盖旧缓存。清除缓存一并删除该缓存并令书架重新解析，之后回退到远程 URL 或占位。
- **URL / 元数据刷新与字节缓存解耦**：源详情刷新成功即持久化系列元数据与封面 URL，即使章节列表为空或章节抓取失败；已有非空章节列表在源返回空列表时保留。打开源搜索结果或详情页并识别到已有书架记录时，把当前系列描述（至少封面 URL）合并回该记录，不要求用户手动刷新。
- **封面缓存不改变下载语义**：封面不参与「已下载 / 未下载 / Missing」判定，不进入 Download index；清除缓存不改变 History、Reading progress、Chapter 状态或 Download library。Backup 导出 / 导入格式不变，封面缓存不随 Backup 迁移。

**Considered Options**

- **只用现有按 `item.uniqueKey` 的 HTTP 图片缓存**：实现最省，但不带 Extension headers / cookies，签名过期后仍失败。
- **把封面字节写进 Download library 或 Content root**：看起来持久，但会制造假的下载目录、污染人类可读的下载库，并被搬移与备份语义误认为下载内容。
- **把封面字节存进数据库**：会无谓膨胀数据库与 Backup；封面是可再生缓存，不应与 Library 数据同生命周期。
- **每次显示都联网抓取**：离线与签名过期时不可用，并给来源增加额外请求。
- **按 URL 作为缓存 key**：签名 URL 每次变化，缓存永远 miss；bookKey 才对应作品身份。

**Consequences**

- 签名 URL 过期后，只要持久缓存存在，书架仍显示封面；清除缓存或换设备后需重新联网或重新打开源页面恢复。
- 来源未安装时书架仍可显示本地或持久缓存封面，但不会发起请求；作品页保持灰占位。
- 缓存文件本身不保存 Extension 凭据；headers、cookies 只在运行时抓取时使用。
- 清理缓存必须同时删除字节与 `.url` 侧车，避免残留 URL 被误用；清除后书架回退到远程 URL 或占位。
- Backup 边界不变：封面缓存不导出、不导入，也不出现在 Download library。
