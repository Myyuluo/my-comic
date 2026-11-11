# 03: 重建下载索引预热第一页封面

**What to build:** 运行「重建下载索引」时，为书架中已有、有本地完整文件但缺封面的 Manga 预热生成第一页封面；只处理 Library 成员，不改变重建只重链、不新增的语义。

**Blocked by:** 02（缺失封面时从第一页生成封面）

**Status:** resolved

- [x] 重建重链书架成员时，对 `membership=true`、有完整本地 Chapter container、且没有可用本地/远程/生成封面的 Manga 生成并缓存第一页封面。
- [x] 只处理 Library 成员；不创建 Manga、不改变 membership、不分配 Tag、不移动/复制/删除文件。
- [x] 缓存缺失或 sentinel 过期时才生成；重复运行幂等，不重复生成同一封面。
- [x] 报告包含生成、更新、跳过与失败的封面数量；封面失败不阻断重建，也不把作品计为重建失败。
- [x] 已有本地 `cover.*` 或可用远程封面的作品不被生成封面覆盖。
- [x] 测试覆盖：源未安装 + 本地 CBZ 在重建后获得封面；有远程封面的作品不被覆盖；非书架作品被跳过；坏页计入失败；重复运行幂等。
- [x] 不新增数据库 schema，不改变 Backup 格式。

## Answer

- Merge commit: `431b2b9e005f845549488265953407a9943498d8`（`--no-ff` 合入 `integration/manga-cover-and-shelf-polish`，无冲突）。
- 改动摘要：
  - `RebuildDownloadIndexService` 新增可选 `firstPageCoverService` / `isRemoteCoverAvailable`：仅在重链成功后，对 Library 成员（`membership=true`、有完整本地 Chapter container、无可用本地/远程/生成封面）生成并缓存第一页封面；生成/更新/跳过/失败分别计数，封面失败不阻断重建，也不把作品计为重建失败。
  - `MangaFirstPageCoverService` 抽出可复用生成入口并导出 shelf cover revision；封面字节只写 Program state 的 shelf cover 缓存，远程封面与已有本地 `cover.*` 保持优先。
  - 设置页 rebuild 动作接入该服务；不新增数据库 schema，不改变 Backup 格式。
- 测试结果（`fushi/`，Flutter 3.47.6，全部通过，共 90 个测试）：
  - `test/media/manga/rebuild_download_index_service_test.dart`
  - `test/media/manga/manga_first_page_cover_test.dart`
  - `test/media/sources/manga_shelf_cover_resolution_test.dart`
  - `test/media/manga/manga_series_page_cover_test.dart`
  - `test/media/media_cover_write_guard_test.dart`
  - `test/settings/settings_rebuild_download_index_test.dart`
  - `test/settings/settings_schema_coverage_test.dart`
  - `test/settings/settings_cli_action_coverage_test.dart`
- 遗留：封面生成/更新/跳过/失败计数尚未进入设置页的重建结果摘要，留给 ticket 07。
