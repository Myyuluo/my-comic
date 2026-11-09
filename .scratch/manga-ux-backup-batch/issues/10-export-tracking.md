# 10: 导出进度记录（Tracking）

**What to build:** 创建备份页增加「进度记录」勾选项；导出每部 Manga 的 Bangumi 追踪记录；该选项依赖「书架中的作品」。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** resolved

- [x] 创建备份页增加「进度记录」勾选项，默认勾选；取消「书架中的作品」时置灰。
- [x] 勾选时，每部有 Bangumi 追踪数据的 Manga 导出追踪记录，包含同步 ID、远端作品 ID、最后阅读章节、状态、评分与相关时间。
- [x] 没有追踪数据的 Manga 不写空记录；其他 tracker 当前不导出。
- [x] 关闭「进度记录」时不写入追踪记录。
- [x] 备份 seam 测试覆盖有追踪、无追踪与勾选依赖。

## Answer

Implemented in `c13aaba4`, merged into the integration branch as `1e84370c`.

UI：创建备份页的书架分组新增「进度记录」勾选项（`create_backup_include_tracking`，默认勾选）。该选项依赖「书架中的作品」：取消书架时置灰不可用；导出选项解析为 `MihonBackupExportOptions.includeTracking = includeLibrary && includeTracking`。

导出：`fushi/lib/src/backup_export/mihon_backup_exporter.dart` 在 `includeLibrary && includeTracking` 时读取 `mediaTrackingMappings` 中 `provider = bangumi`、`mediaType = book` 的映射及其 `mediaTrackingOutbox` 同步进度，按 bookKey 关联每部 Library Manga，写入 Mihon `BackupTracking`：`syncId` 为 Bangumi tracker id（5）、`mediaId` 为远端 subject ID、`title` 取 subjectName（为空回退 mediaTitle）、`lastChapterRead` 取 outbox progress，`startedReadingDate` 取 mapping.createdAt，完成时的 `finishedReadingDate` 取 mapping.updatedAt。

状态推导：Bangumi 收藏类型 —— `outbox.completed` 为 true → 2（completed）；未完成但 `progress > 0` → 3（reading）；已关联未阅读 → 1（wish）。

限制：评分与总章节数本地没有数据来源，按 proto 默认值 0 导出而不臆造；`trackingUrl` 为空，`libraryId` / `mediaIdInt` 为 null，`private` 为 false；当前仅导出 Bangumi，其他 tracker（如 anilist）不导出；没有 Bangumi 映射的 Manga 不写空记录；关闭「进度记录」时不写入任何 tracking 记录。

测试：`fushi/test/backup_import/create_backup_page_test.dart`（默认勾选与书架依赖）与 `fushi/test/backup_import/mihon_backup_export_roundtrip_test.dart`（有追踪、无追踪、reading、wish、unsupported provider、includeTracking=false、export→import 往返）；`flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart` 54 项全部通过。
