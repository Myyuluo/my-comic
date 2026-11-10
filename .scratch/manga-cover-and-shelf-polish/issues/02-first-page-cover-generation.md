# 02: 缺失封面时从第一页生成封面

**What to build:** 源未安装或没有可用封面的 Manga，只要本地有完整 Chapter container，就从规范阅读顺序下第一个完整容器的第一页生成封面；生成字节只写入 Program state 缓存，书架与作品页都能显示，且不会污染下载目录。

**Blocked by:** 01（书架封面缓存写入后立即刷新）

**Status:** ready-for-agent

- [ ] 从规范阅读顺序下第一个完整 Chapter container 取第一张图片：CBZ 取归档内第一张图片，文件夹章节取自然排序第一张图片；跳过 `ComicInfo.xml` 等非图片文件。
- [ ] 生成字节只写入 Program state 的 shelf cover 缓存（按 bookKey），不写 Content root / Download library，不创建下载目录，不改 `cover_path`。
- [ ] 缓存 sidecar 使用本地文件 sentinel（容器规范路径、大小、mtime）；容器替换或更新后视为需要重新生成。
- [ ] 书架与作品页封面优先级：本地 `cover.*` 文件 → 可用 Source 的当前封面（含持久字节缓存）→ 第一页生成封面 → 占位。
- [ ] 来源未安装/停用时，作品页先检查本地封面与持久/生成缓存，再显示「来源未安装」占位，不发起远程请求。
- [ ] Source 恢复可用并成功取得真实封面后，真实封面替换生成封面；生成封面缓存被更新。
- [ ] 第一页损坏、不是图片、容器不完整或解码失败时保留占位，不崩溃，记录日志。
- [ ] 书架或作品页在缺封面时可懒生成一次；生成成功后通过 ticket 01 的 revision 让书架立即显示。
- [ ] 生成封面适用于书架中任何有本地完整容器且没有可用封面的 Manga，不限于源未安装作品。
- [ ] 测试覆盖：源未安装 + CBZ、文件夹章节、封面优先级、坏页、容器变化重生成、不写 Content root、书架与作品页显示。
- [ ] 按 ADR 0008/0023 记录生成封面属于 Program state Cache，不属于 Download library。
