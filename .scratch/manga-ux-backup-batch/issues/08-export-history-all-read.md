# 08: 导出历史与所有已读作品

**What to build:** 创建备份页增加「历史」「所有已读作品」两个勾选项；导出每部 Library Manga 的最近 History；把未加入 Library 但有阅读 History 的在线作品以 favorite=false 导出；两项受各自勾选项与「书架中的作品」依赖规则控制。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** resolved

- [x] 创建备份页增加「历史」「所有已读作品」两个勾选项，默认勾选；取消「书架中的作品」时两者置灰。
- [x] 勾选「历史」时，每部 Library Manga 导出最近一条 History（章节 URL、lastRead、readDuration）。
- [x] 勾选「所有已读作品」时，未加入 Library 但有阅读 History 的在线作品以 favorite=false 导出，包含 Source ID、作品 URL、标题、作者、封面与可用历史。
- [x] 快照没有章节 URL 时只导出作品元数据，不伪造章节或 History 链接。
- [x] 关闭对应勾选项时不写入该类数据。
- [x] 导出的 favorite=false 条目不会在导入时创建 Library 条目（与 14 联动）。
- [x] 备份 seam 测试覆盖历史、favorite=false、缺章节 URL 与勾选依赖。

## Answer

Implemented in `0f72fa20`, merged into the integration branch as `a9e8a301`.

创建备份页：「历史」「所有已读作品」两个勾选项（`create_backup_include_history` / `create_backup_include_all_read`）默认勾选，位于「进度记录」之后；取消「书架中的作品」时两者置灰。`MihonBackupExportOptions` 新增 `includeHistory` / `includeAllRead`，导出器同样按「书架中的作品」的依赖规则解析这两项，直接调用 API 时不会越过依赖。

历史：勾选「历史」时，每部 Library Manga 导出最近一条 History（章节 URL、`lastRead`、`readDuration`）；章节 URL 优先取导入快照，其次取最近更新的章节状态。未勾选时 `history` 写空列表。

所有已读作品：勾选「所有已读作品」时，未加入 Library 但有阅读 History 的在线作品以 `favorite=false` 导出，包含 Source ID、作品 URL、标题、作者与封面，并附可用的最近 History；`favorite=false` 条目在导入时不会创建 Library 条目（与 14 联动）。Library 作品同时按 History 身份与 (Source, URL) 排除，避免备份导入或图源包变化后重复导出。

限制：快照没有章节 URL 时只导出作品元数据，不伪造章节或 History 链接。

i18n 新增 `backup_create_history` / `backup_create_all_read`，通过 key 级合并驱动覆盖全部 17 个语言文件。

测试：`fushi/test/backup_import/create_backup_page_test.dart` 覆盖两项默认勾选、书架依赖置灰与导出选项传递；`fushi/test/backup_import/mihon_backup_export_roundtrip_test.dart` 覆盖历史导出、favorite=false、缺章节 URL、关闭选项不写入与依赖规则。合并后 `flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart` 共 70 项测试全部通过。
