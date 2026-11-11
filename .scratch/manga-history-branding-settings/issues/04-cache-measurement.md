# 04: 清除缓存只计量可清理内容

**What to build:** 「清除缓存」显示的占用大小只包含实际可清理的缓存；WebView 步骤排除 GPU/Shader/运行时组件并返回真实释放字节，避免“清不干净”的误导。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] WebView 占用测量只统计实际会被清理的 HTTP cache（以及 CDP 确实清掉的子目录）；不统计 GPU/Shader/Dawn/组件/站点数据。
- [x] WebView 清除返回真实 `freedBytes`（清理前后测量差异），不再硬编码 0。
- [x] 缓存大小展示与清除范围一致；清完后正常渲染重新生成的封面/图片缓存不被误报为“未清理”。
- [x] 清除缓存继续保留登录态、源 Cookie、WebView 配置、History、数据库、Download library 与 Local source。
- [x] 部分失败仍报告 partial success 并提示重试。
- [x] 不新增“旧版遗留清理”功能；不删除 `GlobalLookupWebView2`、日志、DB 或当前图片缓存索引。
- [x] 测试覆盖：测量只含可清理目录、freedBytes 非零、partial success、保留登录/DB。
- [x] 不改 UI 视觉，仅修正计量与结果文案（ADR 0008）。

## Answer

Implemented in `b953638d`, merged as `64a1f11f`（无冲突）。`kMangaWebViewSafeCacheSubdirectories` 收敛为 CDP `Network.clearBrowserCache`（`NetworkContext::ClearHttpCache`）确实会清理的 `EBWebView/Default/Cache`，移除 `Code Cache`、`GPUCache`、`DawnCache`、`GrShaderCache`、`ShaderCache` 等运行时组件子目录，使占用展示与清理范围一致。`MangaWebViewCacheClearStep.clear` 在清理前后各测一次可清理目录大小，以真实差值报告 `freedBytes`（测量失败按 0 计，不影响清理）；单个 profile 失败继续计入 `failedEntries` 并报告 partial success。站点数据（cookies / localStorage / IndexedDB / Preferences）、登录态、History、数据库、Download library 与 Local source 均不读取、不删除；未新增遗留清理功能，未改 UI 视觉。

测试（fushi/，`flutter test`）：`manga_webview_cache_clear_test.dart`、`manga_cache_clear_service_test.dart`、`manga_cache_clear_settings_test.dart` 共 20 个用例全部通过，覆盖只统计可清理目录、真实 freedBytes、partial success、保留登录态/数据库等场景。
