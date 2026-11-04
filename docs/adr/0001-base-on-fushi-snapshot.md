---
status: accepted
---

# 基于 Fushi v3.0.0 快照，而不是从零写或移植 Mihon

my-comic 需要一个 Windows 桌面漫画阅读器，同时保留 Fushi 的 UI 和 Mihon 扩展/备份能力。我们决定以 Fushi v3.0.0 的源码快照为基座，保留其 Flutter UI 和 JVM sidecar 扩展运行时，再删除非漫画域并加入 Mihon 备份兼容。

**Considered Options**

- **从零写**：UI 和扩展运行时都要重做，成本最高。
- **Suwayomi 后端 + 新 UI**：扩展与备份能力成熟，但要求用户运行本地服务器，产品形态不符合“简单桌面应用”的目标。
- **Mihon 代码移植**：Mihon 是 Android-first，UI/平台层与 Android 深度绑定；移植到桌面不是加一个 JVM target。
- **Fushi v3.0.0 快照**：直接得到 UI 和扩展运行时；代价是 GPL-3.0 衍生、大代码库和删除非漫画模块的成本。
