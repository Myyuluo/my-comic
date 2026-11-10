# 08: Code review 修复

**What to build:** 修复 `code-review`（Standards + Spec）在 `80d70736...d8a72a09` 上确认的问题：先修行为/规范违规，再收敛结构重复。

**Blocked by:** 01–07（均已 resolved）

**Status:** ready-for-agent

## 行为与规范修复

- [ ] **i18n 纪律**：给 `fushi/tool/i18n_sync.dart` 增加 per-locale 写入能力（如 `--set <key> <locale> <value>`，可重复/混用，纳入 usage 与契约测试），并用它写入 `backup_index_section` 与 `rebuild_download_index_report_covers` 的全部 16 个非英文 locale 译文；不要手动逐文件编辑。现有「非英文 locale 必须不同于英文」guard 保留；确认 17 个文件 key 完整、排序正确。
- [ ] **离线不消耗续签冷却**：网络不可用/连接失败时不得持久化 24h 续签冷却；in-process 每启动一次的去重仍保留。离线启动后网络恢复，这本书仍应能在本次启动内自动续签一次。
- [ ] **重建预热封面检测**：生成前检查 `epub_books.cover_path`、`LocalSourceMetadata.coverRelativePath` 与根目录 `cover.*`；已有记录封面（含页路径）的作品不得重复生成、不得计入 generated。
- [ ] **cacheKey 作用域收敛**：撤回共享 `MediaSource.getImageProvider` 对所有媒体类型的全局 URL cacheKey 改动；只对书架封面做定向失效/定向 key，确保其他媒体类型缓存键不变、不触发全量远程图重下载，同时书架 URL 切换后不命中旧失败条目。
- [ ] **文件夹 sentinel**：sentinel 必须能感知 container 变化，不能只依赖第一页文件 size/mtime；包含目录 fingerprint（如目录 mtime、文件数、第一页路径/大小/mtime 的组合）并补测试：替换容器但保持第一页 size/mtime 不变时重新生成。
- [ ] **规范阅读顺序回退**：映射容器不可读/不完整时，回退选择 `mangaReadingOrder(entry.chapters).first` 中仍可用的章节，不得按目录扫描顺序随意选章。
- [ ] 不新增数据库 schema、不改 Backup、不写 Content root / Download library、不移动文件。

## 结构整理（Standards）

- [ ] 抽出 `manga_first_page_cover_service.dart` 的 in-flight 去重与第一页路径推导 helper，消除重复。
- [ ] 把续签节流持久化从 `manga_shelf_cover_cache.dart` 移到 `manga_shelf_cover_renewal.dart`，让缓存文件只负责字节与淘汰。
- [ ] 收敛封面优先级：抽出一份共享的解析/决策逻辑，供书架、作品页、重建预热共用，避免三处重复。
- [ ] 减少 service 互相借内部：用共享 context/factory 或明确注入依赖，避免为借一个 predicate 构造整个 service。
- [ ] 如可行，引入小类型表示 shelf cover cache key 与 sentinel，替代字符串拼接+前缀嗅探；若风险过大，记录取舍。
- [ ] 所有结构整理保持行为不变；ticket 01–07 的测试继续通过。

## 验证

- [ ] 运行本批相关测试：cover resolution/renewal、first-page cover、rebuild、series page cover、pill、settings、i18n 工具契约、i18n completeness/sorted/mojibake。
- [ ] `dart analyze` 改动文件无新增 issue。
- [ ] 不新增历史全量失败；已知 `cover_write_sink_bug_2496` / manga-only schema 失败保持原记录。
- [ ] ticket 08 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、结构整理取舍说明）。
