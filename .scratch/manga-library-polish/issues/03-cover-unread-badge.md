# 03: 漫画封面未读角标

**What to build:** 漫画封面右上角原本的书本图标改为未读章节数：没有未读章节时整个角标不显示；未读数按章的已读标记计算，读到一半的章也算未读；≥100 显示「99+」，角标宽度随内容伸缩。同时去掉漫画封面左上角的用户标签 chip，保留封面底部阅读进度条。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 漫画封面右上角显示未读章节数，不再显示书本图标。
- [x] 未读数按章节已读标记计算：没有已读标记的章计入，读到一半的章也计入。
- [x] 未读数为 0 时角标完全不显示；≥100 显示「99+」；角标宽度随内容伸缩，数字清晰可读。
- [x] 漫画封面左上角不再显示用户标签 chip；封面底部阅读进度条保留。
- [x] 在线漫画与本地图源漫画适用同一规则。
- [x] 从阅读器返回或批量标记已读后，未读数刷新。
- [x] 漫画数量较多时，进入页面与滚动不因未读计算出现明显卡顿。

## Answer

Implemented in `3227e619`, merged as `ce78c0f9`. 新增 `getMangaShelfReadSnapshot()` 批量快照与 `computeMangaShelfUnreadCounts`；封面右上角改为未读数（0 隐藏、99+、宽度自适应），左上角用户标签移除，进度条保留。Code review 后把章节 key 解析收进 `MangaShelfChapterSourceKeys`（`d28f6ff1`，merged `68e80c69`）。
