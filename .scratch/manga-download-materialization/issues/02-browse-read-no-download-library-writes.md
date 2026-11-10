# 02: 浏览与阅读不写 Download library

**What to build:** 打开在线源详情页、在线阅读、查看导入作品都不创建 `downloads/{source}/{manga}`、不写 `cover.jpg`；来源未安装时不请求封面、显示灰封面且不生成数字 sourceId 目录；只有真正开始章节下载才创建目录；封面只由 Cache 提供。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 打开在线源作品详情页不创建下载目录、不写 `cover.jpg`。
- [ ] 只阅读在线章节、只查看导入作品详情不创建空目录。
- [ ] 来源未安装时不创建目录、不发起封面请求、显示灰封面；不生成数字 `sourceId` 目录；已有本地下载文件仍可阅读。
- [ ] 只有真正开始章节下载时才创建 `downloads/{source}/{manga}`；下载完成后目录存在。
- [ ] 书架与详情页封面按「本地封面 → 远程 coverUrl / Cache → 占位」解析；清缓存且离线时显示占位；已有 `cover.jpg` 不自动删除。
- [ ] 页面级与服务级测试覆盖详情页、阅读、来源未安装、实际下载、封面回退；`flutter analyze` 与 Windows 构建通过。
