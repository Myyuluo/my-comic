# 11: 导入后自动匹配下载

**What to build:** `.tachibk` 导入成功后，自动对已导入 Manga 执行一次下载匹配：读取 `downloads` 与带 manifest 的 `local`，按下载身份复用文件夹并写入章节映射；不额外创建 Library 条目；报告匹配/跳过数量；重复导入幂等。

**Blocked by:** 06（下载身份与文件夹复用）、07（已下载状态脱离书架）、10（导入非书架行与 History 修复）

**Status:** resolved

- [x] 导入成功后自动 re-link 已导入 Manga 的 `downloads` 文件。
- [x] `local` 中带 manifest 的文件参与匹配。
- [x] 匹配复用已有文件夹并写入章节映射，不产生 `(2)`。
- [x] 导入自动匹配不额外创建 Library 条目。
- [x] 导入报告显示下载匹配/跳过数量。
- [x] 重复导入保持幂等。
- [x] 页面级与导入服务测试覆盖自动匹配、复用、报告与幂等。

## Answer

实现提交：`68dfc016`（feat(import): auto-relink downloaded files after .tachibk import (ticket 11)），经 merge commit `9d2fc31c` 合入 `integration/manga-library-membership`（无冲突；`strings.g.dart` 为 gitignore 生成物，已用 Slang 重新生成验证）。

- **窄范围导入后重链：** 导入事务提交后，只对本次导入/合并成功并完整落库的 Manga 行（`importedBookKeys`）执行一次匹配：以当前 Content root 的 `downloads` 与带 manifest 的 `local` 为候选，复用共享的 `pages.json` 身份判据（`MangaDownloadIdentity`）、目录探针、章节容器扫描与 `relinkDownloadMangaFolder`，写入 `epub_books.extractDir` 与 `manga_chapter_dirs`。不扫描 `autobackup`、不新建 Library 条目、不补建 orphan、不创建/移动/删除/重命名任何文件，也不会产生 `(2)` 文件夹；全量扫描仍是 ticket 12 的「重建下载索引」入口。重链在导入事务之外执行，失败不回滚已提交的导入，报告只是不带下载计数，重跑手动重建即可重试。
- **匹配规则与跳过：** 每个导入行在 `downloads` 中按身份找唯一目录；`downloads` 无命中再查 `local`。能证明同一身份的目录不唯一（歧义）时不猜测，计入 `downloadMangaSkipped`；目录内的章容器若同一章 key 有多候选，计入 `downloadChaptersSkipped`。完全找不到目录视为「未下载」，不算 skip。两个根都为空（或没有子目录）时跳过所有磁盘 I/O。
- **报告计数：** `MihonBackupImportReport` 新增 `downloadMangaMatched` / `downloadMangaSkipped` / `downloadChaptersRelinked` / `downloadChaptersSkipped`；完成弹窗在任一下载计数非零时显示 `backup_import_mihon_summary_downloads`（"Downloads: X matched, Y chapters linked, Z skipped"，17 个语言文件同步新增该 key 并按字典序插入），零匹配时保持隐藏，不打扰普通导入。
- **幂等：** 重链只增改映射，重复导入同一备份会把相同目录与章节映射刷新为同一状态，不新增重复行；导入服务与页面测试覆盖了二次导入后的 `manga_chapter_dirs` 不增长与报告一致。
- **测试：** `test/backup_import/`（导入服务自动匹配 downloads/local、无 manifest local 不按标题猜、重复目录歧义跳过、书架与非书架行、幂等，以及报告弹窗与导入流程）、`test/media/manga/rebuild_download_index_service_test.dart`、`test/media/manga/manga_series_page_downloaded_status_test.dart`、`test/settings/settings_rebuild_download_index_test.dart`、`test/i18n/i18n_keys_sorted_guard_test.dart` 共 162 个测试通过。

**已知限制：**
- **每目录只读第一份 manifest：** 身份探针只读取 Manga 文件夹中第一份可解析的 `pages.json`（`readFirstDownloadMangaManifest`）用于判断目录归属；首个容器没有可解析 manifest 的目录不会参与匹配，首份 manifest 与导入身份不符时即使后续章节属于该作品也不会命中。这是为了避免为每个目录读完整章表，属于尽力而为的匹配。
- **local 单章作品映射有限：** 单章作品把 `pages.json` 直接放在 `local/<manga>/` 根，身份探针会读取根 manifest 以命中作品并重指 `extractDir`；但共享的 `relinkDownloadMangaFolder` 只扫描子章节容器，不会把根 manifest 当作章节容器，因此该单章的 `manga_chapter_dirs` 映射不会被这条导入后重链写入（需依靠后续手动重建/下载流程补齐）。
