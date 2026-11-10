# 06: 设置页存储与下载文案更新

**What to build:** 设置「存储与下载」中的清除数据库文案去掉「孤儿」；「导入 Mihon 备份」更名为「导入备份」并更新副标题与文件选择框标题。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 清除数据库副标题为「删除全部历史、未入书架的作品记录与阅读记录；书架进度、下载与本地图源都会保留。」。
- [x] 清除数据库进度步骤显示「正在清理阅读记录」。
- [x] 备份分组第一行标题为「导入备份」，副标题为「本应用支持导入Mihon的备份文件，请选择您的.tachibk文件。」。
- [x] 导入文件选择框标题为「导入备份」。
- [x] 页面级测试断言上述文案，其他设置项与分组顺序不变。

## Answer

Implemented in `3a365f98`, merged as `8ae281d5`. 清除数据库副标题与阅读记录进度步骤去掉「孤儿」措辞：`database_clear_subtitle` 改为「删除全部历史、未入书架的作品记录与阅读记录；书架进度、下载与本地图源都会保留。」，`database_clear_step_reading_records` 改为「正在清理阅读记录」。备份分组第一行 `backup_import_mihon_title` 由「导入 Mihon 备份」更名为「导入备份」，`backup_import_mihon_subtitle` 改为「本应用支持导入Mihon的备份文件，请选择您的.tachibk文件。」；文件选择框标题复用同一标题字符串。文案同步到全部 17 个 locale（zh-CN 为准，zh-HK 翻译，其余保留英文语义），设置 schema 的 CLI 提示同步更新。页面级测试 `fushi/test/settings/manga_database_clear_settings_test.dart`、`fushi/test/settings/backup_directory_settings_test.dart`、`fushi/test/backup_import/backup_directory_test.dart` 覆盖清除数据库文案、进度步骤、备份行文案/顺序与文件选择框标题。
