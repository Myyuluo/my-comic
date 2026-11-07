# 09: Rebuild re-link

**What to build:** 在设置 → 存储与下载提供「重建下载索引」。它以书架上的 Manga 为主线，在 `downloads/{source}/{manga}` 和 `localcomic/{manga}` 中查找章节：先按 `pages.json` 稳定 ID 匹配，再按文件夹名匹配；更新路径与「已下载」状态。找不到文件的记录标记 Missing，不删除。操作显示进度、可取消、可重复运行；不移动文件、不读取旧 Content root、不扫描 `autobackup`。

**Blocked by:** 04, 06, 07, 08

**Status:** ready-for-agent

- [ ] 用户把文件手动搬到新 Content root 后，点击重建索引，已有 Library Manga 的下载/本地章节恢复可用
- [ ] 匹配优先使用 `pages.json` 稳定 ID，名称只作为回退
- [ ] 找不到文件的记录显示 Missing，记录和文件都不被删除
- [ ] 有进度、可取消、可重复运行；结束后有结果摘要
- [ ] 不移动文件、不读取旧 Content root、不扫描 `autobackup`
- [ ] 有自动化测试覆盖 ID 匹配、名称回退、Missing、重复运行
