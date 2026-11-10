# 02: 重建下载索引只重链书架成员

**What to build:** 把「重建下载索引」收窄为只重链书架中已有漫画的恢复扫描：点击整行触发，扫描当前 Content root 的 `downloads` 与 `local`，只更新 `membership=true` 的 Manga 的下载关联；绝不把磁盘作品加入书架，也不改动非书架记录。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 「重建下载索引」只扫描当前 Content root 的 `downloads` 与 `local`，不读取旧 Content root 或 `autobackup`。
- [x] 只读取和重链 `membership=true` 的 Manga；非书架 Manga 不被读取、改写、重链或删除。
- [x] 不创建任何 Manga 记录，不翻转 Library membership，不分配 Tag，不把 `downloads` / `local` 中书架没有的作品加入书架。
- [x] 保留现有匹配顺序：`pages.json` 下载身份 → 已记录且仍在 `downloads` 内的路径 → `downloads` 无 manifest 目录的文件夹名回退；`local` 无 manifest 目录不按标题匹配。
- [x] 不引入「本机章节」概念：源章节列表为空时不把磁盘容器合成为章节。
- [x] 全程不移动、不复制、不删除、不重命名任何用户文件或映射。
- [x] 行尾「重建」按钮移除，整行可点触发同一动作；确认框、可取消进度框与结果报告保留。
- [x] 副标题使用：「重新关联书架中已有漫画的下载章节，适用于导入备份后有本地下载章节却显示未下载；不会删除记录或文件。」
- [x] 报告不再出现「新增作品」统计；包含扫描书架条目、匹配、重链、缺失、跳过（含歧义）、失败与取消数量。
- [x] 重复运行幂等，不产生重复记录或重复章节。
- [x] 将发现/恢复辅助逻辑抽成可复用模块，供「检索已下载」使用；抽取本身不改变重建的用户可见行为。
- [x] 测试覆盖设置动作 seam 与服务 seam：整行点击、仅书架成员、绝不新增、非书架行不变、文件不移动、幂等。
- [x] 所有新增/修改文案在全部支持语言中同步，并重新生成访问器。

## Answer

- Merge commit: `17bd773653b5aa5d0814a74e1ee4c7c177aafd38`（`Merge ticket 02: rebuild download index for library members only`），来源分支 `worktree-agent-ab72c406494429ce5`（实现提交 `6e2f717a`），无冲突。
- 抽出的复用模块（`fushi/lib/src/media/manga/download/download_manga_recovery.dart`，供「检索已下载」复用）：
  - `DownloadMangaRecovery(database:, downloadsRoot:)`，入口 `Future<DownloadMangaRecoveryOutcome> recover(DownloadMangaFolderOnDisk folder, {required DownloadMangaInstalledSources installedSources, required Set<String> tombstonedBookKeys, required Set<String> existingBookKeys})`。
  - `DownloadMangaInstalledSources.load(FushiDatabase)` + `has(extensionPackage, sourceId)`：判定源是否已安装，决定建在线条目还是降级本地条目。
  - `DownloadMangaRecoveryOutcome`：`added` / `addedOnline` / `addedLocal` / `addedLocalSourceMissing` / `skipped` / `skippedTombstoned` / `chaptersAdded` / `chaptersSkipped`，并提供 `merge` 汇总同目录多身份结果。
  - 行为与重建原先的内联 orphan recovery 一致：按 `pages.json` 身份逐条登记、源未安装降级本地条目、tombstone 与已有行跳过、绝不复活或重复登记；只增改数据库行，不移动/复制/删除/重命名用户文件。
- 改动摘要：
  - `fushi/lib/src/media/manga/download/rebuild_download_index_service.dart`：删除 orphan recovery / 新增作品路径（净减约 690 行），只查询并重链 `membership=true` 的 Manga；保持 `pages.json` 身份 → 已记录 `downloads` 路径 → 无 manifest `downloads` 文件夹名回退的匹配顺序；`local` 无 manifest 不按标题匹配；不合成「本机章节」；找不到的章节保留记录并显示 Missing。
  - `fushi/lib/src/settings/settings_schema_rebuild_index.dart`：`SettingsStatusItem` + 行尾按钮改为整行可点的 `SettingsActionItem`（`onTap`），移除 `actionLabel`，确认框、可取消进度框与结果报告保留；报告改用 `booksScanned` 与 `chaptersRelinked`，不再传 `added` / `local`。
  - i18n：`rebuild_download_index_confirm_body` / `rebuild_download_index_subtitle` / `rebuild_download_index_report_body` 在基准 `strings.i18n.json` 与 `strings_zh-CN.i18n.json` 同步更新（占位符 `$added` / `$local` 换成 `$scanned`；其余 locale 未定义这些 key，回退基准）；`dart run slang` 重新生成 gitignored 的 `lib/i18n/strings.g.dart` 并 `dart format`。
  - 测试：重写 `rebuild_download_index_service_test.dart`（仅书架成员、绝不新增、非书架行不变、文件不移动、幂等），新增 `download_manga_recovery_test.dart` 覆盖复用模块，`settings_rebuild_download_index_test.dart` 覆盖整行点击 seam，并调整 `manga_series_page_downloaded_status_test.dart` 的书架前置条件。
- 测试（在 `fushi/` 下，`PUB_HOSTED_URL=https://pub.dev`，Flutter `D:\ProgramData\flutter_3.47.6\bin\flutter.bat`）：

  ```
  flutter test test/media/manga/rebuild_download_index_service_test.dart \
    test/media/manga/download_manga_recovery_test.dart \
    test/settings/settings_rebuild_download_index_test.dart \
    test/media/manga/manga_series_page_downloaded_status_test.dart \
    test/settings/settings_downloads_open_page_subtitle_guard_test.dart \
    test/settings/download_cbz_setting_test.dart \
    test/i18n/i18n_keys_sorted_guard_test.dart
  ```

  结果：`All tests passed!`（72 个测试通过）。
