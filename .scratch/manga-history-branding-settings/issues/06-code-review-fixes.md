# 06: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `ad4fd020...ea8dbf88` 上确认的问题：异常吞噬、WebView 可清理范围、更新检查缓存隔离、History 文档顺序，以及结构重复。

**Blocked by:** 01–05（均已 resolved）

**Status:** resolved

## 行为与规范修复

- [x] **不再吞异常**：`_measureClearableBytes()` 改为 typed catch（如 `FileSystemException`），用 `ErrorLogService` 记录；测量失败仍按 0 计，但不掩盖意外错误。补测试。
- [x] **WebView 可清理范围与测量一致**：测量的 profile/cache 必须与 `clear()` 实际清理的集合一致；不要把不会被清理的旧 `webview2-manga*` 兄弟 profile 计入占用。补测试，移除对 stale sibling 300B 的期望。
- [x] **更新检查缓存按 fork 隔离**：缓存 key 或失效逻辑包含 repo/版本/更新源；旧上游 3.x 缓存不得在 fork 检查前显示「Update 3.x available」；无 release 仍走「已是最新」。补测试。
- [x] **History 文档顺序修正**：把 spec/GLOSSARY 中 History 的封面顺序改为与书架/ADR 0023 一致（本地 → 真实持久 → 可用远程 → 生成 → 占位）；代码保持现状，补测试/文档说明。
- [x] **恢复被弱化的测试 guard**：`official_website_entry_test` 恢复「下载页 URL 属于官网」断言，或给出明确理由。

## 结构整理（Standards）

- [x] 合并 `manga_history.dart` 的 `_cachedRealShelfCoverPath` / `_cachedGeneratedShelfCoverPath` 为参数化 helper。
- [x] 抽出共享 `MangaShelfCoverService` 组装 factory，供 `reader_fushi_source` 与 `manga_history_page` 共用。
- [x] 把 `kMangaWebViewSafeCacheSubdirectories` / `mangaWebViewSafeCacheDirectories` 重命名为 Clearable 语义。
- [x] 去重 WebView cache 测试里的 `write` helper。
- [x] 修正 `update_checker_net.dart:533` 的旧库回退注释。
- [x] 收敛只剩单 repo 的 `kGitHubRepoFallbacks` / 单 key map 机制；若保留，记录取舍。
- [x] `_canUseHistoryRemoteCover` 的 bool 三态改为明确的小类型或命名，避免 unknown 隐式映射为 true。
- [x] 所有结构整理保持行为不变，ticket 01–05 测试继续通过。

## 验证

- [x] 运行相关测试：History cover、WebView cache clear、update checker（含缓存/404/空 release）、settings、i18n。
- [x] `dart analyze` 改动文件无新增 issue。
- [x] 不新增历史全量失败；已知 manga-only schema / m3e static / lookup 渲染失败保持原记录。
- [x] 不新增 schema、不改 Backup、不移动文件。
- [x] ticket 06 更新为 `Status: resolved`，追加 `## Answer`。

## Answer

Resolved on `worktree-agent-ticket06`（基线 `d20e1226`，实现 commit `868b8f35a2331ea72d2f5a66d74dd8997525afaa`）。

### 行为修复

- **不再吞异常**：`MangaWebViewCacheClearStep._measureClearableBytes()` 只捕获 `FileSystemException`，用 `ErrorLogService` 记录后按 0 计；其它异常继续抛出。新增 `measureDirectories` 测试缝，覆盖「文件系统失败仍继续清理」与「意外异常不被掩盖」两条路径。
- **WebView 测量 = 清理集合**：`buildMangaWebViewCacheProfiles` 不再扫描、汇总所有 `webview2-manga*` 兄弟目录，只统计 `MangaWebViewEnvironment.currentUserDataFolder`（环境尚未创建时用首次创建会用的基础 `webview2-manga`）。`MangaWebViewEnvironment` 记录实际 user data folder；测试从 650 改为 350，并新增「当前环境落到派生兄弟目录时只统计该目录」。
- **更新缓存按 fork 隔离**：`UpdateCheckCacheEntry` 持久化 `repository`（`kUpdateCheckSourceRepository = Myyuluo/my-comic`）；`decode` 对缺失 / 空 repository 的旧上游缓存返回 null；`cachedEntryForChannel` 同时校验通道与更新源。`kGitHubRepo` 复用同一常量。旧上游 3.x 缓存不会在联网前显示「Update 3.x available」；404 / 空 release 仍走 `onUpToDate`（`update_checker_404_reresolve_test`、`update_checker_manual_callbacks_test` 通过）。新增 3 条隔离测试。
- **History 文档顺序**：`loadMangaHistory` 注释与 GLOSSARY 统一为 本地 `cover.*` → 真实来源持久封面 → 可用远程 URL → 生成封面 → 占位；新增「未注入 shelf cover service 时 unknown 显式保留远程回退」测试。代码行为不变。`spec.md` 是 gitignore 的本地文档；按 worktree 边界未改主 checkout，修正版放在 worktree 的 `.scratch/manga-history-branding-settings/spec.md`。
- **恢复 guard**：`official_website_entry_test` 重新断言下载页 URL 的 host 属于官网并以官网 URL 为前缀。

### 结构整理

- `_cachedRealShelfCoverPath` / `_cachedGeneratedShelfCoverPath` 合并为参数化 `_cachedShelfCoverPath`。
- 新增 `MangaShelfCoverService.forAppCache(...)` 与 `appOnlineMangaServiceResolver(...)`，`reader_fushi_source` 与 `manga_history_page` 共用同一组装入口。
- `kMangaWebViewSafeCacheSubdirectories` / `mangaWebViewSafeCacheDirectories` 重命名为 `kMangaWebViewClearableCacheSubdirectories` / `mangaWebViewClearableCacheDirectories`。
- WebView cache 测试的 `write` helper 去重为顶层 `_write`。
- 修正 `update_checker_net.dart` 的旧库回退注释。
- 删除单元素 `kGitHubRepoFallbacks` 与单 key `manifestUrlsForChannel`；`manifestUrlForChannel` 直接返回通道 URL，guard / product-split 测试同步收敛。
- `_canUseHistoryRemoteCover` 改为显式三态 `_HistoryRemoteCoverAvailability { available, unavailable, unknown }`，unknown 在 switch 中显式保留旧远程回退。

### 验证

- `flutter test`（Flutter 3.47.6，先 `dart run slang`）：
  - WebView cache clear、cache clear service、update cache、update checker structure/manifest/redirect/manual/404、product split、History cover、official website 合计 119 passed。
  - 其余 History page / shelf cover / first-page cover / history write 合计 62 passed。
  - 更早一轮 settings + update checker 组合 188 passed、1 failed；唯一失败为既有 `update_check_cache_wiring_guard_test` 的 `home_page auto-check passes a cacheWriter`（ticket 05 已记录：manga-only 裁剪后 home_page 不再有该接线，本次未改 home_page）。
  - `test/i18n` 59 passed。
- `dart analyze` 全部 18 个改动文件：No issues found。
- 未新增 schema、未改 Backup、未移动文件；未 push。

### 剩余取舍

- 漫画 WebView 环境若在清缓存过程中才首次创建、且基础目录被锁而退到哈希兄弟目录，清理前后测量仍按基础目录，`freedBytes` 会少报（不会多报）；已创建环境与正常路径准确。
- `update_checker_release.dart` 行数天花板 2150 继续满足（2061 行），未上调。
- `officialR2UrlForUpdateAsset` 仍只识别上游 `hajisensai/fushi` 的 Release 资产并映射到官网 R2；本 ticket 未改（不在 findings 列表），下载回退仍走 GitHub 直连 / 镜像。

### Merge 收口（2026-11-11）

- `git merge integration/manga-history-branding-settings` → `Already up to date.`（integration 尖端仍为基线 `d20e1226`，本分支已领先两个提交），无冲突、无 merge commit。
- merge 后 HEAD：`64bac02cc31f37b8247e69a83d0054a0ceb66f49`（实现 `868b8f35a2331ea72d2f5a66d74dd8997525afaa` + ticket 更新；本条 merge 记录提交后 HEAD 再前进一个 docs commit）。未 push。

### Integration 收口（2026-11-11）

- `worktree-agent-ticket06` 以 `--no-ff` 合入 `integration/manga-history-branding-settings`，无冲突；merge commit `4cdb916cfa8ca31cf785d78107a3ec1e9e97add8` 即 integration 新 HEAD。
- 最终验证（`fushi/`，Flutter 3.47.6，先 `dart run slang`）：
  - WebView cache clear、cache clear service、cache clear settings、update check cache、History cover、official website 合计 **53 passed**。
  - update checker 全套（404 / all releases / manifest / redirect / structure / release selection / product split / publish race 等）**328 passed, 1 failed**。首轮 10 failed 均为本机 PATH 上 Windows Store `python3.exe` 占位符（exit 49、无输出）导致；换真实 Python 3.12 shim 后全部通过，与代码无关。
  - 唯一失败仍是既有 `update_check_cache_wiring_guard_test.dart: home_page auto-check passes a cacheWriter`：合并前 `d20e1226` 的 `home_page.dart` 即不含该接线（manga-only 裁剪遗留），merge 未改 `home_page.dart` 或该 guard 测试，非本次合并引入。
  - `test/i18n` **59 passed**。
- 未 push；仅合并与验证，无功能改动。
