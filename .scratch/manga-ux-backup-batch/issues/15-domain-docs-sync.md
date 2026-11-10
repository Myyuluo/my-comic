# 15: 领域文档与 ADR 同步

**What to build:** 更新领域文档，使 GLOSSARY 与 ADR 反映本次交付：移出书架可显式删除本地原作、Tag 与 Mihon 分类的双向映射、MyComic 可以创建 Backup，以及导出与导入补齐的边界。

**Blocked by:** 01（统一移出书架弹窗与单本删除语义）、04（加入书架前选择标签：核心选择器与在线作品页）、07（创建备份页与导出基础）、13（导入：Mihon 分类恢复为标签）、14（导入：应用设置与未入书架已读作品）

**Status:** resolved

- [x] GLOSSARY 的 Remove from Library 明确：Local source 文件默认保留，但用户显式勾选时可以删除。
- [x] GLOSSARY 的 Category 与 Tag 明确双向备份映射：Tag 导出为 Mihon 分类，Mihon 分类导入为 Tag；「书架」等价于 Mihon 的 Default 分类。
- [x] GLOSSARY 的 Backup/Export 明确 MyComic 可以生成 `.tachibk`。
- [x] GLOSSARY 新增或澄清 Reading statistics（阅读统计），说明其与 History、Reading progress 的区别。
- [x] ADR 0005 更新：导出已交付；导入补齐范围。
- [x] 新增 ADR：记录 gzip + protobuf 导出、标准偏好值类型、Tag/Category 映射、应用设置使用 MyComic 键名且不做 Mihon 键名映射、未入架已读作品的导入边界。
- [x] 文档只描述用户可见行为与领域语义，不写会过时的实现细节。

## Answer

Implemented in `fdcfc77e`，merged into the integration branch as `638fe5dc`。

GLOSSARY 更新：`Remove from Library` 写明「同时删除本地文件」默认不勾选、仅显式勾选时删除对应文件、删除失败时 Manga 仍留在 Library，移出固定清除 Reading progress、Chapter 已读标记与 Tag 分配，History 保留，阅读统计仅在显式勾选时移除；`Category` 与 `Tag` 写明双向备份映射（导出时 Tag 写成同名 Mihon Category，导入时 Category 按名称恢复为 Tag，「书架」页签对应 Mihon 的 Default，Tag 颜色不进入 Backup）；`Backup`/`Export`/`Import` 写明 my-comic 可在「创建备份」页生成并重新导入标准 `.tachibk`，导入为 Merge 语义且未入书架的已读作品只恢复 History；`Sidecar` 改为只负责运行 Extension，Backup 解析与生成由 my-comic 自身完成；新增 `Reading statistics（阅读统计）` 词条，说明其与 History、Reading progress 是三套独立数据。

ADR 更新：`docs/adr/0005-backup-import-export.md` 追加 2026-11-10 更新，记录导出已交付、导入补齐范围，并声明原「v1 只做导入、v1.5 再做导出」与 sidecar 复用 Mihon 备份模型的说法由本条及 ADR 0007、ADR 0019 取代；新增 `docs/adr/0019-backup-export-and-import-boundaries.md`（status: accepted），记录标准 `.tachibk` 的 Dart gzip + protobuf 写入器、只使用六种标准偏好值类型、Tag/Category 双向映射、应用设置使用 my-comic 键名且不做 Mihon 键名映射、未入书架已读作品的导入边界，并附 Considered Options 与 Consequences。

验证：`git diff --check` 通过；ADR 0019 frontmatter 为 `status: accepted`，与其余 ADR 一致且编号唯一；GLOSSARY 无重复词条。
