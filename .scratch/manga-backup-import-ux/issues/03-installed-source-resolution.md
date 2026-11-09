# 03: 已安装扩展的导入作品恢复可读

**What to build:** 导入时因扩展未安装而持久化为 `mihon.unavailable` 的 Library 作品，在扩展安装后无需重新导入即可阅读：Mihon 来源解析增加按数字 `sourceId` 的运行时回退，并让刷新、阅读、下载、封面与来源名称解析共用同一规则；从已安装来源浏览同一作品时避免重复入库。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 来源解析先精确匹配 `(extensionPackage, sourceId)` 且启用；没有精确匹配时按数字 `sourceId` 匹配已启用 Source。
- [ ] 同一 `sourceId` 命中多个已启用来源时视为歧义，不随意选择。
- [ ] 扩展未安装或已停用时仍按现有「来源未安装或已停用」语义降级，不崩溃。
- [ ] 刷新章节、加载章节页面、下载章节、获取封面与来源名称解析都使用同一回退规则。
- [ ] 导入时扩展未安装、之后安装并启用的作品可以直接打开章节与下载，无需重新导入。
- [ ] 运行时回退不修改 `extensionPackage`、`bookKey`、`uid`、History 身份或下载 manifest。
- [ ] 阅读位置、章节已读状态、History、Tag 分配与下载映射在修复后保持原样。
- [ ] 从已安装来源浏览到同一部作品时，`find` 按 `(sourceId, series key)` 命中已有占位条目，不创建重复 Library 条目。
- [ ] 已下载章节不依赖 Source 仍可打开。
- [ ] 页面级测试覆盖占位条目 + 已启用真实 Source 的刷新、页流、下载、封面解析、来源名称与重复检测；真正缺失来源仍失败。
