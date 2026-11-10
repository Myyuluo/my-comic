# 06: 设置页合并备份索引并重排下载分组

**What to build:** 在「设置 → 存储与下载」中，把备份与下载索引合并为一个「备份索引」分组；组内顺序为导入备份、创建备份、重建下载索引、检索已下载；把「下载」分组移到「备份索引」下方，数据存储位置保持最上方。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 「存储与下载」section 顺序为：数据存储位置 → 备份索引 → 下载。
- [x] 合并后的 section 保留稳定 id `system.section.backup`，标题为「备份索引」；旧 `storage.rebuild.section` 不再渲染。
- [x] 组内 item 顺序固定为 `system.import_mihon_backup`、`system.export_mihon_backup`、`storage.rebuild_index`、`storage.scan_downloaded`；item id 全部保持不变。
- [x] 备份功能在移动端仍然可见；重建/检索的桌面可见性下移到两个 item 自身，不把整个合并 section 变成桌面专属。
- [x] CLI/桌面控制的 item key、确认框、进度框、报告行为保持不变；CLI breadcrumb 可变为 Backup index。
- [x] 新增/重命名「备份索引」section 标题 key，补齐全部 locale；移除不再使用的 `rebuild_download_index_section` 或明确标记；重新生成访问器。
- [x] 更新顺序 guard：下载视图 section 顺序、合并 section item 顺序、备份设置、CBZ 设置、重建/检索设置测试。
- [x] 不改变设置页视觉组件与交互风格，遵守 ADR 0008。

## Answer

- Worktree 分支：`worktree-agent-a9fec699675bf817b`；基线 `9e2317ad`（ticket 05 已合入 integration）。
- Commit：`ec418489` `feat(settings): merge backup and download index into Backup & index`；分支内含 `8649c06a` merge integration 的同步提交。
- 合并：`git merge --no-ff worktree-agent-a9fec699675bf817b` → merge commit `89364437` `Merge ticket 06: merge backup and download index settings`；无冲突，未产生冲突文件。
- 本文件随后以 `docs(scratch): resolve ticket 06` 提交（其 SHA 见 `git log`）。

### 改动

- `fushi/lib/src/settings/settings_schema_downloads.dart`：
  - 下载视图 section 顺序改为 `buildContentRootsSection()` → `buildBackupIndexSection()` → `buildDownloadBehaviorSection()`。
  - 原 `buildMihonBackupSection()` 重命名为 `buildBackupIndexSection()`，保留稳定 section id `system.section.backup`，标题改用新 key `t.backup_index_section`；组内 item 依次为导入备份、创建备份，再展开 `buildDownloadIndexItems()`（重建下载索引、检索已下载）。
  - 备份行不再有 section 级桌面门控，移动端仍可见。
  - CLI 不可用说明中的 breadcrumb 更新为 `Backup index`。
- `fushi/lib/src/settings/settings_schema_rebuild_index.dart`：
  - 删除 `buildRebuildDownloadIndexSection()`（旧 section id `storage.rebuild.section` 不再渲染），改为 `List<SettingsItem> buildDownloadIndexItems()`。
  - `storage.rebuild_index` / `storage.scan_downloaded` 的 item id、title/subtitle、图标、确认框、进度、报告与 `onTap` 行为保持不变；桌面可见性下移到各 item 的 `visible: (ctx) => isDesktopPlatform`。
  - CLI breadcrumb 更新为 `Settings → Storage & downloads → Backup index → …`。
- i18n（17 个 locale）：新增 `backup_index_section`（英文 `Backup & index`，中文「备份索引」及各语言译文），删除 `rebuild_download_index_section`；`dart run slang` 重新生成 `strings.g.dart`（gitignored）。
- 测试更新：
  - `settings_downloads_open_page_subtitle_guard_test.dart`：guard 下载视图 section 顺序、合并 section id/title/平台可见性、item 顺序、旧 section key 不再出现。
  - `settings_rebuild_download_index_test.dart`、`settings_scan_downloaded_test.dart`：改为通过合并后的「备份索引」分组定位动作行，并断言桌面可见性挂在 item 上。
  - `download_cbz_setting_test.dart`、`backup_directory_settings_test.dart`：适配新的 section 顺序与「备份索引」标题。

### 验证

- 在 `fushi/` 下先 `PUB_HOSTED_URL=https://pub.dev D:/ProgramData/flutter_3.47.6/bin/dart.bat run slang`，再运行（`PUB_HOSTED_URL=https://pub.dev D:/ProgramData/flutter_3.47.6/bin/flutter.bat test ...`）：

  ```
  test/settings/settings_downloads_open_page_subtitle_guard_test.dart
  test/settings/settings_rebuild_download_index_test.dart
  test/settings/settings_scan_downloaded_test.dart
  test/settings/download_cbz_setting_test.dart
  test/settings/backup_directory_settings_test.dart
  test/i18n
  ```

  结果：`All tests passed!`（78 tests）。
- `test/settings/settings_schema_coverage_test.dart` 与 `settings_cli_action_coverage_test.dart`：本次运行同样 `All tests passed!`（4 tests，无基线失败）。
- 视觉/交互未改动，复用现有设置组件与对话框壳，遵守 ADR 0008。

### 遗留

- `backup_import_mihon_section`（英文 `Backup`）在全部 locale 中已无代码引用，但 key 仍保留；按计划留给 ticket 07 清理，本 ticket 不做删除。
