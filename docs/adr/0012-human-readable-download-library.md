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
