---
status: accepted
---

# 备份：v1 只做导入，v1.5 再做导出，不做实时同步

Mihon 备份是 gzip 压缩的 protobuf `.tachibk`，schema 定义在 Kotlin `@Serializable` / `@ProtoNumber` 类中；Fushi 没有解析器。我们决定在 JVM sidecar 中复用 Mihon 的 Apache-2.0 备份模型类实现 `.tachibk` 解析，v1 只做导入，v1.5 再做导出，导入语义对齐 Mihon v0.21.3 的 restore 行为（Merge、缺少 Source 时警告、缺少 Tracker 时跳过并报告、可选恢复范围），不做设备间实时同步。

**Consequences**

- v1 不能从 my-comic 生成备份给 Mihon 读取；导出在 v1.5 交付。
- 导出必须正确映射 source ID、章节 URL 等字段，否则 Mihon 恢复后可能找不到源。

**Update 2026-11-07**：Backup（`.tachibk`）的默认存放目录是 Content root 下的 Backup directory（`autobackup`）；导入/导出的文件选择器默认从这里开始。旧版 `.fushi.zip` 全量导出改称 App snapshot，计划弃用；本 ADR 的 v1 只导入、v1.5 导出边界不变。

**Update 2026-11-10**：导出已交付（见 ADR 0019），不再是 v1.5 计划。my-comic 的「创建备份」页可生成 gzip + protobuf 的 `.tachibk`，字段号对齐 Mihon v0.21.3；写入器与解析器一样由 Dart 实现，不依赖 JVM sidecar。导入范围同期补齐：Mihon Category 按名称恢复为 Tag（导出时 Tag 写成同名 Category，「书架」页签对应 Mihon 的 Default），my-comic 自己导出的应用设置只补齐本机缺失的已知键，`favorite=false` 的未入书架已读作品只恢复 History、不创建 Library 条目。本 ADR 原文的「v1 只做导入、v1.5 再做导出」和「在 sidecar 中复用 Mihon 备份模型」由本条与 ADR 0007、ADR 0019 取代；Merge 语义与不做实时同步的边界不变。
