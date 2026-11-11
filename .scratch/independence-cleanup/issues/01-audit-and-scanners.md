# 01: 审计、扫描器与基线

**What to build:** 建立独立化清理的可重复验收基线：Fushi 引用扫描器、未使用 l10n key 扫描器、Windows analyze/test/build 基线，以及已知失败与 allowlist 记录。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 创建 Fushi 引用扫描器：只读扫描受版本控制文件，按类别汇总（用户可见文案、代码标识符/import/路径、注释/文档、许可证/版权、third_party、历史文档）；支持 allowlist；输出文件级/行级报告。
- [x] allowlist 覆盖 `LICENSE`、第三方 NOTICE/PATCHES/UPSTREAM、`UPSTREAM.md`、ADR、历史文档、README/About 的“基于 Fushi v3.0.0”署名，以及 git 历史。
- [x] 创建未使用 l10n key 扫描器：读取 base JSON key 集合，扫描 `lib/`、`test/`、`integration_test/`，排除生成的 `strings.g.dart`；输出 key、是否引用、引用文件、功能前缀；支持动态访问白名单。
- [x] 运行两个扫描器并保存基线报告；记录当前未引用 key 数量（审计时约 3,045）及主要前缀分布。
- [x] 运行并记录 Windows 基线：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug`；记录已知失败（manga-only schema、已删除源文件导致的静态扫描失败等）。
- [x] 记录当前数据/身份基线：`my_comic.db`、Content root 默认 `<Documents>\MyComic`、更新源 `Myyuluo/my-comic`。
- [x] 不修改产品代码；扫描器放在开发者工具位置，不进入 app 运行时。
- [x] 在 ticket 或 spec 中写清扫描器复跑方式、allowlist 语义与报告位置。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。扫描器只读；是否把报告入库由实现者按项目惯例决定。

## 实现记录（2026-11-12）

详细基线（命令、数字、失败原文、环境坑）见 [notes/01-baseline.md](../notes/01-baseline.md)。

### 复跑方式（仓库根目录）

```bash
dart tool/audit/fushi_references.dart [--summary] [--json] [--report <file>] [--fail-on-violations]
dart tool/audit/unused_l10n_keys.dart  [--summary] [--json] [--report <file>] [--fail-if-unused]
```

- 两者都只读：不写产品代码、不改 git index。
- `--fail-on-violations` / `--fail-if-unused` 是留给清理完成后（ticket 08 / 12）转门禁的开关。

### allowlist 语义

- Fushi 引用：`tool/audit/fushi_references_allowlist.json`。`path` 是相对仓库根的 glob（`*` 不跨目录，`**` 跨目录，`?` 单字符）；可加 `line_pattern` 只放行匹配行。被放行命中仍出现在报告的 `allowed` 里，只有未放行命中算 violation。git 历史不扫描。
- 未使用 l10n key：`tool/audit/unused_l10n_allowlist.json`。每条规则用 `key`（精确）/ `prefix` / `pattern`（正则）之一 + `reason` 描述动态访问。当前为空（基线未发现需要放行的动态访问）。
- 扫描器自身（`tool/audit/**`、`fushi/test/tools/audit/**`）在 Fushi allowlist 中：工具源码必须包含被扫描的词。

### 报告位置

- `reports/01-fushi-references-summary.txt`（入库；完整行级报告约 12 MB，可重新生成，不入库）。
- `reports/01-unused-l10n-keys.txt`（入库，含前缀表与全部 3,036 个未使用 key；JSON 含引用文件，约 2.3 MB，可重新生成，不入库）。

### 基线摘要

- Fushi 引用：14,832 个受版本控制文本文件；101,310 命中；9,141 被 allowlist 放行；92,169 violations（`fushi` 64,104、`native` 10,517、`tools` 8,388、`packages` 6,505、`.github` 1,286）。
- 未使用 l10n key：8,546 keys；5,510 referenced；3,036 unused（审计约 3,045）；主要前缀 video 1,135、game 681、download 184、manga 153、ai 126。
- `flutter analyze`：exit 1，303 warnings + 5 infos，0 errors（均既有）。
- `flutter test test/i18n test/language test/tools/audit`：111 passed。
- `flutter build windows --debug`：环境失败——本机 PATH 无 `nuget`，`flutter_inappwebview_windows` 依赖下载报 `NUGET-NOTFOUND` / MSB3073 / 9009；未修复环境，已记录。
- 身份基线：`my_comic.db`、`<Documents>\MyComic`、更新源 `Myyuluo/my-comic`（文件位置见 baseline note）。
- `fushi/lib/i18n/strings.g.dart` 需在 analyze/test/build 前用 `cd fushi && dart run slang` 生成（当前 CI/bootstrap 不生成；ticket 06 负责补确定性生成）。
