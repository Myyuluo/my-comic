# 06: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `ad4fd020...ea8dbf88` 上确认的问题：异常吞噬、WebView 可清理范围、更新检查缓存隔离、History 文档顺序，以及结构重复。

**Blocked by:** 01–05（均已 resolved）

**Status:** ready-for-agent

## 行为与规范修复

- [ ] **不再吞异常**：`_measureClearableBytes()` 改为 typed catch（如 `FileSystemException`），用 `ErrorLogService` 记录；测量失败仍按 0 计，但不掩盖意外错误。补测试。
- [ ] **WebView 可清理范围与测量一致**：测量的 profile/cache 必须与 `clear()` 实际清理的集合一致；不要把不会被清理的旧 `webview2-manga*` 兄弟 profile 计入占用。补测试，移除对 stale sibling 300B 的期望。
- [ ] **更新检查缓存按 fork 隔离**：缓存 key 或失效逻辑包含 repo/版本/更新源；旧上游 3.x 缓存不得在 fork 检查前显示「Update 3.x available」；无 release 仍走「已是最新」。补测试。
- [ ] **History 文档顺序修正**：把 spec/GLOSSARY 中 History 的封面顺序改为与书架/ADR 0023 一致（本地 → 真实持久 → 可用远程 → 生成 → 占位）；代码保持现状，补测试/文档说明。
- [ ] **恢复被弱化的测试 guard**：`official_website_entry_test` 恢复「下载页 URL 属于官网」断言，或给出明确理由。

## 结构整理（Standards）

- [ ] 合并 `manga_history.dart` 的 `_cachedRealShelfCoverPath` / `_cachedGeneratedShelfCoverPath` 为参数化 helper。
- [ ] 抽出共享 `MangaShelfCoverService` 组装 factory，供 `reader_fushi_source` 与 `manga_history_page` 共用。
- [ ] 把 `kMangaWebViewSafeCacheSubdirectories` / `mangaWebViewSafeCacheDirectories` 重命名为 Clearable 语义。
- [ ] 去重 WebView cache 测试里的 `write` helper。
- [ ] 修正 `update_checker_net.dart:533` 的旧库回退注释。
- [ ] 收敛只剩单 repo 的 `kGitHubRepoFallbacks` / 单 key map 机制；若保留，记录取舍。
- [ ] `_canUseHistoryRemoteCover` 的 bool 三态改为明确的小类型或命名，避免 unknown 隐式映射为 true。
- [ ] 所有结构整理保持行为不变，ticket 01–05 测试继续通过。

## 验证

- [ ] 运行相关测试：History cover、WebView cache clear、update checker（含缓存/404/空 release）、settings、i18n。
- [ ] `dart analyze` 改动文件无新增 issue。
- [ ] 不新增历史全量失败；已知 manga-only schema / m3e static / lookup 渲染失败保持原记录。
- [ ] 不新增 schema、不改 Backup、不移动文件。
- [ ] ticket 06 更新为 `Status: resolved`，追加 `## Answer`。
