# 08: 未使用 l10n key 清理

**What to build:** 在非漫画功能删除和 Onboarding 重写完成后，运行未使用 key 扫描器，删除不再被剩余代码引用的 l10n key，并重新生成/校验四种语言。

**Blocked by:** 07

**Status:** resolved

- [x] 运行 01 建立的未使用 l10n key 扫描器；排除生成的 `strings.g.dart` 与动态访问白名单。
- [x] 删除无引用的 base key，并同步删除四个 locale 中的同名 key。
- [x] 保留漫画域、设置页、Onboarding、About/许可证、语言选择器等仍在使用或动态引用的 key。
- [x] 删除已删除功能的文案（小说、视频、词典、Anki/SRS、听书、同步、AI、反馈、排行榜、Tracking、统计、OCR、浏览器扩展、PDF、首页 dashboard 等）。
- [x] 执行 `dart run slang` 重新生成；跑 i18n completeness、sorted、mojibake 与语言切换测试。
- [x] 验证：扫描器报告为零（或只剩 allowlist）；四种语言 key 集合一致；无空值/缺 key。
- [x] 不改变剩余 key 的语义；只删 key，不做无关重命名。

**Notes:** 参考 [spec](../spec.md)。删除顺序必须是“先删代码，再删 key”，避免删掉仍被死代码引用、随后又需要恢复的 key。

## 实现记录（2026-11-12）

### 扫描与删除

- 清理前 `dart tool/audit/unused_l10n_keys.dart --summary`：扫描 1,613 个 Dart 文件；keys 8,557；referenced 1,723；unused 6,834；allowlisted 0。
- 用 `--json` 的引用文件清单人工核对：25 个 key 的“引用”只来自字符串字面量——偏好 ID（如 `'lookup.popup_max_width'`、`'popup_bottom_docked'`、`'auto_read_on_lookup'`）或已删除源文件的源码文本断言；没有真实 `t.<key>` 访问。它们都是已删除功能（词典弹窗 / 听书 / galgame / 旧设置/测试残留）的文案，按未使用一并删除。
- 每份语言文件删除 6,859 个 key：base `strings.i18n.json` 与 `strings_ja` / `strings_zh-CN` / `strings_zh-HK` 均 8,557 → 1,698，四份 key 集合完全一致。
- 删除后扫描器：keys 1,698、referenced 1,698、unused 0、allowlisted 0；`--fail-if-unused` 退出码 0。报告见 [`reports/08-unused-l10n-keys.txt`](../reports/08-unused-l10n-keys.txt)。
- 删除的主要功能前缀：video 1,150、game 689、srs 557、audiobook 447、anki 352、sync 251、ai 224、onboarding 219（旧向导）、leaderboard 208、download 190、feedback 175、manga 162、dict 127、collection 121、media 119、popup 115、stat 107、reader 88、interconnect 86、floating 77、discovery 76、gal 70、backup 64、anime 62、remote 61 等。

### allowlist / 保留决策

- 未新增动态访问 allowlist；`tool/audit/unused_l10n_allowlist.json` 仍为空。所有保留 key 都有静态成员访问引用。
- 保留仍被漫画域、设置、Onboarding、About/版本、语言选择器、Library、Reader、Download、Backup、Local source、Mihon/Extension store 代码或测试引用的 key（onboarding 13、settings 55、about/version 2 等）。
- 31 个 key 名称仍带 video/anime/audiobook/srs/sync/ai/game/stat 等旧前缀，但被剩余漫画代码或测试真实引用（如 `video_extensions_title`、`srs_stats_source_untitled`、`sync_exit_warning`、`ai_settings_title`）。按“只删无引用 key、不改名、不改值”的原则保留；其代码/文案归属留给后续 ticket（10/12）。
- 剩余 key 的 value 与 HEAD 逐 key 对比：四份文件均 0 处变化。未做 rename，删除后仍保持字典序和 `i18n_sync` 写出格式。

### 测试调整（仅为移除已删功能的 l10n 引用）

- 删除 `test/i18n/shader_quality_hint_not_anime_only_test.dart`：视频着色器档位守卫，功能已删除。
- `test/i18n/strings_test.dart`：移除 video clip export 与 video scrape 两组断言（功能已删除）。
- `test/i18n/zh_cn_mojibake_guard_test.dart`：移除指向已删除 key 的 repaired-key / backup-category / clip-export 断言，保留全量 mojibake 扫描。
- 未改动其他测试。`test/tools/gal_workbench_track_manager_guard_test.dart` 等引用已删除源文件的既有失败仍留给 ticket 12。

### 验证

- `cd fushi && dart run slang`：通过（en / ja / zh-CN / zh-HK）。
- 四语言 key 集合一致，无缺 key；唯一空值 `reader_furigana_mode_hint` 是既有刻意空串（`strings_test` 已断言），不在本 ticket 改值范围。
- `flutter test --no-pub test/i18n test/models/app_locale_resolution_test.dart test/settings/locale_switch_no_restart_test.dart`：44 passed（含 completeness、sorted、mojibake、语言切换）。
- `flutter analyze --no-pub`：0 errors；155 warnings/infos（均既有基线）。
- `flutter build windows --debug --no-pub`：通过（236.2s，产物 `build/windows/x64/runner/Debug/fushi.exe`；NuGet 从 worktree `.dart_tool/nuget` 注入 PATH）。
- `dart run slang` 连续两次生成 SHA-256 一致（确定性）。
