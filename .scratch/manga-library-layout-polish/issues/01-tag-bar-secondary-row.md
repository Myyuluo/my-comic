# 01: 标签栏移到标题下方的二级浮动行

**What to build:** 漫画页的标签栏离开主 chrome 页签位，成为「漫画」标题下方的二级浮动胶囊行，视觉采用图一的二级胶囊形态。标签的书架固定、单选、排他归属、数量、管理标签入口、随滚动收放全部保持。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 标签栏渲染在标题下方的二级浮动行，主 chrome 行不再显示标签栏。
- [x] 视觉为图一的二级胶囊形态：中性配色、选中段填充、贴合内容宽。
- [x] 「书架」固定最左；标签多时在胶囊内横向滚动，「书架」保持可见。
- [x] 单选、排他归属、多标签归属与每个页签的数量保持不变。
- [x] 数量使用更轻的次要色小号数字；标签名截断时数量不截断。
- [x] 搜索、阅读状态筛选、漫画下载筛选仍只在当前标签页签的集合内生效。
- [x] 「管理标签」仍在右上角动作组，标签栏本身不承担管理入口。
- [x] 二级行随主 chrome 行一起滚动收起 / 弹回，内容首行不被浮动行遮挡。
- [x] 书籍 / 视频等其他媒体库的标签行为不受影响。

## Answer

Implemented in `d98f2ffc`, merged as `768f6e71`. 新增 `MediaLibrarySecondaryRowSlot`，标签栏从主 chrome 页签位移到标题下方二级浮动行；`MangaTagTabBar` 改为二级胶囊外观并复用共享 `FushiCompactSecondaryTabsFrame`；书架固定、单选、排他归属、数量、管理标签入口、滚动收放全部保持。Code review fixes in `106ad7d0`, merged as `cd805538`.
