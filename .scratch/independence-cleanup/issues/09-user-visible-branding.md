# 09: 用户可见品牌与 Windows 身份

**What to build:** 把用户可见身份和 Windows 安装/运行身份改为 MyComic：窗口标题、通知、About、安装器、图标、快捷方式、CI 产物、Release/Issue 元数据和更新检查；保留 GPL 来源署名。

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] 窗口标题、任务栏、通知、错误日志、诊断信息和 About 中的应用名改为 MyComic。
- [ ] 安装器：显示名、默认目录、程序组、桌面/开始菜单快捷方式、卸载图标、向导插画改为 MyComic；保持同一个 AppId GUID。
- [ ] 应用图标、启动图、安装器图标与 Windows ico 使用 MyComic M 标识；移除旧 Fushi 图片资源引用。
- [ ] About/版本页增加“基于 Fushi v3.0.0（GPL-3.0）”；版权行同时保留上游版权与 MyComic 版权。
- [ ] 删除/替换 fushi.moe 反馈、排行榜、统计、User-Agent 等运营端点；更新检查只查 `Myyuluo/my-comic`。
- [ ] 更新资产前缀值改为 `mycomic-`；CI 产物名改为 `mycomic-<版本>-windows-setup.exe`；不保留旧 `fushi-` 前缀兼容。
- [ ] 更新 Windows 单实例窗口查找/互斥量/安装器进程清理，使其与新窗口标题和 exe 名一致。
- [ ] 清理 GitHub FUNDING、Issue 模板、Release 标题中的上游指向；只保留 fork 仓库。
- [ ] 验证：Inno 安装包构建成功；全新安装冒烟；窗口/快捷方式/卸载项/About/通知均为 MyComic；Fushi 用户可见文案只剩 allowlist。
- [ ] 本 ticket 不做包名、目录、类名、channel 的整体重命名（由 10 处理）；必要时只改运行时值，符号名留给 10。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。干净切换：旧 `fushi://` 深链与旧 `fushi-` 更新资产不兼容。
