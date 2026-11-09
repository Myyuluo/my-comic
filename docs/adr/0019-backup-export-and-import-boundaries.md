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

## Amendment 2026-11-10（manga-backup-import-ux）

导入体验修复确定了导入作品在来源恢复、封面回退与来源缺失时的语义边界：

- **运行时来源回退**：解析 Library 中在线 Manga 的 Source 时，先精确匹配已启用的 `(extensionPackage, sourceId)`；未命中（典型是导入时 Extension 未安装、条目以占位来源落库）时，再按数字 `sourceId` 匹配已启用的 Source。刷新章节、加载章节页面、下载、获取封面、解析来源名称与来源语言共用这一规则；因此下载库的 `源名 (LANG)` 目录标签也会使用回退后 Source 的名称与语言。同一数字 `sourceId` 命中多个扩展包时视为歧义，继续按「来源未安装或已停用」降级，不随意选择候选。回退只发生在运行时，不回写条目。
- **不做身份迁移**：不修改条目的 `extensionPackage`，不重算 `bookKey`，不改写 `uid`、History 的 source identity 或下载 manifest。因此 Reading progress、Chapter 状态、History、Tag 与下载映射在 Extension 安装后保持原样，无需迁移或重新导入。从已安装 Source 浏览到同一部作品时，重复检测按 `(数字 sourceId, series key)` 命中既有占位条目，不新建重复条目。同源多语言 chip（`languageScope` 的兄弟源列表）仍按条目存储的扩展包判断，不随数字回退改变，不在本边界内。
- **封面远程回退**：Library 与 Manga 作品页的封面按「显式本地封面 → 常规本地封面文件 → 备份描述符中的 `series.coverUrl` → 占位封面」解析。远程封面只作为展示地址交给现有 HTTP 图片缓存懒加载，不依赖 Source 是否安装；它不写入「最近可用本地封面」缓存，不改变离线封面语义。导入阶段不下载封面；URL 为空、过期、防盗链或网络失败时该作品回退占位封面，不影响其他作品。
- **缺失来源文案**：未安装或已停用的 Source 在用户界面统一称为「来源未安装」。导入时把备份中的 Source 名称保存到占位条目；作品页优先使用 Source 表里的显示名（停用的 Source 行仍保留名称），没有时使用备份名称，仍未知或旧备份只显示「来源未安装」。导入完成报告用 warning notice 列出来源名称，并提示安装对应扩展后可阅读；备份未记录名称时使用本地化的「来源未安装」，不展示数字 `sourceId`，重复名称只列一次。作品页说明当前只展示本机已保存的章节，刷新与阅读需要安装对应 Extension；章节打开或下载失败提示「来源未安装，请先安装对应扩展后重试」。不自动安装 Extension，不提供跳转扩展商店的入口，也不隐藏或删除该 Manga。
- **内部占位值边界**：`mihon.unavailable` 是导入时 Extension 未安装而写入条目的内部占位来源标识，不是领域术语，也不出现在用户文案中；用户可见概念只有「来源未安装」。备份导出会跳过这类占位来源的图源设置，不写入无法对应到可安装 Source 的配置。

**Consequences**

- 安装并启用 Extension 后，再次打开作品或刷新即可阅读，无需重新导入或重启；Extension 被停用或卸载后仍按「来源未安装或已停用」降级。
- 数字 `sourceId` 在多个已启用 Extension 间不唯一时，作品保持不可解析，而不是冒险打开错误站点。
- 远程封面回退依赖备份中保存的 URL；URL 失效时作品继续显示占位封面。
- 条目的来源身份始终是导入时写入的值；将来若需要改写身份，必须单独决策并迁移 History、Tag 与下载映射。
- 旧备份或旧条目缺少来源名称时只显示「来源未安装」，不伪造名称。

## Amendment 2026-11-10（manga-library-membership）

「未入书架已读作品的边界」按 Library membership 模型修订：

- **导出**：备份中的 `favorite=true` 条目只来自书架成员；「所有已读作品」仍把非书架已读作品写成 `favorite=false`，以保留阅读记录。
- **导入**：`favorite=false` 条目现在会创建或合并一条持久化的非书架 Manga（Library membership=false），恢复章节、阅读进度与已读，有阅读记录时恢复 History，但**永不创建 Library 条目**，也不恢复 Tag、订阅或 Tracking。原文「只恢复其最新一条 History」按此扩展理解；「本机已有更新的 History 时不覆盖、作品已在本机 Library 时复用其身份」不变。
- **导入后下载匹配**：对成功导入的 Manga，在 `downloads` 与带 manifest 的 `local` 中按 `pages.json` 身份匹配并复用已有文件夹、写入章节映射；不额外创建 Library 条目；全量重建仍是用户手动触发的动作。
