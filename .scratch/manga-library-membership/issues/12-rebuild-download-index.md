# 12: 重建下载索引

**What to build:** 让「重建下载索引」真正成为强制扫描入口：扫描 `downloads` 与 `local`，按 `pages.json` 身份优先 re-link 所有已有 Manga 行（含 membership=false），身份不中再回退文件名；`local` manifest 可关联到在线 Manga；保留 orphan recovery；重复副本优先 recorded `extractDir`/最新完整副本，否则跳过并报告；不删除/重命名文件；完成后刷新已打开详情页。

**Blocked by:** 06（下载身份与文件夹复用）、07（已下载状态脱离书架）

**Status:** resolved

- [x] 重建强制扫描 `downloads` 与 `local`，不扫描 `autobackup`。
- [x] 按 manifest 身份优先 re-link 所有 Manga 行（含非书架）。
- [x] 身份匹配不到时回退文件名匹配。
- [x] `local` 中带 manifest 的文件可关联到在线 Manga。
- [x] 保留 orphan recovery（为未索引内容补建条目）。
- [x] 重复副本优先 recorded `extractDir`/最新完整副本，否则跳过并报告。
- [x] 不删除、不重命名文件或映射。
- [x] 完成后已打开的详情页刷新已下载状态。
- [x] 报告匹配/跳过/歧义/失败数量。
- [x] 服务与页面测试覆盖上述行为。

## Answer

实现提交：`4dcd9529`（feat(manga): rebuild download index as full re-link scan (ticket 12)），经 merge commit `eb1d0079` 合入 `integration/manga-library-membership`（无冲突；`strings.g.dart` 为 gitignore 生成物，已用 Slang 重新生成验证）。

- **全量扫描：** 服务只接收当前 Content root 的 `downloads` 与 `local` 两个根，扫描 `downloads/<source>/<manga>` 与 `local` 中带 `pages.json` 的漫画目录；`autobackup` 在结构上不会被读取（测试确认 extractDir 落在 content root 内且不在 autobackup）。
- **所有 Manga 行 re-link：** 读取 `getAllEpubBooks()` 的全部行（membership true/false 都处理），先按 `pages.json` 稳定身份（runtime / extension / sourceId / mangaKey / chapterKey）重新定位；身份匹配不到时仅对 `downloads` 里无 manifest 的旧目录回退文件夹名。更新 `epub_books.extractDir` 与 `manga_chapter_dirs`，只增改、不删除；非书架行的 membership 不被改写。
- **local manifest 关联：** `local` 中带 manifest 的文件夹参与在线身份匹配，命中后把在线行（含非书架）的 `extractDir` 指向该本地目录并写入章节映射；身份已被在线行覆盖时不再补建重复的本地条目，第二次重建幂等。无 manifest 的 local 目录不按标题猜测。
- **重复副本偏好：** 同身份多副本时优先 recorded `extractDir`，否则选最新完整副本；时间并列或无完整副本时整本跳过并计入 ambiguous，不猜。未采用的副本会被排除在 orphan recovery 之外，不会再次登记。全程不删除、不重命名文件或映射。
- **orphan recovery：** 保留既有语义，为 `downloads`/`local` 中未索引内容补建条目：源已安装的 downloads 建在线条目，源未安装或缺少 `pages.json` 时降级为本地条目。墓碑（主动移出书架）作品不复活；local manifest 证明属于已移出书架的在线作品时同样跳过并报告，避免借本地条目复活。
- **页面刷新信号：** 新增进程级 `DownloadLibraryChanges`（ChangeNotifier，带 revision）。重建在 `finally` 中广播（取消/异常也发，已写入的部分结果同样需要展示）；已打开的作品详情页监听后清空 manifest 扫描缓存并重算已下载状态，无需重新进入页面。
- **报告：** 报告新增 matched / skipped / ambiguous / failed 等计数（以及 addedOnline/addedLocal/relinked/missing 等），en 与 zh-CN 文案同步更新；设置页报告弹窗展示这些数量。
- **测试：** `test/media/manga/rebuild_download_index_service_test.dart`（非书架行、local manifest 关联、重复偏好/歧义、墓碑、幂等）、`test/media/manga/manga_series_page_downloaded_status_test.dart`（页面打开期间重建后实时刷新）、`test/settings/settings_rebuild_download_index_test.dart`、`test/media/manga/download_library_index_test.dart`、`test/pages/manga_nonlibrary_reading_test.dart` 共 66 个测试通过。

**已知限制：** 在线行经 local manifest 关联后，`extractDir` 指向 `local/`。后续重建的「沿用 recorded `extractDir`」规则与文件名回退都只覆盖当前 `downloads` 根内的路径，因此该关联只能靠 `pages.json` 身份再次命中；若该本地目录的 `pages.json` 消失或不可解析，重建会把作品报为 missing/skipped，而不会按记录的 local `extractDir` 直接复用（重复副本偏好仍会优先记录路径）。
