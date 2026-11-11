# 01: 书架封面缓存写入后立即刷新

**What to build:** 手动刷新或后台封面字节写入成功后，书架立即重新解析并显示新封面；从作品页返回书架时也重新解析，不需要重启或等待下一次无关刷新。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 封面字节服务能报告本次写入成功或失败；成功写入 Program state 的 shelf cover 缓存后 bump 一个进程级封面 revision。
- [x] 书架数据 provider 监听该 revision；revision 变化后重新解析 `MediaItem`，卡片使用新的持久缓存封面。
- [x] 从作品页返回书架时主动 invalidate/刷新书架 provider，而不是只刷新 shelf maps。
- [x] 切换封面 URL 后，旧的失败图片缓存条目不会继续压制新封面；必要时清掉该 bookKey 的旧图片缓存。
- [x] 失败或没有新字节时不产生无意义的 provider 重建。
- [x] 测试覆盖：字节写入成功 → revision → 书架新封面；作品页返回 → 书架刷新；失败不触发重建。
- [x] 不写 Content root / Download library，不改数据库 schema，遵守 ADR 0008。

## Answer

已合并到 `integration/manga-cover-and-shelf-polish`。

- Merge commit: `44ecd25a95cb61a6e882dd2c5c5837392bd2ac13`（`Merge ticket 01: refresh shelf after cover cache writes`）
- 合并前 integration HEAD: `65277501328874da44ce27829074d2005105661b`
- 合并后 integration HEAD: `44ecd25a95cb61a6e882dd2c5c5837392bd2ac13`
- 冲突: 无（ort 策略自动合并；ticket 05/06 改动保留）

改动摘要：

- 新增 `fushi/lib/src/media/manga/library/manga_shelf_cover_revision.dart`：进程级封面 revision，只在成功写入新的持久封面字节后 bump；失败或空字节保持静默。
- `MangaShelfCoverService.refreshIfNeeded` 返回本次是否真的写入新字节，并仅在成功时 bump revision。
- `fushiBooksProvider` 订阅 revision 流，变化后重新解析 `MediaItem`，卡片立即改用新的持久缓存封面。
- 从 `MangaSeriesPage` 返回书架时 `ref.invalidate(fushiBooksProvider(JapaneseLanguage.instance))`，不再只刷新 shelf maps。
- 远程封面 `cacheKey` 带上实际 URL（`'${item.uniqueKey}|$remoteUrl'`，使用可打印分隔符），签名 URL 切换后不会继续命中旧失败缓存。
- 保留 ticket 05/06 的 provider watch、作品页返回 invalidate 与 URL 感知 shelf cacheKey 等改动。

测试（`fushi/`，Flutter 3.47.6，先 `dart run slang`）：9 个测试文件共 58 个测试全部通过。

- `test/media/sources/manga_shelf_cover_resolution_test.dart`
- `test/media/sources/reader_fushi_imported_cover_fallback_test.dart`
- `test/media/sources/reader_fushi_cover_cache_test.dart`
- `test/media/reader_fushi_source_watch_guard_test.dart`
- `test/media/manga/manga_series_page_cover_test.dart`
- `test/media/manga/manga_series_missing_source_test.dart`
- `test/media/media_cover_write_guard_test.dart`
- `test/pages/manga_shelf_series_return_refresh_test.dart`
- `test/pages/manga_library_continue_pill_test.dart`
