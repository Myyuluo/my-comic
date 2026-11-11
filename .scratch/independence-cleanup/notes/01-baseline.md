# Ticket 01 基线：审计、扫描器与 Windows 构建

- Date: 2026-11-12
- Worktree: `e:/tmp/mycomic-wt/ticket-01`
- Branch: `ticket/01-audit-and-scanners`
- Base: `8620a070` (`integration/independence-cleanup`)
- Toolchain: Flutter 3.47.6 / Dart 3.13.5（`D:/ProgramData/flutter_3.47.6`），Windows 10 Pro 19045

## 环境与 bootstrap

- `pwsh` 不在 PATH，按 ticket 的 fallback 用 `powershell -NoProfile -ExecutionPolicy Bypass -File tool/setup_worktree.ps1` 完成 bootstrap（pub get + pub-cache patches）。
- 本机环境变量 `FUSHI_FLUTTER` 指向 SDK 目录 `D:\ProgramData\flutter_3.47.6`，而 `tool/bootstrap.ps1` 只检查路径存在、随后把目录当可执行文件调用，首次 bootstrap 报
  `& : 无法将"D:\ProgramData\flutter_3.47.6"项识别为 cmdlet、函数、脚本文件或可运行程序的名称`。
  未改脚本；只在单次命令环境里覆盖为 `FUSHI_FLUTTER='D:\ProgramData\flutter_3.47.6\bin\flutter.bat'` 后重跑成功。
- `fushi/lib/i18n/strings.g.dart` 被 gitignore，bootstrap 与 CI 都不生成（spec Further Notes 已记录）。analyze/test/build 之前必须手动执行：
  ```bash
  cd fushi
  "D:/ProgramData/flutter_3.47.6/bin/cache/dart-sdk/bin/dart.exe" run slang
  ```
  本次生成成功，包含 17 个 locale；该文件未入库。

## 扫描器

两个扫描器都是只读开发者工具，位于 `tool/audit/`，只读仓库文件，不进入 app 运行时，也不写产品代码。测试位于 `fushi/test/tools/audit/`。

### Fushi 引用扫描器

```bash
# 仓库根目录
dart tool/audit/fushi_references.dart                  # 完整文本报告到 stdout
dart tool/audit/fushi_references.dart --summary        # 汇总（分类 / 顶层目录 / top 文件）
dart tool/audit/fushi_references.dart --report <file>  # 写入文件
dart tool/audit/fushi_references.dart --json           # JSON（文件级 + 行级）
dart tool/audit/fushi_references.dart --fail-on-violations  # allowlist 之外有命中时退出 1
```

- 只扫描 `git ls-files` 列出的受版本控制文本文件；二进制按扩展名与 NUL 字节跳过。git 历史不在扫描范围内（历史是允许保留的来源记录）。
- 命中按类别汇总：`user_visible_copy`、`code`、`docs`、`license`、`third_party`、`historical_docs`。代码里的注释计入 `docs`，字符串字面量计入 `user_visible_copy`，import 行计入 `code`。
- allowlist：`tool/audit/fushi_references_allowlist.json`，`path` 支持 `*` / `**` / `?` glob；可再加 `line_pattern` 只放行匹配行。被放行的命中仍出现在报告里（`allowed`），只有 allowlist 之外的命中才算 violation。
- allowlist 覆盖：LICENSE/COPYING、`**/NOTICE*`、`**/PATCHES.md`、`**/UPSTREAM*`、`docs/**`（ADR 与历史文档）、`fushi/docs/**`、`.scratch/**`、`GLOSSARY.md`、README 的 `Fushi v3.0.0` 署名行、About 署名行，以及 `tool/audit/**` 和 `fushi/test/tools/audit/**`（扫描器自身必须包含被扫描词）。
- 基线（含本次新增的扫描器文件，均已被 allowlist 放行）：
  - 扫描 14,832 个受版本控制文本文件
  - 命中 101,310；allowed 9,141；violations 92,169
  - 全部分类（all / violations）：user_visible_copy 17,563 / 17,485；code 62,715 / 62,626；docs 12,888 / 11,593；third_party 562 / 465；historical_docs 7,582 / 0；license 0 / 0
  - violation 顶层目录前几名：`fushi` 64,104；`native` 10,517；`tools` 8,388；`packages` 6,505；`.github` 1,286；`tool` 434；`third_party` 277；`services` 171；`ci` 168；`test` 115
- 报告：`.scratch/independence-cleanup/reports/01-fushi-references-summary.txt`（已入库）。完整行级文本报告约 12 MB，未入库，可用 `--report <tmp>` 重新生成。

### 未使用 l10n key 扫描器

```bash
# 仓库根目录
dart tool/audit/unused_l10n_keys.dart                  # 完整文本报告（前缀表 + 未使用 key 列表）
dart tool/audit/unused_l10n_keys.dart --summary        # 只输出汇总与前缀分布
dart tool/audit/unused_l10n_keys.dart --json           # JSON（每 key 的引用文件）
dart tool/audit/unused_l10n_keys.dart --report <file>
dart tool/audit/unused_l10n_keys.dart --fail-if-unused # 有未使用 key（不含 allowlist）时退出 1
```

- key 集合来自 `fushi/lib/i18n/strings.i18n.json`（嵌套 JSON 会展开为点路径；当前 8,546 个 leaf key）。
- 扫描 `fushi/lib`、`fushi/test`、`fushi/integration_test`（4,359 个 `.dart`），排除生成的 `strings.g.dart`。
- 引用判定：去掉注释后，把成员访问的标识符链当引用候选（`t.key`、`t.a.b`、`Translations.of(context).key`）。字符串字面量里的 `.key` 保守计为引用；注释里的不算。动态拼 key 无法静态识别，用 allowlist。
- allowlist：`tool/audit/unused_l10n_allowlist.json`，规则必须是 `key`（精确）/ `prefix` / `pattern`（正则）三者之一，并给出 `reason`。当前为空：基线没有发现需要放行的动态访问。
- 基线：
  - keys 8,546；referenced 5,510；unused 3,036；allowlisted_unused 0
  - 审计记录约 3,045；本次 3,036（差 9，源于成员访问后缀 + 字符串保守计引用的启发式，而非精确 AST）
  - 主要未使用前缀：video 1,135；game 681；download 184；manga 153；ai 126；collection 119；anime 62；media 54；gal 50；floating 37；subscription 36；jellyfin 30；discovery 27；settings 25；remote 24；book 22；sync 21；onboarding 20；web 16；ocr 14
- 报告：`.scratch/independence-cleanup/reports/01-unused-l10n-keys.txt`（已入库，含全部 3,036 个未使用 key）。JSON（含引用文件）约 2.3 MB，未入库，可用 `--json --report <tmp>` 重新生成。
- 已知启发式边界：`name`、`clear`、`reset` 这类短 key 会把其他对象的同名成员访问误计为引用。清理 ticket 08 应结合 `--json` 的引用文件清单人工核对短 key，不要只看计数。

## Windows 基线

| 命令（cwd `fushi/`） | 结果 | 说明 |
| --- | --- | --- |
| `dart run slang` | 通过 | 生成 17 个 locale 的 `lib/i18n/strings.g.dart`（未入库） |
| `flutter analyze` | **失败（exit 1）** | 308 issues：303 warnings + 5 infos，**0 errors**。全部为既有问题；新增扫描器文件 0 issue |
| `flutter test test/i18n test/language test/tools/audit` | 通过 | 111 tests passed |
| `flutter build windows --debug` | **失败（exit 1）** | 环境缺少 NuGet：插件依赖下载步骤 `NUGET-NOTFOUND`，MSB3073 / 9009 |

### `flutter analyze` 既有问题分布

`override_on_non_overriding_member` 106、`unused_import` 77、`unused_element` 48、`unused_shown_name` 30、`unused_field` 20、`unused_local_variable` 7、`dead_code` 5、`unnecessary_import` 4、`prefer_final_fields` 3、`unused_element_parameter` 2、`unnecessary_null_comparison` 2，以及各 1 条 `unnecessary_non_null_assertion` / `undefined_shown_name` / `prefer_single_quotes` / `prefer_const_declarations`。主要是 manga-only 清理后测试仍引用已删除的成员（例如 `test/sync/*` 的 override、未使用 import）。ticket 01 不修这些。

### `flutter build windows --debug` 失败详情

`flutter_inappwebview_windows` 的依赖下载工程在 MSBuild 阶段调用 NuGet：

```text
error MSB3073: NUGET-NOTFOUND install Microsoft.Windows.ImplementationLibrary -Version 1.0.231216.1 ...
error MSB3073: NUGET-NOTFOUND install Microsoft.Web.WebView2 -Version 1.0.2792.45 ...
error MSB3073: NUGET-NOTFOUND install nlohmann.json -Version 3.11.2 ...
Build process failed.
```

本机 PATH 中没有 `nuget`（命令退出码 9009）。这是环境前置条件，不是本 ticket 或产品代码变更导致；ticket 01 未修改任何产品/运行时代码。后续 ticket 的 Windows build 门禁需要先把 NuGet CLI 放进 PATH（或按仓库构建文档配置）。

## 数据 / 身份基线

- 数据库文件：`my_comic.db` — `packages/fushi_core/lib/src/database/database.dart:441` 的 `kMyComicDatabaseFileName`。
- Content root 默认：`<Documents>\MyComic`，下设 `downloads`、`autobackup`、`local` — `fushi/lib/src/storage/app_paths.dart`（默认目录名与解析逻辑）。
- 更新源：`Myyuluo/my-comic` — `fushi/lib/src/utils/misc/update_check_cache.dart:10` 的 `kUpdateCheckSourceRepository`；仓库 URL 同值见 `fushi/lib/src/utils/misc/official_links.dart:19`。

## 已知失败汇总

1. `flutter analyze` exit 1（308 条既有 warning/info）——见上表。
2. `flutter build windows --debug` 因本机缺 NuGet 失败——见上节；环境问题，未修复。
3. 全量 `flutter test` 未在本 ticket 运行；ticket 01 只要求相关测试基线，全量门禁留给 ticket 12。既有失败（manga-only schema、已删除源文件导致的测试/静态扫描失败）由后续 ticket 处理。
4. `strings.g.dart` 需要在 analyze/test/build 前手动生成；确定性的生成/校验步骤由 ticket 06 负责。
