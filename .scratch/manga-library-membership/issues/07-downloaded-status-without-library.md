# 07: 已下载状态脱离书架

**What to build:** 在线作品详情页不再要求 Library 行即可计算已下载状态：按 entry 身份查询下载索引，无行时扫描 `downloads` 与带 manifest 的 `local`；非书架作品、源页作品与重新加入的作品都显示已下载章节。`local` 无 manifest 的文件夹不做标题匹配。

**Blocked by:** 02（非书架行与在线阅读）、06（下载身份与文件夹复用）

**Status:** ready-for-agent

- [ ] 详情页对任意在线 entry 计算已下载状态，不再因 `_row == null` 提前返回。
- [ ] 非书架作品在源页显示已下载章节。
- [ ] 重新加入书架的作品显示移出前已下载的章节。
- [ ] `downloads` 与 `local` 中带 manifest 的文件都参与匹配。
- [ ] 无 manifest 的 `local` 文件夹不被按标题关联。
- [ ] 已下载状态在书架页、源页、下载页使用同一身份判断。
- [ ] 页面级测试覆盖非书架、重加、local manifest、无标题匹配与一致性。
