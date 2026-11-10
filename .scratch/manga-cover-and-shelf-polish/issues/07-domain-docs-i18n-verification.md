# 07: Domain docs、i18n 与全量验证

**What to build:** 收口本批领域文档、i18n 与验证：更新 GLOSSARY 与 ADR，确认全部 locale 完整，跑通本批相关测试且不新增历史失败。

**Blocked by:** 01（书架封面缓存写入后立即刷新）、02（缺失封面时从第一页生成封面）、03（重建下载索引预热第一页封面）、04（封面 URL 失败驱动自动续签）、05（继续阅读胶囊显示书名）、06（设置页合并备份索引并重排下载分组）

**Status:** resolved

- [x] GLOSSARY 修订「Continue reading pill」：现在包含书名第二行，宽度受主标签约束，完整书名在 tooltip。
- [x] GLOSSARY 增加/修订「Generated cover（生成封面）」：从本地 Chapter container 第一页生成、只存在于 Program state Cache、不是 Download library 内容。
- [x] ADR 0023 修订：第一页生成封面、封面优先级、失败驱动自动续签与节流；明确封面仍不属于 Download library。
- [x] ADR 0016 已由 ticket 05 修订；本 ticket 验证记录存在且与实现一致。
- [x] 全部 locale 的新增/修改文案完整，无英文回退或空缺；i18n completeness/sorted/mojibake guard 通过。
- [x] 本批相关测试全绿：书架封面解析/刷新、第一页生成、重建预热、自动续签、胶囊书名、设置分组。
- [x] 不新增历史全量测试失败；已知的 manga-only schema/旧测试失败不在本批范围内，继续如实记录。
- [x] 未新增数据库 schema、未改 Backup 格式、未写 Download library、未移动用户文件。
- [x] ticket 07 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、剩余遗留）。

## Answer

- Worktree 分支：`worktree-agent-acb400d8350c367c3`；基线 `8bb18562`（integration/manga-cover-and-shelf-polish tip，ticket 03 已合入）。
- Commits（本 ticket）：
  - `cb829526e42bdc57fccd947a052f8650e48a98ee` `docs(domain): document generated covers and continue reading pill title`
  - `3771f5d241fffb23c60cc8a17761118f99c93b83` `chore(i18n): remove unused backup section key and add cover report copy`
  - `f2b2514b10173727a6848e24a768eece153f9fdf` `feat(settings): show cover counts in rebuild download index report`
  - 本文件随后以 `docs(scratch): resolve ticket 07` 提交（其 SHA 见 `git log` / 最终报告）。
- `git merge --no-edit integration/manga-cover-and-shelf-polish`：`Already up to date.`（integration tip 仍为 `8bb18562`，无冲突）。

### 领域文档

- `GLOSSARY.md`「继续阅读胶囊（Continue reading pill）」：修订为显示书名第二行（显示标题、含改名覆盖；MD3 `onVariant` / Apple `secondaryLabel`，`labelSmall`；宽度受本地化「继续阅读」实际渲染宽度约束，单行省略；完整书名保留在 tooltip；整颗胶囊仍是单一点击目标；无候选时隐藏），删除旧的「不显示书名」描述。
- `GLOSSARY.md` 新增「Generated cover（生成封面）」：按 Chapter reading order 取第一个完整本地容器的第一页（CBZ 归档第一张图片、文件夹章节自然排序第一张图片、跳过 `ComicInfo.xml`），缩放编码为 JPEG；只存在于 Program state 的 `<programState>/cache/shelf_covers`（按 bookKey），不是 Download library 内容，不写 Content root / 不建下载目录 / 不改 `cover_path` / 不进 Backup；sidecar sentinel（规范路径 + 大小 + mtime）变化时重新生成；封面优先级为本地 `cover.*` → 可用 Source 当前封面（含持久字节缓存）→ 生成封面 → 占位；真实封面成功后替换生成封面；失败保留占位不崩溃。
- `GLOSSARY.md`「Cache（缓存）」补充生成封面语义：持久封面与生成封面都在 Program state 缓存目录，清除缓存一并删除并按需重建；离线/清缓存后使用本地或生成封面，都没有才占位。
- `docs/adr/0023-online-cover-cache-in-program-state.md`：新增 `## Amendment 2026-11-11（manga-cover-and-shelf-polish）`，明确原文解析顺序被新优先级取代（本地 `cover.*` → 来源当前封面含持久字节 → 生成封面 → 占位）、第一页生成封面与 sentinel 重生成、重建预热及计数、失败驱动自动续签与 24h/每启动节流，并明确生成封面与持久缓存仍不属于 Download library、不新增 schema、不改变 Backup 格式。
- `docs/adr/0016-manga-page-tag-tabs.md`：验证 ticket 05 的 `## Amendment 2026-11-11（manga-cover-and-shelf-polish）` 存在且与实现一致（`getDisplayTitleFromMediaItem`、`labelSmall`、`onVariant`/`secondaryLabel`、`TextPainter` 宽度约束、省略号、完整 tooltip、单一点击目标、MD3 56 不变、Apple 48、无候选隐藏）；无需再改。

### i18n

- 用 `dart tool/i18n_sync.dart --remove backup_import_mihon_section` 从全部 17 个 i18n json 删除未使用 key；确认代码 / 生成物无引用（仅历史 ticket 06 文本保留记录）。
- 新增 `rebuild_download_index_report_covers`（生成 / 更新 / 跳过 / 失败四个计数），并按 locale 提供真实翻译：base EN 之外的 16 份译文全部为本地语言，不是英文占位。`dart tool/i18n_sync.dart --sort` 与 `dart run slang` 重新生成；未手改 `strings.g.dart`。
- `test/i18n` 整套通过：59 tests（completeness、sorted、strings、mojibake 等）。

### 设置页重建报告

- `settings_schema_rebuild_index.dart` 的 `_showRebuildReport` 在原有重建摘要后追加封面行，接入 ticket 03 的 `coversGenerated` / `coversUpdated` / `coversSkipped` / `coversFailed`；取消时同样显示已完成部分的封面计数。
- `settings_rebuild_download_index_test.dart` 先写红（期望出现封面行、实际缺失），再实现转绿；结果框与取消摘要都断言封面计数。

### 测试结果

- 封面解析 / 刷新 / 第一页 / 作品页 / media cover write guard / 返回书架刷新：10 个文件 80 tests 通过。
- 重建服务 / 下载发现 / 24h 更新探针：3 个文件 54 tests 通过（含第一页预热、远程封面优先、坏页失败计数、幂等、容器变化更新）。
- 设置分组 / 重建 / 检索 / CBZ / 备份目录 / schema & CLI coverage + 继续阅读胶囊 / 改名 guard / 进度：10 个文件 48 tests 通过。
- 引擎第一页 bytes API 与回归：2 个文件 18 tests 通过。
- `dart analyze` 改动的 Dart 文件：No issues found。
- 已知既有失败（未新增）：`test/media/cover_write_sink_bug_2496_guard_test.dart` 3 个用例仍失败，与 ticket 02 记录的基线 `bba3599e` 失败一致，与本批改动无交集；按要求未跑全量历史套件，manga-only schema 等历史失败保持现状。

### 边界

- 未新增数据库 schema；未改 Backup 导出 / 导入格式；未写 Content root / Download library；未移动、复制或删除用户文件。
- 本 ticket 的 diff 仅涉及 `GLOSSARY.md`、ADR 0023、17 个 i18n json、设置页重建报告与对应测试，以及本 ticket 文件。
