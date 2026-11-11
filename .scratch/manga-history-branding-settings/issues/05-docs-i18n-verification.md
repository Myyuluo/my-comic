# 05: Docs、i18n 与全量验证

**What to build:** 收口本批领域文档、i18n 与验证：记录 fork 身份/版本/更新源决策，确认全部 locale 完整，跑通本批相关测试且不新增历史失败。

**Blocked by:** 01（历史页使用书架封面缓存）、02（品牌图标与设置 GitHub 行指向 fork）、03（系统与关于清理、版本 1.0.0 与更新源）、04（清除缓存只计量可清理内容）

**Status:** resolved

- [x] 更新/补充 ADR：fork 身份、版本 1.0.0、GitHub 仓库与更新检查指向 `Myyuluo/my-comic`、无 release 时的「已是最新」语义（可修订 ADR 0004 或新增 ADR）。
- [x] GLOSSARY 如涉及品牌/更新源/缓存计量术语，按需更新；避免 implementation details。
- [x] 全部 locale 的新增/修改/删除文案同步完整；i18n completeness/sorted/mojibake 通过；不再使用的 key 已清理。
- [x] 本批相关测试全绿：History 封面、品牌图标、设置系统与关于、版本显示、更新检查无 release、清除缓存计量。
- [x] 不新增历史全量失败；已知 manga-only schema / `cover_write_sink_bug_2496` 等保持原记录。
- [x] 未新增数据库 schema、未改 Backup、未移动用户文件。
- [x] ticket 05 更新为 `Status: resolved`，追加 `## Answer`（commit、测试结果、剩余遗留）。

## Answer

Resolved on `worktree-agent-ticket05`（基线 `fda0b361`；文档 commit `29ea3722`；ticket 更新 commit 为 `docs(scratch): resolve ticket 05`）。

**ADR / GLOSSARY**

- `docs/adr/0004-gpl-3.0-independent-brand.md` 追加 `Amendment 2026-11-11（manga-history-branding-settings）`：记录用户明确要求的产品身份变更——应用从 `1.0.0`（构建元数据 `1.0.0+1355`）起发行，设置页显示精确 `1.0.0`；GitHub 仓库与品牌/设置入口指向 `https://github.com/Myyuluo/my-comic`；更新检查只查该 fork 的 Releases，404 / 空列表 / 无匹配通道按「已是最新」处理，不回退上游 3.x；上游快照、GPL-3.0 与「基于 Fushi v3.0.0」署名不变。
- `docs/adr/0003-freeze-upstream.md` 追加同日 amendment：原文「不实现应用更新检查、自动更新或 Fushi 上游合并」修订为保留只面向本 fork 的更新检查与「更新提醒」入口，仍不合并或跟随上游。
- `GLOSSARY.md`：更新 `my-comic`（1.0.0 发布线、自有仓库与更新源）与 `Fushi`（不作为更新源）；新增 `Update source（更新源）`；`History` 补充与书架一致的封面优先级；`Clear cache` 明确占用只计实际可清理内容并报告真实释放量。未写入代码级实现细节。
- 一致性复核：ADR 0016（标签页签）不被 tickets 01–04 改动，无需 amendment；ADR 0023 的封面优先级（本地 → 可用 Source 当前封面含持久缓存 → 生成封面 → 占位）与 History 实现一致（ticket 01 将可用远程排在生成封面之前），无需 amendment。

**i18n**

- `dart tool/i18n_sync.dart --dry-run` → `All translation files are in sync.`；`--sort --dry-run` → `All i18n files are already sorted.`；实际执行 `--sort` 未产生文件改动。
- `dart run slang` 成功生成 17 个 locale（`Translations generated successfully`）。
- 17 个 `strings*.i18n.json` 的扁平 key 均为 8546 个，missing / extra 均为 0；排序 guard 通过。
- `options_website`、`options_github_sponsors`、`startup_module`、`startup_module_hint`、`startup_module_default` 在全部 locale 与 Dart 代码中均无引用；仅保留非 i18n 的启动偏好键 `startup_module`（由 guard 测试锁定）。
- `flutter test test/i18n`：59 个用例全部通过（completeness / sorted / mojibake 等）。

**验证**

- History 封面：`manga_history_cover_test`、`manga_history_page_test`、`manga_history_write_test` 与品牌/版本测试合计 56 个用例全部通过。
- 品牌 / 设置 / 版本：`nav_rail_brand_button_test`、`official_website_entry_test`、`app_version_display_format_test` 通过；`settings_schema_coverage_test`（rows=36、destFindings=0）与 `startup_default_dictionary_tab_settings_test` 通过。
- 更新检查：`update_checker_manual_callbacks_test`（空 release → `onUpToDate`）、`update_checker_release_selection_test`、`update_checker_404_reresolve_test`、`update_checker_all_releases_parse_test`、`update_checker_asset_version_test`、`update_checker_manifest_test`、`update_checker_redirect_tag_test`、`update_checker_structure_guard_test`、`manual_update_check_guard_test` 共 90 个用例全部通过。
- 清除缓存计量：`manga_webview_cache_clear_test`、`manga_cache_clear_service_test`、`manga_cache_clear_settings_test` 共 20 个用例全部通过。
- `dart analyze` 本批 8 个改动 Dart 文件：仅 8 条既有 `unused_element` 警告（对应符号在基线 `ad4fd020` 同样只出现一次），无新增 issue。

**既有失败（未新增）**

- `settings_renderer_test.dart`：`lookup settings can edit the Yomitan API key`、`lookup settings exposes lookup audio volume slider` 因 manga-only schema 不含 `SettingsDestinationId.lookup` 失败（与 ticket 03 记录一致）。
- `m3e_design_system_static_test.dart`：12 个静态扫描因已删除的非漫画源文件抛 `PathNotFoundException`（与 ticket 03 记录一致，本次仍为 +54 -12）。
- 按指示未运行全量历史测试套件；未观察到新的失败。

**边界**

- `git diff --name-status --find-renames ad4fd020..fda0b361` 无 rename/copy；本批未新增数据库 schema、未改 Backup、未移动用户文件（仅 `pubspec.yaml` 版本与既有实现/测试文件变更）。
- 未修改 spec 或其他 ticket；未 push。

**Merge 收口（2026-11-11）**

- 以 `git merge --no-ff worktree-agent-ticket05` 合入 `integration/manga-history-branding-settings`，无冲突（merge base 即原 integration HEAD `fda0b361`）。Merge commit：`e3aba65005aeec4dbbad2dd1994b8efe167228fe`（父提交 `fda0b361` + `79971f89`）。合并只涉及 4 个文档文件（本 ticket、`GLOSSARY.md`、ADR 0003/0004 amendment），无代码或 i18n 资源变更。
- 合并后复验（`fushi/`，Flutter 3.47.6，`PUB_HOSTED_URL=https://pub.dev`，先 `dart run slang` 成功生成 17 个 locale）：`flutter test test/i18n` 59 passed；`manga_history_cover_test` + `nav_rail_brand_button_test` + `official_website_entry_test` + `app_version_display_format_test` + `settings_schema_coverage_test` 33 passed（rows=36、destFindings=0）；update checker 相关 11 个测试文件 107 passed、1 failed；`manga_webview_cache_clear_test` 10 passed。
- 唯一失败为既有失败，与本次合并无关：`update_check_cache_wiring_guard_test.dart` 的 `home_page auto-check passes a cacheWriter (background refresh)`。证据：合并未改任何 Dart 文件，`fushi/lib/src/pages/implementations/home_page.dart` 在 `fda0b361` 与合并后完全相同，且都不含该 guard 期望的 `cacheWriter: appModel.setUpdateCheckCache,`（ticket 05 原文未包含此 guard 测试）。
- 既有失败记录保持不变：`settings_renderer_test`（manga-only schema 无 `lookup` destination）与 `m3e_design_system_static_test`（已删除非漫画源文件导致 `PathNotFoundException`）；本轮未跑全量套件，未观察到新增失败。
- 环境产物已还原：`PUB_HOSTED_URL` 导致根 `pubspec.lock` 镜像 URL 改写、测试生成的 plugin registrant 文件，均已 `git checkout --` 还原，未进入提交。
