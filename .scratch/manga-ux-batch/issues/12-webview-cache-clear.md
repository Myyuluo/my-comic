# 12: WebView/HTTP 缓存清理

**What to build:** 在「清除缓存」动作中安全清理默认与漫画 WebView profile 的 HTTP 缓存，保留 cookies/localStorage/IndexedDB；无法安全清理时跳过并报告部分成功。

**Blocked by:** 11（清除缓存（图片/磁盘））

**Status:** resolved

- [x] 通过 CDP `Network.clearBrowserCache` 或等价的 cache-only API 清理默认与漫画 WebView profile 的 HTTP 缓存。
- [x] 没有可见 WebView 时临时创建 headless WebView（加载 `about:blank`）执行清理后销毁。
- [x] 绝不整目录删除 WebView2 数据目录；不删除 cookies、localStorage、IndexedDB、Preferences。
- [x] 只清 Mihon 的封面缓存子目录，不删除整个 Mihon 数据目录（其中有登录态与扩展数据）。
- [x] 某类 WebView 缓存无法安全清理时跳过，并在结果中体现部分成功；不要求重启。
- [x] 可控 fake 或页面级测试覆盖清理调用、登录态保留与部分成功提示。
- [x] `flutter analyze`、定向测试通过（按批量任务指令未运行完整 Windows 构建）。

## Comments

- 2026-11-09：实现完成。新增 `MangaWebViewCacheClearStep` 并追加到 ticket 11 的清缓存步骤列表；默认与漫画 profile 各用临时 headless WebView 执行 CDP `Network.clearBrowserCache`，用完销毁；单个 profile 失败继续其余 profile 并以部分成功提示。定向测试与 `flutter analyze` 结果见提交说明；完整 Windows 构建未运行（批量任务明确要求不跑）。

## Answer

Merged as `eef5eab8`. 通过 CDP 清理默认与漫画 WebView profile 的 HTTP 缓存，保留 cookies/localStorage/IndexedDB，失败按部分成功提示。
