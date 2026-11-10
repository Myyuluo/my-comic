# 14: 导入：应用设置与未入书架已读作品

**What to build:** 导入 MyComic 自己的应用设置时只补齐本机缺失的已知键；导入 favorite=false 的已读作品时恢复 History 但不创建 Library 条目；导入汇总报告增加 Tag、应用设置与未入架 History 的计数。

**Blocked by:** 08（导出历史与所有已读作品）、11（导出应用设置与敏感设置过滤）

**Status:** resolved

- [x] 导入包含 MyComic 应用设置的备份时，只导入 MyComic 已知键；本机已有键不被覆盖，缺失键被补齐。
- [x] Mihon 原生键被跳过，不写入 MyComic 应用设置。
- [x] favorite=false 的已读作品不创建 Library 条目；其 History（作品快照、标题、封面、最近阅读时间、可用章节 URL 与阅读时长）被恢复。
- [x] 恢复的 History 出现在历史页，不增加书架作品数。
- [x] 导入汇总报告包含 Tag、应用设置与未入架 History 的计数与跳过原因。
- [x] 重复导入幂等；Merge 语义与其他导入行为保持不变。
- [x] 与 08、11 的导出往返测试通过：MyComic 导出后重新导入，应用设置与未入架 History 一致。

## Answer

Implemented in `fcd41e5c`（后续测试补强 `1ab8e279`），merged into the integration branch as `b1157d47`。

应用设置导入（fill-only）：只接受 MyComic 自己的键——静态注册表 `kKnownPreferenceKeys` 加动态前缀族 `kKnownPreferenceKeyPrefixes`（如 `audiobook_pos_<bookKey>`）。本机已有的键一律保留本地值，缺失的键才写入，并按六种标准 Mihon 封装 1:1 重新编码为 `PrefCodec` 格式。Mihon 原生键与未知键计入 `notMyComicKey`；设备本地键（`SyncRepository.deviceLocalPrefKeys`，如 `ai_providers`、本机路径/基线等）计入 `deviceLocal`，避免新设备冒用导出机的身份；本机已有值计入 `alreadyPresent`。已知键出现未知值类型时在第一次写入前抛 `MihonBackupFormatException`，坏文件不会留下半导入状态。

未入架已读作品：`favorite=false` 的条目永不创建 Library 行（计入 `skippedEntries` / `notInLibrary`），但会取最新一条 `lastRead > 0` 的 History 恢复为 `media_open_history` 行，快照包含标题、作者、封面，`online` 引用（runtime `mihon`、sourceId、seriesKey、封面），以及 `mihon_history` 块（章节 URL、`read_at`、`read_duration`）。作品已在本机书架时复用其本地身份，避免历史出现两条；恢复行经 `loadMangaHistory` 出现在历史页，书架作品数不变。跳过原因分别为 `noHistory`（无阅读时间戳）、`missingUrl`（作品无 URL）、`alreadyNewer`（本地行不旧于备份），重复导入因此幂等。

导入汇总报告新增 `appPreferencesImported` 与 `appPreferencesSkippedByReason`（notMyComicKey / deviceLocal / alreadyPresent）、`nonLibraryHistoryImported` 与 `nonLibraryHistorySkippedByReason`（noHistory / missingUrl / alreadyNewer），并在导入结果弹窗中与既有的 Tag（新建/复用/跳过）计数一并展示。

测试：`fushi/test/backup_import/mihon_backup_import_test.dart` 覆盖六种值类型补齐、本机值优先、Mihon 原生键跳过、设备本地键跳过、未入架 History 恢复与三种跳过原因、重复导入幂等；`mihon_backup_export_roundtrip_test.dart` 覆盖 08/11 导出后重新导入的往返（含本机已有键优先与二次导入幂等）。`flutter test test/backup_import/ test/settings/backup_directory_settings_test.dart` 共 81 项全部通过（`strings.g.dart` 为 gitignored 生成物，已用 `dart run slang` 重新生成后运行）。
