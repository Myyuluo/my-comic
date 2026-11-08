# 04: 发现页聚合搜索「查看全部」

**What to build:** 发现页「搜索所有来源」的聚合搜索结果中，每个来源分区的标题行右侧新增「查看全部」；点击进入该来源自己的搜索页，搜索框预填当前关键词并自动执行搜索，返回后聚合页保留原状态。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 聚合搜索结果的每个来源分区标题行右侧显示「查看全部」（文字 + 右箭头，复用现有样式）。
- [x] 加载中、空结果、失败、有结果时都显示该入口。
- [x] 点击后打开该来源自己的搜索页，搜索框预填当前关键词并自动执行搜索。
- [x] 来源搜索页显示该关键词的完整结果并支持分页。
- [x] 从来源搜索页返回后，聚合搜索页原有结果与状态保留。
- [x] 普通提交搜索（不点「查看全部」）的现有行为不变。

## Answer

Implemented in `fdcccae9`, merged as `aff4e729`. `MihonSourceBrowsePage` / `OnlineSourceBrowsePage` 增加 `initialQuery`（prepare 后预填、切到搜索态并自动执行）；聚合搜索每个来源分区无条件渲染 `DiscoveryViewAllButton`，点击以当前关键词进入该来源搜索页。30 个相关测试通过。
