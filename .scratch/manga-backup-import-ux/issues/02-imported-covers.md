# 02: 导入作品封面远程回退

**What to build:** 导入的 Library 作品在本地没有封面文件时，书架与作品页回退到备份已存的 `series.coverUrl`，通过现有 HTTP 图片缓存懒加载；本地封面始终优先，远程加载失败继续使用占位封面。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 书架封面的解析顺序为：显式 `cover_path` → 本地 `cover.jpg/jpeg/png` → 备份 `series.coverUrl` → 占位封面。
- [x] 有本地封面时行为不变，远程回退不会覆盖本地封面。
- [x] 远程封面通过现有 HTTP 图片缓存加载，滚动时不会重复下载。
- [x] 远程封面 URL 为空、过期、防盗链或网络失败时显示现有占位封面，不影响其他作品。
- [x] 远程回退不写入本地「最近可用封面」缓存，保持离线语义。
- [x] 作品页封面同样使用本地优先、`series.coverUrl` 回退，并以占位封面兜底。
- [x] 远程封面回退不依赖 Source 是否安装。
- [x] 不引入导入时批量下载封面或封面预取队列。
- [x] 页面级测试覆盖本地优先、远程回退、失败占位与本地缓存语义。

## Answer

Implemented in `fcf99738`, merged as `6d9a86c2`. 书架解析链在本地 `cover_path` 与磁盘封面探测全部落空后，回退到备份描述符里的 `series.coverUrl`，通过 `MediaItem.imageUrl` 交给现有 HTTP 图片缓存（`AppCachedHttpImage`）懒加载；该远程地址不写入 `_lastGoodCoverUrlByBookKey`，保持离线语义。作品页封面顺序为本地文件 → 源浏览远端 builder → `series.coverUrl`（经同一 HTTP 图片缓存）→ `MangaCoverPlaceholder`，远程加载失败仅记录诊断并回到占位块，不影响其他作品；回退不依赖 Source 是否安装，未引入批量下载或预取队列。新增 `reader_fushi_imported_cover_fallback_test.dart` 与 `manga_series_page_cover_test.dart`，连同既有 cover cache / case-insensitive 测试共 28 项全部通过。
