# 12: 最终验收

**What to build:** 对独立化后的 MyComic 做最终验收：全量静态检查/测试、Windows debug/release 构建、安装包、全新安装与关键用户路径冒烟，确认 Fushi 只剩 allowlist 中的来源记录。

**Blocked by:** 11

**Status:** ready-for-agent

- [ ] 运行 `flutter analyze`，无新增问题。
- [ ] 运行相关 `flutter test` 与 Windows golden；记录已知失败，确认没有新增失败。
- [ ] 构建 `flutter build windows --debug` 与 `--release`；构建 Inno 安装包。
- [ ] 手动卸载旧版，全新安装当前包；确认安装目录、快捷方式、卸载项、窗口标题、About、通知均为 MyComic。
- [ ] 冒烟：首次启动三步 Onboarding → 选择 Content root → 完成/重启 → 进入 Library。
- [ ] 冒烟：语言切换四种语言；繁体系统默认落 `zh-HK`。
- [ ] 冒烟：Extension store 安装/启用 Source；Library 添加/移除；Manga 作品页；Reader；History；Download；Local source；Backup 导入/导出。
- [ ] 冒烟：更新检查只查 `Myyuluo/my-comic`；无 release 时显示“已是最新”。
- [ ] 运行 Fushi 引用扫描器：只剩 LICENSE、第三方声明、UPSTREAM.md、ADR、历史文档和 README/About 署名。
- [ ] 运行未使用 l10n key 扫描器：零结果或只剩 allowlist。
- [ ] 记录验收结果、已知失败和残余项；更新本 ticket 的 `## Answer`。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。这是文档层面的最后一张 ticket；不要在此顺手重构未列出的模块。
