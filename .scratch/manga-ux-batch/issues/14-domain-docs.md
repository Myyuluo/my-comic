# 14: 领域文档核对（GLOSSARY + ADR 0018）

**What to build:** 在功能落地后核对 `GLOSSARY.md` 与 ADR 0018，确保文档与实现后的用户可见行为一致；文档只保留领域语义，不写实现细节。

**Blocked by:** 04（本地源自动换章与章级已读操作）、07（批量删除已下载章节）、10（历史生命周期边界）、12（WebView/HTTP 缓存清理）、13（清除数据库）

**Status:** resolved

- [x] 核对 `History（历史）`：每部 Manga 一条、来自阅读会话、与 Reading progress 解耦；删除历史不影响进度。
- [x] 核对 `Incognito reading（无痕阅读）`：不新增/不更新历史页条目，已有历史保留。
- [x] 核对 `Non-library work（未入书架作品）`、`Cache（缓存）`、`Clear cache（清除缓存）`、`Clear database（清除数据库）`。
- [x] 核对 `docs/adr/0018-history-data-source-and-deletion.md` 的状态、决策与后果与实际实现一致。
- [x] 确认 GLOSSARY 不包含表名、文件路径或其它易过时的实现细节。
- [x] 如实现与 spec 有偏差，先更新 spec 的对应段落再更新文档。

## Answer

Merged as the ticket 14 integration merge (docs-only). GLOSSARY、ADR 0018 与 spec 已按实现核对：无痕只抑制自动 History 信号、在线作品开读先静默入库、历史/缓存/清除数据库范围与本地源行为均已对齐；无代码改动。
