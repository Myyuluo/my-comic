# 07: 三步漫画版新手引导

**What to build:** 重写 Onboarding 为三步：欢迎（语言/主题）→ 选择 Content root（展示 `downloads`/`autobackup`/`local` 最终路径）→ 完成说明。复用 Fushi 向导组件；新装用户首次启动显示，已有用户不被打扰；设置中可重新打开。

**Blocked by:** 05、06

**Status:** ready-for-agent

- [ ] 用现有 Onboarding 步骤序列纯函数生成三步：`welcome` → `storage` → `finish`。
- [ ] 欢迎步：复用现有语言选择器与明暗主题选择器。
- [ ] 存储步：选择一个 Content root；展示将创建的 `downloads`、`autobackup`、`local` 最终路径；复用现有目录选择器和 Content root 校验；选择后只写偏好。
- [ ] 完成步：只显示说明文字与“完成”按钮；文案使用“MyComic 是 Mihon 兼容的桌面阅读器，支持导入 Mihon Backup 和使用 Extension store”；不提供 Backup 导入/Extension store 操作按钮。
- [ ] 重启时机：用户点“完成”时，如果 Content root 有变化才重启；没有变化则不重启。
- [ ] 首次启动门控：新增 Onboarding 完成偏好，默认未完成；用现有 `first_time_setup` 标记避免已有用户看到。
- [ ] 在“设置 → 系统与关于”增加“重新打开新手引导”入口，复用现有设置行组件。
- [ ] 复用 Fushi v3.0.0 的向导组件、主题、spacing tokens 和布局；不照搬 Mihon Android 截图视觉。
- [ ] 验证：步骤序列、目录选择、重启时机、首次启动门控、设置重开入口的测试；Windows 手动走一遍。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。本 ticket 是 ADR 0008 UI fidelity 的显式例外；其余 UI 不改。
