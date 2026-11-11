# 04: 封面 URL 失败驱动自动续签

**What to build:** 封面加载失败（403、签名过期、5xx、解码失败）且 Source 可用时，应用自动做一次详情-only 刷新，落库新的 `series.coverUrl`、刷新持久字节并让书架立即重算；通过节流避免坏 Source 被反复请求。

**Blocked by:** 01（书架封面缓存写入后立即刷新）

**Status:** resolved

- [x] 封面字节获取失败且 Source 已安装/启用时，触发一次详情-only 刷新；不要求章节列表刷新成功。
- [x] 刷新成功时持久化新的系列描述与 `series.coverUrl`，保留旧章节列表（章节为空/失败不清空），刷新持久字节，并通过 ticket 01 的 revision/invalidation 让书架立即显示。
- [x] 每本书每次应用启动最多自动续签一次，并有 24 小时冷却；冷却期内不重复请求。
- [x] Source 未安装/停用、平台不支持或网络不可用时跳过自动续签，使用本地/生成封面或占位。
- [x] 自动续签失败时保留旧缓存/占位，不删除已有封面字节，不进入重试循环，记录日志。
- [x] 手动「刷新漫画」与 24 小时更新探针的既有行为保持不变；自动续签是额外的失败驱动恢复路径。
- [x] 切换 URL 后旧的失败图片缓存不会继续压制新封面。
- [x] 测试覆盖：旧 URL 403 → 详情返回新 URL → 落库/字节/书架更新；章节失败但封面落库；冷却不重复；源缺失跳过；连续失败不循环。
- [x] 按 ADR 0023 记录自动续签/节流策略；不新增数据库 schema。

## Answer

已合并到 `integration/manga-cover-and-shelf-polish`。

- Merge commit: `e2c357117e3291d155cfac2d7548da992ad2b310`（`Merge ticket 04: auto-renew expired cover URLs`）
- 合并前 integration HEAD: `60fca859596a88c05d73a88f8a95956bb722bfa7`
- 合并后 integration HEAD: `e2c357117e3291d155cfac2d7548da992ad2b310`
- 冲突: 无（ort 策略自动合并；ticket 01 revision 与 URL 感知 cacheKey 保留）

改动摘要：

- 新增 `fushi/lib/src/media/manga/library/manga_shelf_cover_renewal.dart`：失败驱动自动续签的节流策略，每本书每次应用启动最多一次，并有持久化 24 小时冷却（Program state shelf cover 缓存下的 `.renew` sidecar）。
- 新增 `MangaShelfCoverService` 的续签路径：封面字节获取失败（403/404/5xx、签名过期、解码失败）且 Source 已安装/启用时，经 `OnlineMangaLibraryService.refreshFromSource` 做一次详情-only 刷新。
- 刷新得到的系列描述与 `series.coverUrl` 即使章节失败或为空也会落库，保留旧章节列表；新 URL 经扩展运行时抓取后写入 bookKey 封面缓存并 bump ticket 01 的 revision，书架立即重算。
- 失败计入尝试次数、不进入重试循环，保留旧字节或占位；Source 缺失/停用、平台不支持、刷新失败均跳过并记录日志。
- 手动刷新与 24 小时更新探针行为不变；ADR 0023 记录续签/节流策略，未新增数据库 schema。

测试（`fushi/`，Flutter 3.47.6，先 `dart run slang`）：10 个测试文件共 72 个测试全部通过。

- `test/media/sources/manga_shelf_cover_resolution_test.dart`
- `test/media/sources/reader_fushi_imported_cover_fallback_test.dart`
- `test/media/sources/reader_fushi_cover_cache_test.dart`
- `test/media/reader_fushi_source_watch_guard_test.dart`
- `test/media/manga/manga_series_page_cover_test.dart`
- `test/media/manga/manga_series_missing_source_test.dart`
- `test/media/media_cover_write_guard_test.dart`
- `test/pages/manga_shelf_series_return_refresh_test.dart`
- `test/updates/online_manga_update_probe_test.dart`
- `test/pages/manga_library_continue_pill_test.dart`
