# 12: WebView/HTTP 缓存清理

**What to build:** 在「清除缓存」动作中安全清理默认与漫画 WebView profile 的 HTTP 缓存，保留 cookies/localStorage/IndexedDB；无法安全清理时跳过并报告部分成功。

**Blocked by:** 11（清除缓存（图片/磁盘））

**Status:** ready-for-agent

- [ ] 通过 CDP `Network.clearBrowserCache` 或等价的 cache-only API 清理默认与漫画 WebView profile 的 HTTP 缓存。
- [ ] 没有可见 WebView 时临时创建 headless WebView（加载 `about:blank`）执行清理后销毁。
- [ ] 绝不整目录删除 WebView2 数据目录；不删除 cookies、localStorage、IndexedDB、Preferences。
- [ ] 只清 Mihon 的封面缓存子目录，不删除整个 Mihon 数据目录（其中有登录态与扩展数据）。
- [ ] 某类 WebView 缓存无法安全清理时跳过，并在结果中体现部分成功；不要求重启。
- [ ] 可控 fake 或页面级测试覆盖清理调用、登录态保留与部分成功提示。
- [ ] `flutter analyze`、定向测试、Windows 构建通过。
