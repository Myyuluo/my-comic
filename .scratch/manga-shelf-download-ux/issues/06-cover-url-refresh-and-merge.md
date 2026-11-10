# 06: 在线封面元数据刷新与 URL 合并

**What to build:** 让在线漫画的封面 URL 能在签名过期后自愈：详情/封面刷新与章节刷新解耦，章节列表为空或抓取失败时仍持久化新的封面 URL；打开源搜索/详情页识别到已有书架作品时，把源当前返回的封面 URL 合并回该记录。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 源详情刷新成功时，即使章节列表为空或章节抓取失败，也持久化新的系列元数据与封面 URL。
- [x] 源返回空章节列表而本地已有非空章节时，保留旧章节缓存，不清空章节列表。
- [x] 打开源搜索结果或源详情页并识别到已有书架记录时，把当前系列描述（至少封面 URL）合并回该记录，不要求用户手动刷新。
- [x] 签名 URL 过期后，用户手动刷新作品页或重新打开对应源页面，书架封面恢复显示。
- [x] 来源未安装/未启用时，作品页仍保持灰占位、不发起远程封面请求；书架若有本地封面则继续显示。
- [x] 封面 URL 的刷新与合并不写入 Download library、不创建下载目录。
- [x] 测试在在线元数据刷新与书架封面解析 seam 上覆盖：章节为空仍保存新 URL、旧章节保留、源页面合并 URL、过期 URL 自愈、来源缺失不请求。
- [x] 不改变 Backup 导出/导入格式。

## Answer

- Merge commit: `bbb663dc5b432afc9c5fa279fb6754c7aaf30cab`（`Merge ticket 06: refresh and merge online cover URLs`），来源分支 `worktree-agent-a0e175e08d2df3dad`（实现提交 `5a8293f3`），无冲突。
- 改动摘要：
  - `fushi/lib/src/media/manga/library/online_manga_runtime_adapter.dart`：详情与章节阶段拆开兜底（stage 仍分开记录，保留 BUG-1767 语义）；章节阶段失败时 `OnlineMangaUnavailable.series` 携带详情阶段已拿到的系列描述（含新封面 URL），调用方可先落库再报错。
  - `fushi/lib/src/media/manga/library/online_manga_library_service.dart`：`refresh` 在源返回空章节且本地已有非空章节时保留旧章节列表，但系列元数据与封面 URL 照常落库；仅在章节确实刷新时才做下载重链与新章提醒。`refreshFromSource` 改为返回 `OnlineMangaRefreshOutcome(entry, chaptersError)`：章节失败时先把详情落库（旧章节保留），再把错误交回界面。新增 `mergeSeries`：按「非空优先」把源当前系列描述（至少封面 URL）合并回已有记录，身份 key、章节、当前章、订阅位与阅读进度均保留，不联网、不抓封面字节、不写 Download library。
  - `fushi/lib/src/media/manga/library/manga_series_page.dart`：打开源搜索/详情页识别到已有记录时直接调用 `mergeSeries` 合并当前封面 URL（无需手动刷新）；封面变化时 invalidate `fushiBooksProvider`，让书架重算 MediaItem。手动刷新改用 `OnlineMangaRefreshOutcome`：章节失败仍更新封面、保留旧章节并显示「刷新未完成」横幅与日志；仅章节成功才标记 `_refreshSucceeded`。
  - `fushi/lib/src/updates/update_probes.dart`：章节列表返回空不再算刷新失败（详情/封面已落库，旧章节保留），照常计入刷新数；章节抓取失败仍按失败上报并跳过自动追更。
  - 测试：`manga_series_page_cover_test.dart` 新增来源缺失本地封面、源页面合并 URL、过期 URL 手动刷新自愈、章节失败封面更新且旧章节保留 + 横幅；`online_manga_library_test.dart` 新增空章节仍落库、章节失败详情落库、过期 URL 被书架封面解析采用；`mihon_installed_source_fallback_test.dart` 新增章节失败错误携带系列；`manga_series_missing_source_test.dart` 新增来源缺失不复用远程封面请求；`clear_database_download_relink_test.dart`、`online_manga_library_entry_v3_test.dart` 随返回值类型调整。Backup 导出/导入格式未改动。
- 测试（在 `fushi/` 下，先 `PUB_HOSTED_URL=https://pub.dev dart run slang` 生成 gitignored 访问器，Flutter `D:\ProgramData\flutter_3.47.6\bin\flutter.bat`）：

  ```
  flutter test test/media/manga/manga_series_page_cover_test.dart \
    test/media/sources/reader_fushi_imported_cover_fallback_test.dart \
    test/media/manga/online_manga_library_test.dart \
    test/media/manga/manga_series_missing_source_test.dart \
    test/media/manga/clear_database_download_relink_test.dart \
    test/media/manga/library/mihon_installed_source_fallback_test.dart \
    test/media/manga/online_manga_library_entry_v3_test.dart \
    test/updates/online_manga_update_probe_test.dart
  ```

  结果：`All tests passed!`（101 个测试通过）。
