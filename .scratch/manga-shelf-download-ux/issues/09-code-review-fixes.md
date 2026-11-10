# 09: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `eb6e2f42...263a5695` 上确认的问题：先修真实行为 bug，再做命名/去重/三态/参数团等结构整理，并补齐 locale 文案。

**Blocked by:** None（can start immediately；依赖 01–08 已合入 integration）

**Status:** ready-for-agent

## 真实行为修复

- [ ] **Disabled 源不得当成已安装**：`DownloadMangaInstalledSources.load` 只收集 enabled 的 Extension 与 Source（同时检查扩展与源两侧）；停用源必须走「源未安装」降级本地条目，并计入 `addedLocalSourceMissing`。补服务测试。
- [ ] **来源缺失时书架封面不得回退远程 URL**：来源未安装/停用时，书架封面解析顺序只允许「持久缓存 → 本地封面文件 → 占位」，不得使用 `series.coverUrl`。补书架封面解析测试，并调整现有断言远程回退的测试。
- [ ] **新封面 URL 持久化后必须后台刷新字节**：即使当前显示的是本地封面、只要没有持久字节缓存或 URL 已变化，也要调度 `refreshIfNeeded`。补测试覆盖「本地封面存在 + 无持久缓存 + 新 URL」。
- [ ] **scan report 的 `\\n` 字面量**：`scan_downloaded_report_body` 在全部 locale 中改为真正的换行 `\n`，不得显示字面量反斜杠 n。
- [ ] **新/改文案覆盖全部 locale**：`scan_downloaded_*`、`cache_clear_step_shelf_covers`、`rebuild_download_index_*` 在全部 16 个 locale 中提供对应翻译，不再用英文占位/回退；zh-HK 不得混用英文 scan 文案。用 `dart tool/i18n_sync.dart` 与 `dart run slang`，不要手改生成物。
- [ ] **`update_probes` scope creep 评估**：保留「空章节仍持久化封面/元数据」所需的最小改动；不得无意改变自动追更或刷新计数语义。若某项改动是新的 `OnlineMangaRefreshOutcome` 必需，写下理由；否则回退。
- [ ] 不改变 Backup 格式、不写 Download library、不移动文件、不新增数据库 schema。

## 结构整理（Standards）

- [ ] **术语命名**：把 `download_manga_recovery.dart` 及 `DownloadMangaRecovery` / `DownloadMangaRecoveryOutcome` 等重命名为 Scan downloaded 语义（如 `download_manga_discovery.dart` / `DownloadMangaDiscovery` / `DownloadMangaDiscoveryOutcome`），更新所有 import、调用点与测试；不得保留“Rebuild recovery”措辞。
- [ ] **设置动作去重**：抽出 rebuild / scan 共用的「run scan → progress dialog → report」helper，消除 `_scanDownloaded` / `_showScanReport` / 进度框 / cancel token 的逐行重复；两侧报告字段仍按各自语义展示。
- [ ] **封面缓存淘汰去重**：让 `MangaShelfCoverCache` 与 `MihonCoverCache` 共用同一份 512 条 / 64 MiB mtime 淘汰策略（抽出 policy/helper），不要复制 `trim()` / `measureBytes()` 形状。
- [ ] **Outcome 汇总**：使用 `DownloadMangaDiscoveryOutcome.merge()` 或删除未被生产代码使用的 `merge()`；不要手工重复累加十个字段。
- [ ] **三态完成状态**：用一个小三态类型替代 `classifyShelfReadStatus(completed:, completedKnown:)` 的 bool 组合，表达 unknown / known-incomplete / complete；同步 `tallyShelfProgress` 与所有调用点。`isLastMangaChapterInReadingOrder` 的 `naturalOrder` bool 同形处理。
- [ ] **Key sets 参数团**：把 `tombstonedBookKeys` / `existingBookKeys` / `existingNonLibraryBookKeys` / `skippedOnlineBookKeys` 包成一个 `DownloadMangaBookKeys`（或等价类型）传递。
- [ ] **字段语义**：修正 `DownloadMangaDiscoveryOutcome.skipped` 与 `.skippedTombstoned` 的重复注释，明确各自含义。
- [ ] 所有结构整理保持行为不变；ticket 01–08 的测试必须继续通过。

## 验证

- [ ] 相关测试：continue-reading、rebuild、scan downloaded、cover resolution、settings scan/rebuild、i18n completeness/sorted、update probes。
- [ ] `dart analyze` 对改动文件无 issue。
- [ ] 全量测试的既有历史失败不得因本 ticket 增加；本 ticket 相关测试全绿。
- [ ] ticket 09 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、对 `update_probes` 与 locale 回填的处理说明）。
