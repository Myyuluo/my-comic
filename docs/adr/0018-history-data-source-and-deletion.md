---
status: accepted
---

# 历史页以阅读会话记录为准，与阅读进度解耦

用户需要一个新的「历史」一级页面来展示读过的漫画，并支持单条与全部删除。现有数据里有两条候选来源：通用的 `media_open_history`（带有 `snapshotJson`，可承载未入书架作品，但漫画阅读目前不写）与 `reader_positions.updatedAt`（书架「最近阅读」排序与继续阅读在用，无痕阅读会冻结它）。

我们决定：

- 历史页以 `media_open_history` 为唯一数据源；漫画在「打开 Chapter 进入阅读器」时（含阅读器内切章）写入或更新一条记录，每部 Manga 一条。
- 记录身份是「Source + 作品 id」，因此同一部作品从「未入书架」变为「已加入 Library」后仍是同一条历史；历史页优先显示 Library 中的最新标题与封面。
- 在线作品从来源页开读章节时会先静默加入 Library，进度、已读与历史都按 Library 条目落库；作品之后仅移出 Library（保留文件）时历史仍保留。展示与重新打开所需的来源载荷存入 `snapshotJson`，点击时按来源身份打开来源作品页并拉取详情。
- 无痕阅读开启时跳过历史写入；已有历史保留。
- 删除单条或全部历史只删除历史记录，不清除 Reading progress、Chapter 已读标记或 Library 状态。删除整部作品（含文件）时一并删除其历史；仅移出 Library 保留历史。（2026-11-10 修订：见文末 Amendment——漫画的所有「移出 Library」路径始终保留历史。）
- History 不设条数上限：漫画历史写入不调用 `trimMediaHistory`，第 101 部及之后的作品仍保留。
- 本功能按全新安装设计：不回填旧阅读数据，也不写历史迁移。

**Considered Options**

- **从 `reader_positions.updatedAt` 派生历史页（不新增写入）**：实现最省，但覆盖不了未入书架作品；更关键的是，删除历史会牵动书架「最近阅读」排序与继续阅读入口，违背「删历史不删阅读进度」的要求。
- **同时读两套来源并在展示时合并**：能兼顾历史与续读，但会出现两个真相来源，去重、排序、删除语义都变复杂。
- **按 Chapter 记录历史**：信息更细，但页面只需要 Manga 粒度；单本删除要删多行，且与「每部一条」的交互不符。
- **用 `media_open_history` 作为唯一来源（选定）**：写入路径需要新建，但它天然支持未入书架作品与单条删除，并且与 Reading progress 完全解耦。

**Consequences**

- 漫画阅读器在装载章节（打开与切章）时显式写历史；漫画源不实现通用的 `openMedia` 历史记账，因此这条写入点必须覆盖所有开书路径，并读取无痕策略，避免无痕期间留下条目。
- 历史行与 Reading progress 是两套数据：删除整部作品、移出书架、清空历史等动作各自维护自己的级联边界。
- 历史页不会为功能上线前的阅读记录回填；全新安装从空历史开始。
- 未来任何「最近读过」的展示（尤其是未入书架作品）应从历史记录取，而不是从 `reader_positions` 取。

## Amendment 2026-11-10（manga-ux-backup-batch）

所有漫画「移出 Library」入口（在线 / 本地作品页、书架单卡、书架批量、Local source 页批量）共用同一个移出流程，并**始终保留 History**：移出只删 Library 条目、Reading progress、Chapter 已读标记与 Tag 分配，不删 `media_open_history`。原文「删除整部作品（含文件）时一并删除其历史」对漫画在统一移出流程中已不可达：底层删除以 `removeFromLibraryOnly` 调用，跳过 History 级联，受管漫画卷（无在线 / Local source 描述符）也不例外。独立于移出的「删除本地文件」动作仍按整部作品删除并级联清理历史，与移出流程无关。

## Amendment 2026-11-10（manga-library-membership）

History 的归属对象从「书架条目」扩展为「全部 Manga」：

- 非书架 Manga 同样写入 History；原文「在线作品从来源页开读章节时会先静默加入 Library」不再成立——源页阅读会创建或复用非书架 Manga（见 ADR 0020）。History 仍按 Manga 去重，每部一条，本 ADR「不按 Chapter 记录」的决定不变。
- 导入为有阅读记录的 Manga 写入规范来源身份与完整快照（标题、作者、封面地址、在线来源引用、Mihon 章节 URL 与阅读时间）；`favorite=false` 的非书架作品也写入其阅读进度、已读与 History。
- 历史页兼容旧版导入写入的裸快照与旧 `reader_manga` 身份：按快照中的作品键回退匹配已导入 Manga。封面按「本地封面 → 快照封面地址 → 来源封面 → 占位」回退，标题绝不显示原始 `fushi://book/...` 标识；点击时优先按已存在的 Manga 记录打开作品页（含非书架 Manga），没有记录时按快照中的在线来源打开来源作品页。
- 旧历史行不自动删除；重新导入修复后的备份可让同一作品命中规范身份。同一作品同时存在旧身份与新身份记录时只展示最新一条，History 仍保持每部 Manga 一条。
- 「清理数据库」只删除被清理非书架作品的 History（含旧身份），书架作品及其 History 保留；移出书架仍始终保留 History。
- 本 ADR 上一修订（2026-11-10 manga-ux-backup-batch）中「移出只删 Library 条目、Reading progress、Chapter 已读标记与 Tag 分配」由 ADR 0020 取代：移出默认只清 membership、Tag 与订阅/自动追更，保留 Reading progress 与 Chapter 已读；仅本地作品勾选「同时删除本地文件」时连记录与阅读状态一起删除。History 仍始终保留。
