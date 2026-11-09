# 12: 导出插件商店与图源设置

**What to build:** 创建备份页增加「插件商店」「图源设置」；导出全部 Extension store 与按 Source 组织的配置；跳过空配置组与导入生成的不可用占位源；图源配置复用 11 的敏感过滤规则。

**Blocked by:** 11（导出应用设置与敏感设置过滤）

**Status:** resolved

- [x] 创建备份页增加「插件商店」「图源设置」勾选项，默认勾选。
- [x] 插件商店导出全部 Extension store，包含 index URL、名称、badge、联系站点、签名 key、Discord、legacy 与扩展列表 URL。
- [x] 图源设置按 Source 导出配置，sourceKey 为 `source_<sourceId>`；跳过空配置组与不可用占位源。
- [x] 未勾选敏感设置时排除图源配置中的密码、Token 等敏感键；勾选时包含。
- [x] 关闭对应勾选项时不写入该类数据。
- [x] 备份 seam 测试覆盖商店字段、源配置键、占位源跳过与敏感过滤。

## Answer

Implemented in `c22f5997`, merged into the integration branch as `25e1d021`. 创建备份页「设置」卡新增「插件商店」「图源设置」两项（默认勾选），两者都是独立可导出分区：只勾选任一设置分区时「创建」仍可用，关闭对应勾选项时不写入该类数据。「包含敏感设置」现在在应用设置或图源设置任一项勾选时可用。

插件商店：`_extensionStores` 从 `manga_extension_stores` 读取 `mediaKind: 'manga'` 的全部商店，映射为 Mihon `BackupExtensionStore`（proto field 106），包含 index URL、名称、badge、签名 key、联系站点、Discord、legacy 标志与扩展列表 URL。Mihon 备份格式没有媒体类型字段，因此 Aniyomi（视频）商店不写入，避免导入后被重建为漫画商店；`contactJson` 解析失败按空元数据处理，不中断整个备份。

图源设置：`_sourcePreferences` 按 Source 分组，sourceKey 为 `source_<sourceId>`（proto field 105），组内按 preferenceKey 排序，值映射为 Mihon 六种标准封装。跳过 `kUnavailableMihonExtensionPackage`（导入生成、当前不可用的占位源）下的配置、空 key、无标准封装的配置；无有效配置的来源不写空容器。敏感过滤复用 11 的 `PrefRedactionPolicy`：未勾选「包含敏感设置」时排除 password / token / api_key 等凭据，勾选时包含。

测试：新增 `fushi/test/backup_import/mihon_backup_stores_source_export_test.dart`（商店字段、关闭商店不写、`source_<sourceId>` 分组与标准值类型、空来源与占位源跳过、关闭图源不写、敏感过滤），并扩展 `fushi/test/backup_import/create_backup_page_test.dart` 与 `mihon_backup_export_roundtrip_test.dart`；`flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart` 76 项全部通过。
