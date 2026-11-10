---
status: accepted
---

# 重建下载索引只重链书架成员，检索已下载负责发现并入架

用户导入备份或切换 Content root 后，本机 `downloads` / `local` 里可能已有文件，而对应作品尚未在书架。旧「重建下载索引」同时承担两件事：重新关联已有作品的下载章节，以及给磁盘上没有记录的作品自动补建 Manga 条目、翻转 Library membership。后者会把用户从未收藏或主动移出的作品重新塞回书架，违背 Library membership 语义（ADR 0020），报告里也会出现与「恢复」动作不符的「新增 N 部作品」。我们决定把恢复与发现拆成两个用户动作：

- **Rebuild download index（重建下载索引）是恢复动作**：只扫描当前 Content root 的 `downloads` 与 `local`，只查询 `membership=true` 的 Manga；按 `pages.json` Download identity → 已记录且仍在 `downloads` 内的路径 → `downloads` 无 manifest 目录的文件夹名回退，重新关联 Chapter 与下载状态。它不读取或改写非书架 Manga，不新增 Manga，不翻转 Library membership，不分配 Tag；`local` 无 manifest 目录不按标题匹配，也不合成「本机章节」。只增改数据库记录与映射，不移动、重命名或删除用户文件；重复运行幂等。报告只含扫描、匹配、重链、缺失、跳过（含歧义）、失败与取消。
- **Scan downloaded（检索已下载）是发现动作**：只扫描当前 Content root 的 `downloads`，候选作品必须至少有一个完整 Chapter container。归属顺序：已在 Library → 跳过；已有 `membership=false` 记录 → 原地提升并保留阅读状态、已读、History 与下载映射；有 tombstone → 用户显式执行本动作时复活并清除墓碑；有 `pages.json` 且 Source 已安装启用 → 建立在线条目并写入下载索引；否则建立指向该 `downloads` 目录的 Local 条目并加入 Library，报告单列「因来源未安装降级」。多个目录证明同一身份时跳过并报告歧义，不猜。它不移动、复制或删除文件，不重链已在 Library 的 Manga，重复运行幂等。
- **Library membership 只能由用户显式动作改变**：磁盘上存在内容不等于加入书架。下载索引的恢复动作不得隐式改变 membership：Rebuild 永不改变；Scan downloaded 只在用户明确触发该动作时加入、提升或复活作品。既有的 Local source 登记规则（ADR 0013）与「导入不创建 Library 条目」的边界（ADR 0019）保持不变。
- 两个动作都保留确认框、可取消进度与结果报告，设置行整行可点，视觉继续复用现有组件（ADR 0008）。取消时已完成的更新保留；重建取消仍广播下载索引可能变化。

**Considered Options**

- **保留旧 Rebuild 的全量恢复（自动补建条目）**：一次动作修好所有磁盘内容，但会把用户没有收藏或主动移出的作品重新塞进书架，违背 membership 语义；恢复动作不应带发现副作用。
- **自动或后台运行 Scan downloaded**：用户无需操作，但会在无提示时改变 Library membership，违背「书架归属只能由用户显式动作改变」。
- **用一个动作加开关区分重链与发现**：少一个设置行，但确认文案、进度与报告都要分支，用户更容易误触发现副作用。
- **把 `downloads` 的文件移动到 `local` 或反过来**：能让单一扫描覆盖两种形态，但移动用户文件违反不可破坏原则。

**Consequences**

- 设置「下载索引」下有两个语义明确的动作；重建报告不再出现「新增作品」，发现数量只出现在检索报告。
- 非书架 Manga 仍可通过阅读、History 与清理数据库管理，但不会被 Rebuild 读取或改写。
- 用户主动移出的作品不会因重建而复活；只有显式运行 Scan downloaded 才会清除 tombstone。
- 两个动作都幂等，不产生重复记录或章节；文件始终留在原地。
- 不引入数据库 schema 变更，不改变 Download identity、tombstone、Local source 与 Backup 的既有边界。
- 新增与修改文案必须在全部 locale 中区分「重链」与「发现 / 加入」，并由 i18n 完整性测试守护。
