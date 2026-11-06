# 02: 作品页改为手动刷新

**What to build:** 已入库的在线漫画打开作品页时不再自动联网刷新，直接显示本地缓存的作品信息与章节列表；用户通过现有的「⋯ → 刷新章节」手动拉取。未入库的来源作品仍自动拉取一次详情与章节；已入库但缓存没有章节时自动兜底拉取一次。Mihon 与互联对端作品使用同一规则；本地卷、阅读进度、下载状态、失败提示条与重试入口保持不变，不新增「数据可能不是最新」提示。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 打开已入库在线漫画作品页时不发起网络刷新，立即显示本地缓存。
- [x] 现有「⋯ → 刷新章节」仍能手动拉取并更新页面。
- [x] 未入库的来源作品仍自动拉取一次详情与章节。
- [x] 已入库但缓存章节为空时自动兜底拉取一次。
- [x] Mihon 与互联对端作品遵循同一规则；本地卷打开行为不变。
- [x] 阅读进度、下载状态、章节状态、失败提示条与重试入口保持不变。
- [x] 不新增「数据可能不是最新」或类似提示。
- [x] 相关测试已新增/更新，`flutter analyze` 与定向测试通过。

## Comments

- Implemented and merged into `integration/reading-behavior-and-privacy` at merge commit `1893f8ee` (dual-axis review fixes included).
