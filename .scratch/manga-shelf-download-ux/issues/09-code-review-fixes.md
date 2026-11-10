# 09: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `eb6e2f42...263a5695` 上确认的问题：先修真实行为 bug，再做命名/去重/三态/参数团等结构整理，并补齐 locale 文案。

**Blocked by:** None（can start immediately；依赖 01–08 已合入 integration）

**Status:** resolved

## 真实行为修复

- [x] **Disabled 源不得当成已安装**：`DownloadMangaInstalledSources.load` 只收集 enabled 的 Extension 与 Source（同时检查扩展与源两侧）；停用源必须走「源未安装」降级本地条目，并计入 `addedLocalSourceMissing`。补服务测试。
- [x] **来源缺失时书架封面不得回退远程 URL**：来源未安装/停用时，书架封面解析顺序只允许「持久缓存 → 本地封面文件 → 占位」，不得使用 `series.coverUrl`。补书架封面解析测试，并调整现有断言远程回退的测试。
- [x] **新封面 URL 持久化后必须后台刷新字节**：即使当前显示的是本地封面、只要没有持久字节缓存或 URL 已变化，也要调度 `refreshIfNeeded`。补测试覆盖「本地封面存在 + 无持久缓存 + 新 URL」。
- [x] **scan report 的 `\\n` 字面量**：`scan_downloaded_report_body` 在全部 locale 中改为真正的换行 `\n`，不得显示字面量反斜杠 n。
- [x] **新/改文案覆盖全部 locale**：`scan_downloaded_*`、`cache_clear_step_shelf_covers`、`rebuild_download_index_*` 在全部 16 个 locale 中提供对应翻译，不再用英文占位/回退；zh-HK 不得混用英文 scan 文案。用 `dart tool/i18n_sync.dart` 与 `dart run slang`，不要手改生成物。
- [x] **`update_probes` scope creep 评估**：保留「空章节仍持久化封面/元数据」所需的最小改动；不得无意改变自动追更或刷新计数语义。若某项改动是新的 `OnlineMangaRefreshOutcome` 必需，写下理由；否则回退。
- [x] 不改变 Backup 格式、不写 Download library、不移动文件、不新增数据库 schema。

## 结构整理（Standards）

- [x] **术语命名**：把 `download_manga_recovery.dart` 及 `DownloadMangaRecovery` / `DownloadMangaRecoveryOutcome` 等重命名为 Scan downloaded 语义（如 `download_manga_discovery.dart` / `DownloadMangaDiscovery` / `DownloadMangaDiscoveryOutcome`），更新所有 import、调用点与测试；不得保留“Rebuild recovery”措辞。
- [x] **设置动作去重**：抽出 rebuild / scan 共用的「run scan → progress dialog → report」helper，消除 `_scanDownloaded` / `_showScanReport` / 进度框 / cancel token 的逐行重复；两侧报告字段仍按各自语义展示。
- [x] **封面缓存淘汰去重**：让 `MangaShelfCoverCache` 与 `MihonCoverCache` 共用同一份 512 条 / 64 MiB mtime 淘汰策略（抽出 policy/helper），不要复制 `trim()` / `measureBytes()` 形状。
- [x] **Outcome 汇总**：使用 `DownloadMangaDiscoveryOutcome.merge()` 或删除未被生产代码使用的 `merge()`；不要手工重复累加十个字段。
- [x] **三态完成状态**：用一个小三态类型替代 `classifyShelfReadStatus(completed:, completedKnown:)` 的 bool 组合，表达 unknown / known-incomplete / complete；同步 `tallyShelfProgress` 与所有调用点。`isLastMangaChapterInReadingOrder` 的 `naturalOrder` bool 同形处理。
- [x] **Key sets 参数团**：把 `tombstonedBookKeys` / `existingBookKeys` / `existingNonLibraryBookKeys` / `skippedOnlineBookKeys` 包成一个 `DownloadMangaBookKeys`（或等价类型）传递。
- [x] **字段语义**：修正 `DownloadMangaDiscoveryOutcome.skipped` 与 `.skippedTombstoned` 的重复注释，明确各自含义。
- [x] 所有结构整理保持行为不变；ticket 01–08 的测试必须继续通过。

## 验证

- [x] 相关测试：continue-reading、rebuild、scan downloaded、cover resolution、settings scan/rebuild、i18n completeness/sorted、update probes。
- [x] `dart analyze` 对改动文件无 issue。
- [x] 全量测试的既有历史失败不得因本 ticket 增加；本 ticket 相关测试全绿。
- [x] ticket 09 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、对 `update_probes` 与 locale 回填的处理说明）。

## Answer

- Worktree 分支：`worktree-agent-ad05a41d77dbb55e9`；基线 `5e7c67e1`（ticket 09 已提交）。
- Commit：`15a65aca` `fix(manga): address ticket 09 code review findings`（本文件随后的 ticket 更新单独提交）。
- 合并：`git merge integration/manga-shelf-download-ux` → `Already up to date`（integration HEAD `5e7c67e1`）。

### 真实行为修复

- **Disabled 源**：`DownloadMangaInstalledSources.load` 只收集 `enabled` 的扩展与在线源（两侧都要启用）；`MihonLibraryAdapter.isSourceAvailable` 同样要求扩展与源都启用。停用源按「源未安装」处理，Scan downloaded 降级为本地条目并计入 `addedLocalSourceMissing`。新增 discovery 模块与 scan service 两层测试。
- **来源缺失书架封面**：`ReaderFushiSource` 在无持久缓存、无本地封面时，先经 `MangaShelfCoverService.isSourceAvailable`（只读数据库、按来源缓存结果、不联网）判定；来源未安装 / 停用直接占位，不再回退 `series.coverUrl`。有持久缓存或本地封面时照常显示。调整了原有「来源缺失回退远程」断言并新增本地封面场景测试。
- **字节刷新调度**：书架解析对在线条目始终调度 `refreshIfNeeded`；服务内部用 `needsRefresh` 决定是否真正取字节。因此「本地封面存在 + 无持久缓存 + 新 URL」也会后台刷新，显示仍优先本地封面。
- **scan report 换行**：`scan_downloaded_report_body` 在 base、zh-CN 与 14 个英文占位 locale 中全部改为真正的 `\n`；新增 i18n guard 禁止字面量反斜杠 n。
- **locale 回填**：22 个下载索引 / 检索已下载 key 在 16 个 locale 全部提供真实翻译（14 个原先英文占位、zh-HK 的 scan / cache 文案；zh-HK rebuild 文案原本已是繁体中文）；zh-CN 保留既有中文并只修换行。流程使用 `dart tool/i18n_sync.dart --sort`（无缺 key，校验收口格式）与 `dart run slang` 重新生成访问器，未手改生成物。另加 guard：这些 key 不得与英文基线逐字相同。
- **`update_probes` scope creep**：保留的唯一新代码是适配 `OnlineMangaRefreshOutcome`，并新增 `chaptersRefreshed` 标志。原因：票 06 让 `refresh()` 在源返回空章节时不再抛错（以便持久化详情 / 封面），若 probe 只看 `chaptersError` 会把空章节列表误计为一次成功刷新。`chaptersRefreshed=false` 时 probe 沿用旧语义：上报 `emptyChaptersError`、不计入 `refreshed`、跳过自动追更，但票 06 的详情 / 封面落库与旧章节保留仍然生效。没有回退这部分，因为它不是额外功能，而是保持原有刷新计数 / 自动追更语义的最小手段。
- 未新增数据库 schema、未改 Backup 格式、未写 Download library、未移动用户文件；UI 未改版（ADR 0008）。

### 结构整理

- `download_manga_recovery.dart` → `download_manga_discovery.dart`；`DownloadMangaRecovery` / `DownloadMangaRecoveryOutcome` / `recover` / `_recoverAsLocal` 分别改为 Discovery / DiscoveryOutcome / `discover` / `_discoverAsLocal`，同步 import、注释、测试文件与测试辅助函数，移除 “Rebuild recovery / orphan recovery” 措辞。
- 四组 bookKey 收进 `DownloadMangaBookKeys`；Scan downloaded 用 `DownloadMangaDiscoveryOutcome.merge()` 统一累加，不再手工逐字段相加。
- `DownloadMangaDiscoveryOutcome.skipped` 与 `.skippedTombstoned` 注释拆分：前者是安全跳过总数，后者只表示墓碑原因。
- `classifyShelfReadStatus` / `tallyShelfProgress` 改用三态 `ShelfCompletion { unknown, incomplete, complete }`；`isLastMangaChapterInReadingOrder` 的 bool 改为 `MangaChapterOrdering { canonical, natural }`，全部调用点与测试同步。
- `MangaShelfCoverCache` 与 `MihonCoverCache` 共用 `CoverCacheEvictionPolicy`（512 条 / 64 MiB、mtime 升序、书架 `.url` 侧车一起清理），删除两份 `trim()` / `measureBytes()` 形状。
- 设置页抽出 `_runDownloadIndexAction` + `_DownloadIndexProgressDialog` + `_showDownloadIndexReport`，rebuild / scan 只保留各自的文案、执行体和报告字段；进度框与取消流程不再逐行重复。

### 验证

- 受影响套件（`fushi/`，`--no-pub`，Flutter `D:/ProgramData/flutter_3.47.6/bin/flutter.bat`，先 `dart run slang`）：

  ```
  flutter test --concurrency=6 \
    test/pages/manga_shelf_continue_reading_progress_test.dart \
    test/pages/manga_library_continue_pill_test.dart \
    test/pages/manga_library_membership_test.dart \
    test/pages/shelf_recent_read_order_test.dart \
    test/media/shelf_sort_test.dart \
    test/media/manga/manga_completion_semantics_test.dart \
    test/media/manga/rebuild_download_index_service_test.dart \
    test/media/manga/download_manga_discovery_test.dart \
    test/media/manga/scan_downloaded_manga_service_test.dart \
    test/settings/settings_rebuild_download_index_test.dart \
    test/settings/settings_scan_downloaded_test.dart \
    test/media/sources/manga_shelf_cover_resolution_test.dart \
    test/media/sources/reader_fushi_imported_cover_fallback_test.dart \
    test/media/sources/reader_fushi_cover_cache_test.dart \
    test/media/manga/manga_series_page_cover_test.dart \
    test/media/manga/manga_series_missing_source_test.dart \
    test/media/manga/mihon_cover_cache_test.dart \
    test/media/manga/library/mihon_installed_source_fallback_test.dart \
    test/media/manga/online_manga_library_test.dart \
    test/storage/manga_cache_clear_service_test.dart \
    test/settings/manga_cache_clear_settings_test.dart \
    test/media/media_cover_write_guard_test.dart \
    test/updates/online_manga_update_probe_test.dart \
    test/i18n
  ```

  结果：`All tests passed!`（289 tests）。
- `dart analyze` 对全部改动文件：无新增 issue。大型遗留文件（`manga_fushi_page.dart`、`home_dashboard_page.dart`、`reader_fushi_history_page.dart`）仍有本 ticket 前既存的 unused / 旧 API warning，未在本 ticket 扩大范围处理。
- 未跑全量历史套件（ticket 08 已记录大量与本批无关的 manga-only 历史失败）；本 ticket 相关测试全绿，未新增全量失败。

### Merge 记录

- Merge commit：`9101638f9f2ab5965c6288cc295cf790bc21077f`（`Merge ticket 09: code review fixes`），无冲突。
- 合并后复验（Flutter 3.47.6，先 `dart run slang`）：ticket 09 验证套件（含 `test/i18n` 整目录）`All tests passed!`（289 tests）。
- `dart analyze` 17 个改动 Dart lib 文件：22 个 warning / info 均为 `manga_fushi_page.dart`、`home_dashboard_page.dart`、`reader_fushi_history_page.dart` 的既存问题，无新增。
