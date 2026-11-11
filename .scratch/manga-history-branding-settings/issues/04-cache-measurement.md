# 04: 清除缓存只计量可清理内容

**What to build:** 「清除缓存」显示的占用大小只包含实际可清理的缓存；WebView 步骤排除 GPU/Shader/运行时组件并返回真实释放字节，避免“清不干净”的误导。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] WebView 占用测量只统计实际会被清理的 HTTP cache（以及 CDP 确实清掉的子目录）；不统计 GPU/Shader/Dawn/组件/站点数据。
- [ ] WebView 清除返回真实 `freedBytes`（清理前后测量差异），不再硬编码 0。
- [ ] 缓存大小展示与清除范围一致；清完后正常渲染重新生成的封面/图片缓存不被误报为“未清理”。
- [ ] 清除缓存继续保留登录态、源 Cookie、WebView 配置、History、数据库、Download library 与 Local source。
- [ ] 部分失败仍报告 partial success 并提示重试。
- [ ] 不新增“旧版遗留清理”功能；不删除 `GlobalLookupWebView2`、日志、DB 或当前图片缓存索引。
- [ ] 测试覆盖：测量只含可清理目录、freedBytes 非零、partial success、保留登录/DB。
- [ ] 不改 UI 视觉，仅修正计量与结果文案（ADR 0008）。
