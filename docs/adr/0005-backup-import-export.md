---
status: accepted
---

# 备份：v1 只做导入，v1.5 再做导出，不做实时同步

Mihon 备份是 gzip 压缩的 protobuf `.tachibk`，schema 定义在 Kotlin `@Serializable` / `@ProtoNumber` 类中；Fushi 没有解析器。我们决定在 JVM sidecar 中复用 Mihon 的 Apache-2.0 备份模型类实现 `.tachibk` 解析，v1 只做导入，v1.5 再做导出，导入语义对齐 Mihon v0.21.3 的 restore 行为（Merge、缺少 Source 时警告、缺少 Tracker 时跳过并报告、可选恢复范围），不做设备间实时同步。

**Consequences**

- v1 不能从 my-comic 生成备份给 Mihon 读取；导出在 v1.5 交付。
- 导出必须正确映射 source ID、章节 URL 等字段，否则 Mihon 恢复后可能找不到源。
