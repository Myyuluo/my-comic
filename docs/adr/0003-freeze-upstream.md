---
status: accepted
---

# 冻结上游：Fushi v3.0.0 / Mihon v0.21.3

my-comic 只要求对接当前版本的 Mihon，不跟随 Fushi 或 Mihon 的后续更新。我们决定把代码基线锁定在 Fushi v3.0.0，把兼容目标锁定在 Mihon v0.21.3 和 extension-lib 1.6，不设置上游合并或自动更新。

**Consequences**

- 未来 Mihon 备份格式、扩展 API 或 Fushi 运行时变化时，my-comic 可能不兼容；这是已知且接受的代价。
- 不实现应用更新检查、自动更新或 Fushi 上游合并。

## Amendment 2026-11-11（manga-history-branding-settings）

原文 Consequences 中「不实现应用更新检查、自动更新或 Fushi 上游合并」按以下方式修订：my-comic 保留自己的应用更新检查与「更新提醒」入口，但只面向本 fork 的发布线（`Myyuluo/my-comic`）；仓库没有可用 release 时按「已是最新」处理。仍不设置上游合并，也不跟随 Fushi 的后续发布。产品身份与版本决定见 ADR 0004 同日修订。
