# 17: .tachibk 导出兼容与未下载提示

**What to build:** 修复两个用户可见问题：MyComic 导出的 `.tachibk` 在 Mihon 中报“备份文件已损坏”；未下载的漫画点“打开文件位置”时提示“无法打开文件位置。”而不是“该漫画没有下载”。

**Blocked by:** None（post-release fixes）

**Status:** resolved

## 1. `.tachibk` 在 Mihon 导入报损坏

### Root cause

Mihon v0.21.3 使用 kotlinx.serialization 的 protobuf 解码。**没有 Kotlin 默认值的字段是必填的**，即使值是 proto3 默认值（0 / 空串 / false）也必须出现在 wire 数据里。MyComic 的 writer 之前按“proto3 默认值可省略”处理，漏写了这些必填字段，例如：

- `BackupManga.source` / `url`
- `BackupChapter.url` / `name`
- `BackupHistory.url` / `lastRead`
- `BackupTracking.syncId` / `libraryId`
- `BackupCategory.name`
- `BackupSource.sourceId`
- `BackupPreference.key`
- `PreferenceValue.value`
- `BackupSourcePreferences.sourceKey`
- `BackupExtensionStore.indexUrl` / `name` / `contactWebsite` / `signingKey`

MyComic 自己的 parser 宽容地补默认值，所以导出→再导入的往返测试一直通过；Mihon 的严格 parser 会抛 `MissingFieldException`，表现为“备份文件已损坏”。用户导出时勾选了“应用设置”等分组，其中的 false / 0 值触发了该问题。

### Fix

- `MihonBackupWriter` 对所有没有 Kotlin 默认值的字段始终写出，即使值等于 proto3 默认值。
- `PreferenceValue` 的 string / boolean / integer / long / float payload 始终写 field 1；StringSet 仍按 repeated 字段写。
- `BackupTracking.libraryId` 为 null 时写 0（Kotlin 必填）。
- 新增结构测试：直接解析 writer 产出的 protobuf，断言所有这些必填字段存在。

## 2. 未下载漫画打开文件位置

### Fix

- 新增四语言 key `media_file_location_not_downloaded`：英语 “This manga is not downloaded.”、简中 “该漫画没有下载。”、繁中 “該漫畫沒有下載。”、日语 “この漫画はダウンロードされていません。”
- 书架/历史漫画卡菜单的“打开文件位置”先检查该在线漫画是否有任何已下载章节；没有则显示新提示（info toast），不再落到通用失败提示。
- 真正的 I/O 失败（目录被外部删除、文件管理器起不来）仍显示 `media_file_location_failed`。

## Verification

- `flutter test --no-pub test/backup_import/mihon_backup_export_test.dart`：5/5 通过（含 required-field 结构测试）。
- `flutter test --no-pub test/backup_import/mihon_backup_export_roundtrip_test.dart`：33/33 通过。
- `flutter test --no-pub test/i18n`：27/27 通过。
- `flutter analyze --no-pub`：0 errors。
- 重新构建 Release 并启动，供用户用新导出的 `.tachibk` 在 Mihon 验证。
