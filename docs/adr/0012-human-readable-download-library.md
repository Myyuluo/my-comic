---
status: accepted
---

# 在线下载库使用人类可读目录，身份由 pages.json 与数据库映射保证

当前在线漫画下载目录是 `mihon-<hash>/chapters/<sha256(chapterKey)>`，用户无法在资源管理器里找到对应漫画/章节。我们决定把 Download library 改为 `downloads/{source}/{manga}/{chapter}/`（后续也可 `{chapter}.cbz`）：`source` 用 Source 显示名，`manga`/`chapter` 用可读名称并做 Windows 文件名净化；章节内页图平铺为 `001.jpg…`，元数据 `pages.json` 带 Source/Manga/Chapter 的稳定 ID 与现有页表；目录名不是身份，数据库保存 `chapterKey → 实际目录名` 映射，Rebuild download index 用 `pages.json` 的 ID 重新关联。标题/源改名不自动重命名目录；同名用 `[扫译组]`/`(2)` 后缀；路径超长时截断并加短哈希。

**Considered Options**

- **保持哈希目录**：稳定，但用户不可读，正是要解决的痛点。
- **纯标题目录、无元数据**：可读，但同名、改名、重建索引时会错配。
- **只存数据库映射、不写 pages.json**：重建可用，但用户移动目录或数据库丢失后无法恢复。

**Consequences**

- Download library 必须写 `pages.json`；Reader、Importer、Interconnect 等路径消费点改用映射，不再用标题推导。
- `downloads` 只是 Mihon-style layout，不是 Mihon 本地源根；`localcomic` 才是 Local source。
- 用户手动改名后，重建按 ID 恢复；`pages.json` 丢失时降级为按名称匹配或本地条目。
- CBZ 章节的 `pages.json` 放包根；文件夹章节放同级。

## Amendment 2026-11-08

CBZ 从「后续也可」变为新下载的默认形态：设置新增「保存为CBZ压缩包」开关（默认开启，见 ADR 0015）。新开始的在线下载写 `downloads/{source}/{manga}/{chapter}.cbz`，包根平铺页图与 `pages.json`；已存在的文件夹章节原样保留，不做批量转换，两种 Chapter container 共存。数据库把容器类型显式化（folder / archive，schema v2→v3），已有行迁移为 folder；章节载体抽象、阅读、缩略图、删除、Rebuild download index 与互联读取都按容器类型分支。写入仍先落到 `.staging/{jobId}`，再生成同目录的 `{chapter}.cbz.tmp` 并原子改名为最终 `.cbz`，取消或崩溃不会留下可见的半成品。

## Amendment 2026-11-08（local-source-polish）

新下载的 Source 目录名改为 `源名 (LANG)`：语言取 Source 的语言原值并大写，保留子标签（`zh-Hans` → `ZH-HANS`）；语言为空、`all` 或 `multi` 时不写语言后缀。已有 Source 目录不重命名，继续按源身份复用；`pages.json.source.name` 仍保存裸源名，语言只体现在目录名上。目录名的净化、截断与同名冲突后缀规则不变。

原文（Consequences 小节）中的 `localcomic` 按 `local` 理解：本地源根目录已更名为 `local`，见 ADR 0013 的 2026-11-08（local-source-polish）修订。该句的语义不变——`downloads` 不是 Mihon 本地源根，`local` 才是 Local source。
