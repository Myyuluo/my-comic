---
status: accepted
---

# 备份导出使用 Dart gzip + protobuf，并确定 Tag/分类与导入补齐边界

ADR 0005 原计划在 JVM sidecar 中复用 Mihon 备份模型，v1 只导入；ADR 0007 已把导入解析改为 Dart。本次交付导出后，my-comic 需要生成 Mihon v0.21.3 可读取的 `.tachibk`，并让 my-comic 自己的备份往返时恢复 Tag、应用设置与未入书架作品的 History。我们决定：

- **导出格式与实现**：导出产物仍是标准 `.tachibk`——gzip 压缩的 protobuf，字段号严格对齐 Mihon v0.21.3。写入器由 Dart 手写实现，与 Dart 解析器逐字段对应，不依赖 JVM sidecar；Mihon 与 my-comic 都能导入该产物。
- **偏好值类型**：应用设置与图源设置只使用 Mihon 的六种标准偏好值类型（Int、Long、Float、String、Boolean、StringSet）及其标准序列名。Mihon 遇到未知序列名会中止整份恢复，因此不使用自定义值类型；无法用标准类型表达的值不写入备份。
- **Tag / Category 双向映射**：导出时每个 Tag 写成同名 Mihon Category，Category 顺序取 Tag 顺序，每部作品引用其 Tag 对应的分类；导入时每个 Category 按名称创建或复用 Tag，并把分类顺序恢复为 Tag 顺序。Tag 颜色不属于 Mihon 分类格式，不跨备份保留。Mihon 的 Default（不属于任何 Category）对应 my-comic 的「书架」页签。
- **应用设置键名**：导出与导入都使用 my-comic 自己的设置键名，不做 Mihon 键名映射。Mihon 会安全保存不认识的键，因此不影响它恢复；导出时设备本地键始终排除，凭据仅在显式勾选「包含敏感设置」时写入。my-comic 导入只接受自己已知的键，设备本地键跳过，本机已有值优先，缺失值才补齐；已知键出现未知值类型时在写入前中止整次导入。
- **未入书架已读作品的边界**：导出时未加入 Library 但已有 History 的在线作品写成 `favorite=false` 条目。导入 `favorite=false` 条目时永不创建 Library 条目，只恢复其最新一条 History（作品快照、标题、封面、最近阅读时间与可用的章节 URL、阅读时长）；本机已有更新的 History 时不覆盖，作品已在本机 Library 时复用其身份以避免重复历史。无阅读时间戳、缺少作品 URL 或本机记录更新的条目会跳过并计入导入报告。

**Considered Options**

- **继续按 ADR 0005 在 sidecar 中实现导出**：可复用 Mihon 的 Kotlin 模型，但 sidecar 构建不可用，且会与 ADR 0007 已落地的 Dart 解析器形成两套格式来源；Dart 写入器可直接复用解析器的字段定义与合成 fixture。
- **把 my-comic 设置键名映射为 Mihon 键名**：能让 Mihon 应用部分设置，但两边的键语义并不一一对应，且 Mihon 对未知键是安全保存；映射会制造错误对应。该路径明确不在范围内。
- **只导出 Library**：实现更简单，但未入书架已读作品的 History 会丢失，my-comic 自己的迁移不完整。
- **用自定义偏好值类型保存复杂设置**：表达力更强，但 Mihon 遇到未知类型会中止整份恢复；宁可不导出这类值。
- **把 `favorite=false` 作品导入为 Library 条目**：能让作品出现在书架，但会违背「未入书架」语义并意外塞满书架；History 才是需要保留的数据。
- **继续把 Mihon Category 导入为隐藏合集**：避免改动旧数据，但 my-comic 只有 Tag 这一个用户分组概念；隐藏合集对用户不可见，也不出现在漫画页页签。

**Consequences**

- 导出的 `.tachibk` 与导入解析器共享 Mihon v0.21.3 schema；任一侧升级字段都需要同步另一侧。
- 应用设置与图源设置只能承载六种标准值；其它形状的设置在备份中被跳过，不保证完整迁移。
- Tag 颜色不会跨备份保留；导入时新建的 Tag 使用默认外观，已存在的同名 Tag 保留本机颜色。
- 未入书架 History 依赖备份中的来源身份与作品 URL；缺少这些信息时无法恢复，只能跳过并报告。
- 导入遇到已知键的未知偏好值类型时会中止，不留下半导入状态。
- 以前导入产生的隐藏合集保持原样、不自动迁移为 Tag；重新导入同一份备份会按新映射写入 Tag，旧隐藏合集不会因此消失。
- 真实 Mihon 备份只作本地手工验证；自动化测试继续使用合成 fixture，不提交 `.tachibk`。

## Amendment 2026-11-10（manga-ux-backup-batch）

插件商店导出**仅限 manga Extension store**。MyComic 是漫画-only 应用；Mihon v0.21.3 的 `BackupExtensionStore` 没有 media-kind 字段，无法表达 Aniyomi（视频）store，导出后在导入端只会被重建为漫画 store。因此 Aniyomi store 不写入备份，导出实现（`_MangaExtensionStoreExportSection`）与测试都显式按 manga-only 命名与断言。
