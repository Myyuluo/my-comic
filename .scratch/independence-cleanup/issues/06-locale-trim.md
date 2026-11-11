# 06: 界面语言精简为四种

**What to build:** 把界面语言从 17 种精简为 `zh-CN`、`zh-HK`、`en`、`ja`；让系统 `zh-TW`/`zh-Hant` 落到 `zh-HK`；保留跟随系统语言、英文兜底的默认行为；确保 slang 生成在构建/CI 中确定执行。

**Blocked by:** 04

**Status:** resolved

- [x] 删除 13 个翻译文件：`ar, de, es, fr, id, it, ko, nl, pt-BR, ru, th, tr, vi`。
- [x] 更新 `AppModel` 的 locale 列表、语言名表与 `supportedLocales` 来源，只保留 `en-US`、`zh-CN`、`zh-HK`、`ja`。
- [x] 增加显式映射：系统 `zh-TW`/`zh-Hant` → `zh-HK`，避免被语言前缀匹配到 `zh-CN`。
- [x] 保持默认行为：已保存偏好 → 系统 locale → 语言前缀 → 英文兜底；不强制 `zh-CN`。
- [x] 语言选择器剩 4 项后使用现有内联选择器；不改视觉语言。
- [x] 删除写死 17 的测试断言；浏览器扩展相关的语言测试由 ticket 05 随扩展一起删除（本 ticket 未触碰）。
- [x] 删除语言后显式执行 `dart run slang`；在构建脚本/CI 增加生成与校验步骤，避免 `strings.g.dart` 缺失或陈旧。
- [x] 验证：四种语言完整；繁体系统落到 `zh-HK`；语言切换测试通过；i18n 完整性与排序测试通过。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。`strings.g.dart` 当前被 gitignore，生成门禁是本 ticket 的硬要求。

## 实现记录

### 语言集合

- 保留 `en`（base，`en-US`）、`ja`、`zh-CN`、`zh-HK`；删除 `strings_ar/de/es/fr/id/it/ko/nl/pt-BR/ru/th/tr/vi.i18n.json` 共 13 份。
- `AppModel.supportedLocales` 成为唯一列表来源（顺序 en-US → zh-CN → zh-HK → ja，首项即英文兜底）；`populateLocales()` 与 `main.dart` 的 `supportedLocales: appModel.locales.values` 都由它派生。
- `FushiLocalisations.localeNames` 只保留四项，值与 `AppModel.supportedLocales` 的标签一一对应；语言选择器仍用现有 `AdaptiveSettingsPickerRow`，4 项低于 `kSettingsPickerInlineLimit`（8），自动走内联选择器，无视觉改动。

### zh-TW / zh-Hant 映射

- 新增纯函数 `AppModel.matchSupportedLocale` 与 `AppModel.resolveAppLocale`，`appLocale` getter 只保留 `_getPref` + `PlatformDispatcher.instance.locale` 的输入。
- 解析顺序：已保存偏好（精确命中）→ 系统 locale（先精确标签；`zh-TW`/`zh-Hant`/`zh-Hant-TW` 显式映射 `zh-HK`，`zh-Hans` → `zh-CN`；其余按语言前缀）→ `en-US` 兜底。
- 已删除语言的旧偏好（如 `ko`）被忽略，继续跟随系统；系统不支持时回退英文，不会强制 `zh-CN`。

### 测试

- 新增 `fushi/test/models/app_locale_resolution_test.dart`（14 条）：四种语言集合、语言名表、`zh-TW`/`zh-Hant`/`zh-Hant-TW` → `zh-HK`、`zh-Hans` → `zh-CN`、地区/语言前缀、已删除语言不再命中、偏好/系统/前缀/英文兜底顺序，以及生成代码 `AppLocale.values` 只有四种（陈旧的 `strings.g.dart` 会红）。
- 更新写死 17 的守卫：`i18n_keys_sorted_guard_test` 文件数 4；`no_experimental_labels_guard_test` 扫描 4 份；`i18n_completeness_test` 扫描规模 `atLeast: 2 / measured: 3`；`stat_compact_count_unit_guard_test` 的 locale 文件清单改为 en/ja/zh-CN/zh-HK。
- 顺带清理注释里过时的「17 种语言」：`settings_actions.dart`、`fushi_dropdown.dart`、`content_language_picker.dart`、`app_model.dart` 通知文案注释。

### slang 生成门禁

- `dart run slang` 生成 4 locale；连续两次生成 SHA-256 一致（`timestamp: false`，确定性）。
- `script/build_and_run.ps1` 改为**每次构建**无条件 `dart run slang` 并校验产物存在。旧的 mtime 检查发现不了「删除输入文件」造成的陈旧（删除不会更新剩余文件的 mtime），语言精简正是这种场景。
- CI 生成步骤：`main.yml` 已有（ticket 02）；本 ticket 补齐 `golden-tests.yml`、`release-desktop.yml`、`build-multiplatform.yml`（Windows debug）的 `dart run slang`，三处都在 pub get + patches 之后、测试/构建之前。

### 验证

- `cd fushi && dart run slang`：通过（4 locales）。
- `flutter analyze`：0 errors；218 条既有 warning/info（ticket 04 后约 200 条基线，本次修改/新增文件无 issue）。
- 相关测试：`flutter test --no-pub test/i18n test/language test/models/app_locale_resolution_test.dart test/settings/locale_switch_no_restart_test.dart test/settings/settings_downloads_open_page_subtitle_guard_test.dart test/models/app_ui_font_chain_test.dart` → 97 通过。
- `flutter build windows --debug --no-pub`：通过（248.7s，产物 `build/windows/x64/runner/Debug/fushi.exe`）。NuGet 从 worktree `.dart_tool/nuget` 注入（PATH 用 POSIX 形式 `/e/...` 才会被 MSYS 转换给 CMake）；pdfium/sqlite3 native asset 命中缓存。

### 延迟项

- 未使用 l10n key 的删除由 ticket 08 负责；本 ticket 不删 key。
- 浏览器扩展页面/测试/语言字典由 ticket 05 删除；本 ticket 未触碰。
- `reader_statistics_sheet.dart` 的「17 种语言」注释属阅读统计，由 ticket 05 随统计功能删除。
- `stat_compact_count_unit_guard_test.dart` 的 locale 文件清单位于 i18n 守卫内、但覆盖阅读统计格式化；若 ticket 05 删除统计功能并删除该测试，以删除为准。
