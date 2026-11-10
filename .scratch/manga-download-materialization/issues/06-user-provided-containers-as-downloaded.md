# 06: 用户提供的本地容器视为已下载

**What to build:** 没有 `pages.json` 的用户 CBZ/文件夹、以及根 manifest 单章作品，经「重建下载索引」关联后显示「已下载」、可阅读、可批量删除；`local` 根下的原件永不被删除。

**Blocked by:** 05（清库后自动重连与批量删除）

**Status:** ready-for-agent

- [ ] 没有 `pages.json` 的 CBZ/文件夹按容器名与章节关联后视为已下载。
- [ ] 根 `pages.json` 单章作品视为已下载。
- [ ] 关联后的容器可以阅读；「重建下载索引」后状态正确，即使来源未安装。
- [ ] 批量删除可以删除这些 `downloads` 容器；`local` 根下的用户原件永不删除。
- [ ] 单章根 manifest 删除时清空该作品的下载内容，但保留作品条目与阅读进度。
- [ ] 服务级与页面级测试覆盖无 manifest、根 manifest、来源未安装、删除保护；`flutter analyze` 与 Windows 构建通过。
