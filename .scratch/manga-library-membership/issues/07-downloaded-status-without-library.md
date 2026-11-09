# 07: 已下载状态脱离书架

**What to build:** 在线作品详情页不再要求 Library 行即可计算已下载状态：按 entry 身份查询下载索引，无行时扫描 `downloads` 与带 manifest 的 `local`；非书架作品、源页作品与重新加入的作品都显示已下载章节。`local` 无 manifest 的文件夹不做标题匹配。

**Blocked by:** 02（非书架行与在线阅读）、06（下载身份与文件夹复用）

**Status:** resolved

- [x] 详情页对任意在线 entry 计算已下载状态，不再因 `_row == null` 提前返回。
- [x] 非书架作品在源页显示已下载章节。
- [x] 重新加入书架的作品显示移出前已下载的章节。
- [x] `downloads` 与 `local` 中带 manifest 的文件都参与匹配。
- [x] 无 manifest 的 `local` 文件夹不被按标题关联。
- [x] 已下载状态在书架页、源页、下载页使用同一身份判断。
- [x] 页面级测试覆盖非书架、重加、local manifest、无标题匹配与一致性。

## Answer

Ticket 07 已由 commit `b93bf848`（`feat(manga): compute downloaded status without a library row (ticket 07)`）实现，并合入 `integration/manga-library-membership`（merge commit `c7627b77`）。

- **身份判据**：新增 `DownloadLibraryIndex.downloadedChapterKeysForEntry()`（`fushi/lib/src/media/manga/download/download_library_index.dart`）。不再要求 Library 行：有行时先走记录的映射（`extractDir` + `manga_chapter_dirs`，最精确），映射没覆盖的章再按共享 `MangaDownloadIdentity`（runtime + 规范化数字 sourceId + seriesKey，扩展包兼容性由 `downloadExtensionPackagesCompatible` 判定）扫描 `downloads` 与 `local` 的 `pages.json`。`MangaDownloadDiskIndex.scan` 先为每个 Manga 文件夹只读第一份 manifest 做身份探针，只对身份匹配的文件夹再读完整章表并检查完整性，因此打开一部作品不会验证全库每一章。
- **不做标题匹配**：只有 `pages.json` manifest 能证明身份；无 manifest 的目录（含 `local` 无 manifest 文件夹）一律不按标题/文件夹名猜测。同一身份有多个目录都能证明时同样不猜（返回空，交给重建索引处理）。
- **详情页**：`manga_series_page.dart` 的 `_refreshDownloadState()` 在 `_row == null` 时不再提前返回；无行时 `bookKey` 回退到 `OnlineMangaLibraryService.bookKeyOf(entry)` 查询任务表。结果合并「记录映射」与「manifest 扫描」，并按身份 + 章节表 + 任务状态签名缓存扫描结果（进度更新不触发全库重扫）；revision 计数器避免并发旧结果覆盖；章节表刷新后自动重算；单章/批量删除下载时立即失效缓存并从 `_downloaded` 中移除，避免等待异步重扫期间仍显示已下载。Local source 的 Missing 判定仍要求行且目录在当前 `local` 根内。
- **一致性**：书架筛选 `computeMangaShelfDownloadedBookKeys()`（`manga_shelf_download_state.dart`）复用同一个 `MangaDownloadDiskIndex` 与同一身份规则（映射未证明时补 manifest 扫描，无 manifest 不按标题匹配），因此书架「已下载」筛选、页签数量与作品页/源页状态一致；本地图源的判据保持「至少一章真的可读」。
- **限制（重要）**：只有 manifest、没有 `manga_chapter_dirs` 映射的下载目录，当前只提供**展示层**的已下载状态（章节行显示已下载，「已下载/未下载」筛选与页签数量计入），文件尚未被 re-link 到作品/章节行；实际阅读与管理这些 manifest-only 目录需等 ticket 12 的「重建下载索引」完成关联。
- **测试**：`flutter test test/media/manga/manga_series_page_downloaded_status_test.dart test/media/manga/download_library_index_test.dart test/pages/manga_library_search_and_download_filter_test.dart test/media/manga/online_manga_library_test.dart test/media/manga/rebuild_download_index_service_test.dart test/media/manga/library/` 共 125 项全部通过（本次无需重新生成 `lib/i18n/strings.g.dart`；`flutter test` 顺带改写的 generated plugin registrant 文件已还原）。
- **票 commit**：`b93bf848`。
