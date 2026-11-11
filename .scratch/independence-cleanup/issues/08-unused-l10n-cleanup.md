# 08: 未使用 l10n key 清理

**What to build:** 在非漫画功能删除和 Onboarding 重写完成后，运行未使用 key 扫描器，删除不再被剩余代码引用的 l10n key，并重新生成/校验四种语言。

**Blocked by:** 07

**Status:** ready-for-agent

- [ ] 运行 01 建立的未使用 l10n key 扫描器；排除生成的 `strings.g.dart` 与动态访问白名单。
- [ ] 删除无引用的 base key，并同步删除四个 locale 中的同名 key。
- [ ] 保留漫画域、设置页、Onboarding、About/许可证、语言选择器等仍在使用或动态引用的 key。
- [ ] 删除已删除功能的文案（小说、视频、词典、Anki/SRS、听书、同步、AI、反馈、排行榜、Tracking、统计、OCR、浏览器扩展、PDF、首页 dashboard 等）。
- [ ] 执行 `dart run slang` 重新生成；跑 i18n completeness、sorted、mojibake 与语言切换测试。
- [ ] 验证：扫描器报告为零（或只剩 allowlist）；四种语言 key 集合一致；无空值/缺 key。
- [ ] 不改变剩余 key 的语义；只删 key，不做无关重命名。

**Notes:** 参考 [spec](../spec.md)。删除顺序必须是“先删代码，再删 key”，避免删掉仍被死代码引用、随后又需要恢复的 key。
