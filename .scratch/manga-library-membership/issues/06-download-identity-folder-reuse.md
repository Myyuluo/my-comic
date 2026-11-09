# 06: 下载身份与文件夹复用

**What to build:** 统一在线漫画的下载身份为 `(runtime, 数字 sourceId, seriesKey)`，扩展包只作 tie-breaker；在目标来源目录下按 `pages.json` 身份复用已有漫画文件夹，包含 `.cbz` 内的 manifest。恰好一个匹配才复用；多个匹配不猜；无 manifest 保持现有 `(2)` 安全规则。复用后立即重建该作品的章节映射。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 统一下载身份为 runtime + 数字 sourceId + seriesKey；`mihon.unavailable` 与真实包视为同一身份。
- [x] 目标来源目录下恰好一个 Manga 文件夹/章节 manifest 匹配时，复用该文件夹。
- [x] 多个匹配时不随意选择，保持冲突/`(2)` 行为。
- [x] 无 manifest 的现有文件夹仍按现有规则生成 `(2)`，不覆盖。
- [x] `.cbz` 章节内部的 manifest 参与身份匹配。
- [x] 复用后立即重建该作品的章节映射，详情页显示已下载。
- [x] 不删除、不重命名已有文件或文件夹。
- [x] 服务测试覆盖复用、无 manifest、歧义、CBZ、复用后映射。

## Answer

Implemented in `99abaf41`; merged as `1e9757b7`.

统一下载身份：新增 `fushi/lib/src/media/manga/download/download_identity.dart`。`MangaDownloadIdentity` 的判据是 `runtime + 数字 sourceId + seriesKey`：`downloadSourceIdKey` 把纯十进制 sourceId 归一为数值（`001` 与 `1` 相同），非数字来源按去空白原串比较。扩展包只做 tie-breaker：`mihon.unavailable` 占位包、空扩展包（旧描述符未记录）与真实包均视为同一身份兼容；`matchesManifestPackage` 只在双方都是相同的真实包时提供精确加分。`DownloadSourceIdentity` 复用同一套规则判断 `downloads/<source>` 目录归属，来源改名或占位/真实包混用不会把同一来源拆成多个目录。`MangaDownloadService._manifestBelongsTo` 也改用这份判据，下载认领、文件夹复用与 Rebuild 三处不再各写一份。

共享扫描器：新增 `download_library_scanner.dart`，统一扫描 `downloads/<source>/<manga>/<chapter>`；目录章节与 `.cbz` 都从包内 `pages.json` 读 manifest，点号目录（`.staging` 等）一律忽略，按小写名排序保证扫描确定。`matchDownloadMangaFolderByIdentity` 先按核心身份匹配，恰好一个目录命中才复用；多个候选时用相同真实扩展包做 tie-breaker，仍不唯一即 `ambiguous`，一个都不选；没有任何 manifest 的目录不参与身份复用。

共享 re-link：新增 `download_manga_relinker.dart`，文件夹复用（`OnlineMangaLibraryService._resolveDownloadMangaDirectory` / `ensureBookDirectory`）与 Rebuild download index 共用 `relinkDownloadMangaFolder`：`pages.json` 稳定身份优先，已有 `manga_chapter_dirs` 映射与容器名回退（容忍扫译组 `[..]` 与 `(2)` 后缀）兜底；每个章 key 最多映射一个容器，多候选跳过；只增改 `manga_chapter_dirs` 与 `epub_books.extract_dir`，绝不删除或重命名文件，支持取消。复用后立即执行 re-link，详情页无需手动跑 Rebuild 即显示已下载。

文件夹复用规则（`online_manga_library_service.dart`）：Source 目录先按 `DownloadSourceIdentity`（含磁盘 manifest 证据）复用；Manga 目录在目标 source 下按 manifest 身份匹配——恰好一个匹配直接复用（目录名不再是身份，作品改名也不会生成 `(2)`）；多个匹配不猜，继续走既有冲突后缀 / `(2)` 规则且不改动、不删除已有目录；无 manifest 的现有目录仍按原 `(2)` 安全规则避让，不覆盖。

测试：`flutter test test/media/manga/online_manga_library_test.dart test/media/manga/rebuild_download_index_service_test.dart test/media/manga/manga_download_service_test.dart test/media/manga/download_library_index_test.dart test/media/manga/library/` 143 项全部通过。新增覆盖：改名后复用、CBZ 内 manifest、无 manifest 的 `(2)`、多匹配歧义、扩展包 tie-breaker、占位包兼容、`ensureBookDirectory` 复用与复用后立即映射。
