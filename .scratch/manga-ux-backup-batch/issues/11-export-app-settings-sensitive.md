# 11: 导出应用设置与敏感设置过滤

**What to build:** 创建备份页增加「应用设置」与「包含敏感设置」；导出 MyComic 自家的应用设置键值，使用 Mihon 标准偏好值类型；排除设备本地键与敏感键，敏感键仅在勾选时写入；「包含敏感设置」在应用设置或图源设置勾选时才可用。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** resolved

- [x] 创建备份页增加「应用设置」与「包含敏感设置」；应用设置默认勾选，敏感设置默认不勾选。
- [x] 「包含敏感设置」仅在「应用设置」或后续「图源设置」勾选时可用。
- [x] 勾选应用设置时，导出 MyComic 应用设置键值，使用标准偏好值封装；不做 Mihon 键名映射。
- [x] 未勾选敏感设置时，密码、Token、API key 等敏感键与设备本地键被排除；勾选时包含敏感键。
- [x] MyComic 专有键使用标准值类型，不会导致 Mihon 导入失败。
- [x] 关闭应用设置时不写入应用设置；敏感设置不单独产生数据。
- [x] 备份 seam 测试覆盖键值、敏感与设备本地过滤、勾选依赖与标准值类型。

## Answer

Implemented in `78fd681f`, merged into the integration branch as `62b7d1fc`. 创建备份页新增「应用设置」（默认勾选）与「包含敏感设置」（默认不勾选）；「包含敏感设置」仅在任一设置分区（应用设置，后续图源设置）勾选时可用，关闭应用设置则不单独产生数据。创建按钮在仅勾选任一设置分区时也可用。

导出：`fushi/lib/src/backup_export/mihon_backup_exporter.dart` 在 `includeAppSettings` 时读取 `database.getAllPrefs()`，按 key 排序后以原始 key 名写入 Mihon `BackupPreferences`（proto field 104），不做 Mihon 键名映射。每行经 `PrefCodec.decodeUntyped` 映射到 Mihon 的六种标准值封装：bool→Boolean、int→Int/Long（按 int32 范围选择）、double→Float、String→String、字符串列表→StringSet；无标准封装可承载的形状（null、JSON object、非字符串列表）直接跳过，避免 Mihon 恢复时因未知类型整体中止。

敏感与设备本地过滤：设备本地键（`SyncRepository.deviceLocalPrefKeys`：路径、设备 id、同步状态等）无论是否勾选敏感设置都不出设备；密码、Token、API key 等凭据键按既有 `PrefRedactionPolicy` 判定，仅在勾选「包含敏感设置」时写入；内部 `prefs_version` 计数器视为安装状态而非设置，始终排除。

同时 `mihon_backup_writer.dart` / `mihon_backup_parser.dart` 支持 field 104 往返，writer 的 protobuf varint 对负值做符号扩展（不再截断为一个字节）。

测试：`fushi/test/backup_import/create_backup_page_test.dart`（默认值、依赖门控、关闭应用设置）与 `fushi/test/backup_import/mihon_backup_app_settings_export_test.dart`（键值、标准值类型、敏感/设备本地过滤、取消敏感），`flutter test test/backup_import/` 42 项全部通过。
