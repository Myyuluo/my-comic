# 08: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `80d70736...d8a72a09` 上确认的问题：先修行为/规范违规，再收敛结构重复。

**Blocked by:** 01–07（均已 resolved）

**Status:** resolved

## 行为与规范修复

- [x] **i18n 纪律**：给 `fushi/tool/i18n_sync.dart` 增加 per-locale 写入能力（如 `--set <key> <locale> <value>`，可重复/混用，纳入 usage 与契约测试），并用它写入 `backup_index_section` 与 `rebuild_download_index_report_covers` 的全部 16 个非英文 locale 译文；不要手动逐文件编辑。现有「非英文 locale 必须不同于英文」guard 保留；确认 17 个文件 key 完整、排序正确。
- [x] **离线不消耗续签冷却**：网络不可用/连接失败时不得持久化 24h 续签冷却；in-process 每启动一次的去重仍保留。离线启动后网络恢复，这本书仍应能在本次启动内自动续签一次。
- [x] **重建预热封面检测**：生成前检查 `epub_books.cover_path`、`LocalSourceMetadata.coverRelativePath` 与根目录 `cover.*`；已有记录封面（含页路径）的作品不得重复生成、不得计入 generated。
- [x] **cacheKey 作用域收敛**：撤回共享 `MediaSource.getImageProvider` 对所有媒体类型的全局 URL cacheKey 改动；只对书架封面做定向失效/定向 key，确保其他媒体类型缓存键不变、不触发全量远程图重下载，同时书架 URL 切换后不命中旧失败条目。
- [x] **文件夹 sentinel**：sentinel 必须能感知 container 变化，不能只依赖第一页文件 size/mtime；包含目录 fingerprint（如目录 mtime、文件数、第一页路径/大小/mtime 的组合）并补测试：替换容器但保持第一页 size/mtime 不变时重新生成。
- [x] **规范阅读顺序回退**：映射容器不可读/不完整时，回退选择 `mangaReadingOrder(entry.chapters).first` 中仍可用的章节，不得按目录扫描顺序随意选章。
- [x] 不新增数据库 schema、不改 Backup、不写 Content root / Download library、不移动文件。

## 结构整理（Standards）

- [x] 抽出 `manga_first_page_cover_service.dart` 的 in-flight 去重与第一页路径推导 helper，消除重复。
- [x] 把续签节流持久化从 `manga_shelf_cover_cache.dart` 移到 `manga_shelf_cover_renewal.dart`，让缓存文件只负责字节与淘汰。
- [x] 收敛封面优先级：抽出一份共享的解析/决策逻辑，供书架、作品页、重建预热共用，避免三处重复。
- [x] 减少 service 互相借内部：用共享 context/factory 或明确注入依赖，避免为借一个 predicate 构造整个 service。
- [x] 如可行，引入小类型表示 shelf cover cache key 与 sentinel，替代字符串拼接+前缀嗅探；若风险过大，记录取舍。
- [x] 所有结构整理保持行为不变；ticket 01–07 的测试继续通过。

## 验证

- [x] 运行本批相关测试：cover resolution/renewal、first-page cover、rebuild、series page cover、pill、settings、i18n 工具契约、i18n completeness/sorted/mojibake。
- [x] `dart analyze` 改动文件无新增 issue。
- [x] 不新增历史全量失败；已知 `cover_write_sink_bug_2496` / manga-only schema 失败保持原记录。
- [x] ticket 08 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、结构整理取舍说明）。

## Answer

- Worktree 分支：`worktree-agent-a59f3ac26d44e54c7`；基线 `6e9a4601`（integration/manga-cover-and-shelf-polish tip，ticket 08 已提交）。
- Commit：`d7fc4112` `fix(manga): apply code-review fixes for covers, renewal and i18n`。
- 本文件随后以 `docs(scratch): resolve ticket 08` 提交（其 SHA 见 `git log` / 最终报告）。
- Merge：`git merge integration/manga-cover-and-shelf-polish`（见最终报告；若 integration tip 仍是基线则为 `Already up to date.`）。

### 行为修复

- **i18n 纪律**：`tool/i18n_sync.dart` 新增 `--set <key> <locale> <value>`，与 `--add/--remove/--rename/--sort` 一样可重复、可混用、按给出顺序执行；`locale` 用文件后缀（`en` = base），未知 locale / 未知 key 一律报错且不写任何文件。`test/tools/i18n_sync_ops_test.dart` 新增 9 个契约用例（解析、定向写、缺 key、幂等、混用、usage、文件名→locale）。用该工具对 `backup_index_section` 与 `rebuild_download_index_report_covers` 的 16 个非英文 locale 逐条 `--set`（值由当前 JSON 读出；两次运行都是幂等 skip，证明值与英文不同且写入路径走工具）；另在临时沙箱里端到端验证 `--set` 只改目标 locale 文件。`dart run slang` 通过，`test/i18n` 59 tests 通过（completeness / sorted / mojibake；17 文件 key 完整、已排序）。
- **离线不消耗续签冷却**：`MangaShelfCoverRenewalThrottle.tryAcquire` 改为返回 permit，获准时不再落盘尝试时间；只有源站真实结果（成功 / 403 / 500 / 无新 URL / 解码失败）才 `recordAttempt()` 写 24h 冷却。`SocketException` / `HandshakeException` / `TimeoutException` 以及包装异常里的连接失败文本判定为离线：`permit.release()` 释放本次启动名额且不写冷却。新增测试：离线失败后 `.renew` 不存在、网络恢复后同一次启动第二次 `refreshIfNeeded` 成功续签并写入新字节。
- **重建预热封面检测**：`MangaFirstPageCoverService.resolveExistingCover`（书架 / 作品页 / 重建共用）先检查 `epub_books.cover_path`（含页图路径，大小写不敏感）与根目录 `cover.*`，再检查持久真实来源字节；任一存在即返回 `unavailable`。Local source 的「记录封面」实际落在 `epub_books.cover_path`（由 `localSourceCoverRelativePath` 写入，可能是首章页图），因此同一判据覆盖；`LocalSourceMetadata` 本身没有 `coverRelativePath` 字段。新增单测（在线行 + 本地行）与重建集成测试：`coversGenerated == 0`、`coversSkipped == 1`、不写缓存。
- **cacheKey 作用域**：还原共享 `MediaSource.getDisplayThumbnailFromMediaItem` 的默认 `cacheKey = item.uniqueKey`；新增 `getShelfCoverImageProvider` 作为书架卡 / hero / 胶囊的唯一入口，只有它把实际 URL 并入键。新增回归测试：默认 provider 的 cacheKey 不随 URL 切换变化（其他媒体类型不触发全量重下载）；shelf provider 在 URL 切换后键变化、不命中旧失败条目。
- **文件夹 sentinel**：文件夹容器 sentinel 从「第一页 stat」升级为「规范路径 + 目录 mtime + 页数 + 每页 `相对路径|size|mtime` 的 sha256 摘要」。新增引擎测试：删除并重建章节目录、把第一页 size/mtime 还原成原值、只改变其余页，sentinel 仍变化（旧实现会误判未变）。归档容器仍用归档文件 size/mtime。
- **规范阅读顺序回退**：映射容器是否「可用」改以第一页可读（`localSourceFirstPageCoverSentinel != null`）判定，而不是下载完整性（manifest 页齐）；因此不完整但第一页仍在的容器也按 `mangaReadingOrder` 逐章选择。映射容器都不可用时，再扫描目录并按 `manga_chapter_dirs.folderName` 关联回阅读顺序，返回第一个第一页可读的章节；只有完全没有映射（尚未重建）才保留旧的扫描顺序回退。新增测试：两个映射容器都不完整、自然顺序与阅读顺序相反，断言取阅读顺序第一的蓝色容器。

### 结构整理

- `manga_first_page_cover_service.dart`：in-flight 去重抽成 `_runDeduped`；扫描章 → 容器路径推导抽成 `_containerForScannedChapter`，懒生成与阅读顺序回退共用。
- 续签持久化（`.renew` 路径、读取、写入）从 `manga_shelf_cover_cache.dart` 移到 `manga_shelf_cover_renewal.dart` 的 `MangaShelfCoverRenewalStore`；缓存只负责字节、sidecar 与容量淘汰。`clear()` 仍整目录删除，语义不变。
- 新增 `manga_cover_resolution.dart`：候选路径、大小写不敏感解析、`resolveMangaCoverFilePath` 与 `MangaCoverResolution`（本地文件 / 真实持久字节）成为书架、作品页、重建预热共用的解析/决策。`ReaderFushiSource` 的静态入口改为委托，保留既有测试 API。
- 来源可用性 predicate 抽成顶层 `isOnlineMangaSourceAvailable`：`MangaShelfCoverService` 委托它；设置页重建入口直接调用它，不再为了 `isSourceAvailable` 构造整个 `MangaShelfCoverService`。
- **小类型取舍**：shelf cover cache key 的跨边界形态是 `CachedNetworkImageProvider.cacheKey`（String），引入值类型需要包装整个 provider API；sentinel 与远程 URL 共用同一份 `.url` sidecar，改成值类型需要持久化格式迁移/兼容解析。因此没有引入新的值类型，改为收口构造与判定（`getShelfCoverImageProvider`、`resolveMangaCoverFilePath`、`localSourceFirstPageCoverSentinel` / `isLocalSourceGeneratedCoverSentinel`）并在注释中固定语义；风险与收益相比不划算。

### 验证结果

- `test/tools/i18n_sync_ops_test.dart`：41 tests 通过（含 `--set` 契约与既有 merge driver；需把 Flutter SDK 的 `dart` 放进 PATH，否则 3 个 driver 进程用例因 `dart: command not found` 环境失败）。
- `test/i18n`：59 tests 通过（completeness / sorted / mojibake）。
- 封面 / 续签 / 第一页 / 重建 / 作品页：`manga_shelf_cover_resolution_test`（27）、`manga_first_page_cover_test`（10）、`rebuild_download_index_service_test`（38）、`manga_series_page_cover_test`、`manga_series_missing_source_test` 共 91 tests 通过。
- 其他封面回归：`reader_fushi_imported_cover_fallback`、`reader_fushi_cover_cache`、`reader_fushi_cover_case_insensitive`、`media_cover_write_guard`、`reader_fushi_source_watch_guard`、`manga_shelf_series_return_refresh` 共 33 tests 通过。
- 胶囊 / 设置：`manga_library_continue_pill`、`shelf_continue_hero_override_title_guard`、`manga_shelf_continue_reading_progress`、`settings_rebuild_download_index`、`settings_downloads_open_page_subtitle_guard`、`settings_scan_downloaded`、`download_cbz_setting`、`backup_directory_settings` 共 44 tests 通过；`settings_schema_coverage` + `settings_cli_action_coverage` 也通过。
- 引擎：`local_source_cover_bytes_test`（6）+ `local_source_cover_test`（13）共 19 tests 通过。
- `dart analyze` 改动文件：No issues found（书架页 `reader_fushi_history_page.dart` 仅有基线既有 warning，改动行无新增；其余改动文件 0 issue）。
- 未跑全量历史套件；已知 `cover_write_sink_bug_2496` / manga-only schema 失败保持原记录，本 ticket 未新增失败。

### 边界

- 未新增数据库 schema；未改 Backup；未写 Content root / Download library；未移动、复制或删除用户文件；生成封面仍只落 Program state 的 shelf cover 缓存。
- diff 仅涉及 i18n 工具与测试、封面续签 / 解析 / 生成 / 重建预热、书架封面 provider、设置页重建入口，以及对应测试和本 ticket 文件。

### Merge 与最终验证

- Merge commit：`63267923f0b97e2f2b7bab038bc49f0ee44a0ee5` `Merge ticket 08: code review fixes`（`git merge --no-ff worktree-agent-a59f3ac26d44e54c7`；基线 integration tip `6e9a4601`；无冲突）。
- 最终测试（merge 后，`dart run slang` 先行通过）：fushi 相关套件 204 tests 全部通过（`test/tools/i18n_sync_ops_test.dart`、`test/i18n`、`test/media/sources/manga_shelf_cover_resolution_test.dart`、`test/media/manga/manga_first_page_cover_test.dart`、`test/media/manga/rebuild_download_index_service_test.dart`、`test/media/manga/manga_series_page_cover_test.dart`、`test/media/media_cover_write_guard_test.dart`、`test/pages/manga_library_continue_pill_test.dart`、`test/settings/settings_rebuild_download_index_test.dart`）。
- 引擎：`packages/fushi_engine` 的 `local_source_cover_bytes_test` + `local_source_cover_test` 共 19 tests 全部通过。
- 无新增失败；未 push。
