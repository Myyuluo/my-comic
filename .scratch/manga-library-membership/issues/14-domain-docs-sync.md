# 14: 领域文档与 ADR 同步

**What to build:** 更新领域文档，记录 Library membership、非书架 Manga、非破坏移出、下载身份与 Mihon 风格清理数据库的语义，并同步相关 ADR。

**Blocked by:** 01（Library membership 基础）、02（非书架行与在线阅读）、03（显式加入书架翻转 membership）、04（非破坏移出书架）、05（非书架阅读功能）、06（下载身份与文件夹复用）、07（已下载状态脱离书架）、08（非书架下载与删除下载）、09（失败下载取消）、10（导入非书架行与 History 修复）、11（导入后自动匹配下载）、12（重建下载索引）、13（清理数据库 Mihon 对齐）

**Status:** resolved

- [x] GLOSSARY 新增/更新：Library membership、Non-library Manga、Remove from Library（非破坏）、Download identity、Clear database（Mihon 对齐）、History（仍每 Manga 一条）。
- [x] 新增 ADR：Library membership 与非书架行模型、非破坏移出、非书架功能边界。
- [x] 更新 ADR 0012：文件夹身份与复用规则（manifest 身份优先，无 manifest 保持 `(2)`）。
- [x] 更新 ADR 0017：失败下载同时提供重试与取消。
- [x] 更新 ADR 0018：History 身份、旧快照兼容与导入修复。
- [x] 更新 ADR 0005/0019：`favorite=false` 导入为非书架行及导出边界。
- [x] 在 ADR 0008 下记录移出文案、清理数据库 UI、加入书架提示的批准。
- [x] 文档只描述用户可见行为与领域语义，不写会过时的实现细节。
- [x] 不修改代码、测试或 spec。

## Answer

领域文档已按 Library membership 模型同步完成，仅改动 `GLOSSARY.md` 与 `docs/adr/`，未触碰代码、测试或 spec。

**GLOSSARY.md**
- 新增 **Library membership（书架归属）**：明确书架专属读取点（书架页、Home 继续阅读、Tag 页签与计数、订阅/自动追更、更新探测、备份的「书架中的作品」）与使用全部 Manga 的读取点（阅读器、Chapter 状态、History、下载与下载索引）的边界；加入/移出只翻转状态，不重建记录。
- 新增 **Download identity（下载身份）**：运行时 + 数字 Source ID + series/manga key，扩展包名仅作 tie-breaker；目录名不参与。
- **Non-library work** 更名为 **Non-library Manga（非书架漫画）**：持久化、可阅读/下载/写 History 与统计，但不进书架、Home、Tag、更新探测、订阅与备份书架范围，也不能分配 Tag/订阅/Tracking；下载任务出现在下载页。
- 重写 **Remove from Library（移出书架）** 为非破坏语义：保留记录、Reading progress、已读、下载文件与索引、History；「同时删除本地文件」在在线作品上保留非书架记录，在本地作品上连记录与阅读状态一起删除（History 保留）；「同时删除统计数据」仍仅显式勾选时生效。
- 重写 **Add to Library（加入书架）**：已有非书架记录时只翻转同一条记录，不新建；在线作品从作品页执行，本地作品在作品页/本地图源选择模式/点开阅读时登记。
- 更新 **Manga**、**Missing source**、**Library**、**History**、**Reading statistics**、**Download library**、**Download index**、**Rebuild download index**、**Unindexed**、**Import**、**Export**、**下载页**，使书架归属与全部 Manga 的区分一致；**Clear database** 更名为 **清理数据库** 并对齐 Mihon 语义（按 Source 多选、默认保留有阅读记录的作品、只删非书架记录及其历史）。

**ADR**
- 新增 **ADR 0020**《Manga 持久化与书架归属分离：非书架记录、非破坏移出与功能边界》：记录 membership 模型、非书架记录的创建/复用、显式加入书架翻转、非破坏移出与两个删除选项、非书架功能边界，以及 Local source 的静默登记与移出行为；列出四个被否方案与后果（书架读取点必须显式过滤等）。
- **ADR 0005**：`favorite=false` 导入从「只恢复 History」扩展为创建/复用非书架 Manga，并记录导出边界不变与导入后下载匹配。
- **ADR 0008**：记录用户批准的移出书架文案、清理数据库 UI、非书架下载完成后的「加入书架？」提示，均复用 Fushi v3.0.0 既有组件与 tokens。
- **ADR 0012**：新增文件夹身份复用修订——按 `pages.json` 的 Download identity 复用已有文件夹并立即重建章节映射；无法唯一确定或没有 manifest 时保持 ` (2)` 安全规则；已有重复文件夹不自动合并。
- **ADR 0013**：移出书架默认保留 Local source 记录并翻转为非书架；勾选「同时删除本地文件」时删除原作、记录与阅读状态（History 保留）。
- **ADR 0017**：下载页任务不要求书架成员身份；失败行同时提供「重试」与「取消」。
- **ADR 0018**：History 归属扩展到全部 Manga，取消「源页阅读先静默加入 Library」；记录导入身份与快照、旧快照回退匹配、清理数据库与移出时保留 History，并声明 ADR 0020 取代上一修订的移出删除语义。
- **ADR 0019**：`favorite=false` 导入创建非书架记录且永不进 Library，导出边界与导入后下载匹配同步修订。
