# 04: Online download library（核心）

**What to build:** 下载在线漫画时，文件落在 Content root 的 `downloads/{source}/{manga}/{chapter}/`：source/manga/chapter 是可读名称，章节内平铺 `001.jpg…` 与带稳定身份的 `pages.json`。下载使用 staging，完成后整章 rename；半成品不会被视为已下载。阅读器能打开新布局；数据库保存 `chapterKey → 实际目录名` 映射，删除也通过映射定位。在线漫画「移出书架」时询问是否删除已下载文件。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 下载在线章节后，资源管理器里能看到 `downloads/{source}/{manga}/{chapter}/001.jpg…` 和 `pages.json`
- [ ] `pages.json` 包含 Source/Manga/Chapter 稳定 ID、页表与下载时间；页图平铺、无 `images/` 前缀
- [ ] source 层存在；名称经过基础 Windows 净化；不存在覆盖已有目录的情况
- [ ] 下载写入 staging，完成后整章 rename；半成品不出现在已下载索引里
- [ ] 阅读器能打开新布局的章节；删除章节/整部漫画使用数据库映射而非标题推导
- [ ] 在线漫画移出书架时询问是否删除已下载文件
- [ ] 下载写入、阅读、映射、删除均有自动化测试
