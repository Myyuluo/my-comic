# 06: 界面语言精简为四种

**What to build:** 把界面语言从 17 种精简为 `zh-CN`、`zh-HK`、`en`、`ja`；让系统 `zh-TW`/`zh-Hant` 落到 `zh-HK`；保留跟随系统语言、英文兜底的默认行为；确保 slang 生成在构建/CI 中确定执行。

**Blocked by:** 04

**Status:** ready-for-agent

- [ ] 删除 13 个翻译文件：`ar, de, es, fr, id, it, ko, nl, pt-BR, ru, th, tr, vi`。
- [ ] 更新 `AppModel` 的 locale 列表、语言名表与 `supportedLocales` 来源，只保留 `en-US`、`zh-CN`、`zh-HK`、`ja`。
- [ ] 增加显式映射：系统 `zh-TW`/`zh-Hant` → `zh-HK`，避免被语言前缀匹配到 `zh-CN`。
- [ ] 保持默认行为：已保存偏好 → 系统 locale → 语言前缀 → 英文兜底；不强制 `zh-CN`。
- [ ] 语言选择器剩 4 项后使用现有内联选择器；不改视觉语言。
- [ ] 删除写死 17 的测试断言；删除随浏览器扩展一起移除的语言测试。
- [ ] 删除语言后显式执行 `dart run slang`；在构建脚本/CI 增加生成与校验步骤，避免 `strings.g.dart` 缺失或陈旧。
- [ ] 验证：四种语言完整；繁体系统落到 `zh-HK`；语言切换测试通过；i18n 完整性与排序测试通过。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。`strings.g.dart` 当前被 gitignore，生成门禁是本 ticket 的硬要求。
