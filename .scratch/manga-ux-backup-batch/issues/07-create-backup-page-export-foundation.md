# 07: 创建备份页与导出基础（书架作品、章节）

**What to build:** 新建「创建备份」独立页，按参考布局提供「书架」「设置」两组卡片与底部创建按钮；先交付「书架中的作品」「章节」两个勾选项；保存对话框、默认文件名、进度与结果提示；实现 gzip + protobuf 写入器与标准偏好值类型；「创建备份」设置行更名并启用，生成 Mihon 可导入的 `.tachibk`。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 设置中的「创建备份」行标题与副标题更新为「创建备份」「将书架数据导出为.tachibk文件。」，点击进入独立创建备份页。
- [x] 创建备份页按参考图分「书架」「设置」两组卡片，底部有「创建」按钮；首批提供「书架中的作品」「章节」勾选项，默认勾选。
- [x] 取消「书架中的作品」时「章节」置灰；没有可导出项时「创建」置灰。
- [x] 点「创建」弹出保存对话框，默认目录为 Backup directory，默认文件名 `my-comic_YYYY-MM-DD_HH-mm.tachibk`；取消保存不写文件。
- [x] 导出文件为 gzip + protobuf，字段号对齐 Mihon v0.21.3；书架作品包含 Source ID、作品 URL、标题、作者、封面、加入时间与 favorite=true；章节包含 URL、名称、read、lastPageRead、日期与章节号。
- [x] 偏好值只使用六种标准类型与标准类型名，不使用自定义类型。
- [x] 写入临时文件，成功后移动到目标路径；失败时删除临时文件并提示；目录中不残留半成品。
- [x] 创建过程显示进度，成功后提示文件路径。
- [x] 导出的文件可被现有导入器解析并恢复 Library 与章节；用 Mihon v0.21.3 手动导入可正常恢复书架。
- [x] 备份 fixture/parser/import-service seam 测试覆盖字段、gzip、文件命名、取消保存与失败清理。

## Answer

Implemented in `61dc7313`, merged as `8a16f519`. 新增独立创建备份页 `fushi/lib/src/pages/implementations/create_backup_page.dart`：按参考布局分「书架」「设置」两组卡片、底部通栏「创建」按钮；首批提供「书架中的作品」「章节」两项且每次打开默认勾选，取消「书架中的作品」时「章节」置灰，无可导出项时「创建」置灰。设置「存储与下载 → 备份」中「导出 Mihon 备份」更名为「创建备份」并启用，点击进入该页（CLI 提示同步更新），文案已同步到全部 17 个 locale。

导出基础：`mihon_backup_writer.dart` 手写 gzip + protobuf 编码器，字段号与 `MihonBackupParser` 逐字段对齐 Mihon v0.21.3（proto3 省略零值；`BackupManga.favorite` 按 Kotlin 默认 true 只写 false；偏好值仅接受六种标准类型及其标准序列名，非法类型直接抛错；解析器补齐 `BackupChapter.sourceOrder` 字段 10）。`mihon_backup_exporter.dart` 从 Library 读取 Mihon 运行时作品，导出 Source ID、作品 URL、标题、作者/画师、描述、题材、状态、封面、加入时间与 favorite=true；章节导出 URL、名称、scanlator、read、bookmark、lastPageRead、dateFetch、dateUpload、章节号与 sourceOrder，并每 25 条/结束时回调进度。

保存与进度：点「创建」弹出保存对话框，默认目录为 Backup directory（`<Content root>/autobackup`），默认文件名 `my-comic_YYYY-MM-DD_HH-mm.tachibk`，取消保存不写文件；导出时显示进度对话框（processed / total），先写同目录 `.part` 临时文件、成功后移动到目标路径，失败删除临时文件并提示错误，成功提示保存路径，目录中不残留半成品。

测试：`fushi/test/backup_import/create_backup_page_test.dart`、`mihon_backup_export_test.dart`、`mihon_backup_export_roundtrip_test.dart` 与更新的 `backup_directory_test.dart`、`fushi/test/settings/backup_directory_settings_test.dart`；运行 `flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart`，38 项全部通过。
