# 07: 在线封面持久字节缓存

**What to build:** 通过 Extension runtime 获取在线漫画封面字节，按 bookKey 缓存在 Program state 的封面缓存中，使书架封面在签名 URL 过期、防盗链或需要 headers/cookies 时仍能稳定显示；缓存不写入 Download library。

**Blocked by:** 06（在线封面元数据刷新与 URL 合并）

**Status:** resolved

- [x] 在线封面字节通过 Extension runtime 获取，复用 Extension 的 headers、cookies 与站点鉴权。
- [x] 封面字节按 bookKey 缓存在 Program state 的封面缓存中，不写入 Content root、不写入 Download library、不创建下载目录。
- [x] 书架封面解析顺序为：按 bookKey 的持久封面缓存 → 本地封面文件 → 已保存的远程封面 URL（现有 HTTP 图片缓存）→ 占位。
- [x] 签名 URL 过期后，只要持久封面缓存存在，书架仍显示封面。
- [x] 获得新的封面 URL 后后台刷新持久封面字节；刷新失败时保留旧缓存，不删除已有封面。
- [x] 封面缓存有容量/数量上限与淘汰规则，并随「清除缓存」清理；清除后回退到远程 URL 或占位。
- [x] 来源未安装/未启用时不做运行时封面抓取；已有本地封面或持久缓存仍显示，否则占位。
- [x] 测试在书架封面解析 seam 上覆盖：过期 URL + 持久缓存、headers/cookies 场景、新 URL 后台刷新失败保留旧缓存、清除缓存回退、来源缺失不抓取、不产生 Download library 目录。
- [x] 不改变 Backup 导出/导入格式，封面缓存不进入 Backup。
- [x] 书架与作品页视觉保持不变，遵守 ADR 0008。

## Answer

- Merge commit: `8efe5f56baa4f5c2df6f157e7caceb1ee6412b75`（`Merge ticket 07: durable online cover cache`，合入 `integration/manga-shelf-download-ux`，无冲突）。
- 缓存位置：`<programState>/cache/shelf_covers`（`AppPaths.cacheRoot` 下），文件名是 `sha256(bookKey).cover`，另存同名 `.url` 侧车记录产生该字节的源 URL。不写入 Content root、Download library，不创建下载目录，也不进入 Backup。
- 淘汰策略：默认上限 512 条 / 64 MiB；每次写入后 `trim()` 按文件 mtime 升序淘汰最旧条目，连同 `.url` 侧车一起删除。写盘使用临时文件 + rename，空字节不覆盖旧缓存；覆盖写后驱逐 Flutter ImageCache 旧解码。
- 改动摘要：
  - 新增 `MangaShelfCoverCache`（持久字节缓存）与 `MangaShelfCoverService`（解析/后台刷新编排）。
  - `ReaderFushiSource` 书架解析顺序改为「持久缓存 → 本地封面 → 远程 URL → 占位」；来源 URL 变化或尚无缓存时以 `unawaited` 后台刷新，失败只记日志并保留旧缓存。
  - `OnlineMangaRuntimeAdapter.fetchCover` 走 Extension 网络栈（headers/cookies/站点鉴权）；新增 `OnlineMangaSourceAvailability`，`MihonLibraryAdapter` 仅查 Source 表判断来源是否已安装/启用，不做运行时初始化、不联网。
  - 「清除缓存」新增 `shelf_covers` 步骤并 `invalidate(fushiBooksProvider)`，清除后书架回退到远程 URL 或占位；新增 i18n key `cache_clear_step_shelf_covers`（17 个语言文件）。
- 测试：`manga_shelf_cover_resolution_test.dart`（6 项）、`reader_fushi_imported_cover_fallback_test.dart`、`manga_series_page_cover_test.dart`、`manga_cache_clear_settings_test.dart`、`manga_cache_clear_service_test.dart`、`i18n_keys_sorted_guard_test.dart` 全部通过（先执行 `dart run slang` 生成访问器）。
