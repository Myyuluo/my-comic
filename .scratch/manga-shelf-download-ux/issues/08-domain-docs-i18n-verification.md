# 08: Domain docs、i18n 与全量验证

**What to build:** 把本批的领域术语、架构决策与文案收口：更新 GLOSSARY 与 ADR，清理废弃 i18n key，确认全部 locale 与生成访问器同步，并跑通完整测试套件。

**Blocked by:** 01（继续阅读与「读完」语义修正）、02（重建下载索引只重链书架成员）、03（检索已下载扫描 downloads 并加入书架）、04（更新提醒分组置顶）、05（刷新失败横幅文案）、06（在线封面元数据刷新与 URL 合并）、07（在线封面持久字节缓存）

**Status:** resolved

- [x] GLOSSARY 新增「Scan downloaded（检索已下载）」：用户手动触发的发现扫描，只读当前 Content root 的 `downloads`，把已下载但未加入书架的作品加入 Library；源未安装时原地登记为本地条目；不移动文件；显式执行时可复活 tombstone。
- [x] GLOSSARY 修订「Rebuild download index（重建下载索引）」：只重链 Library 成员，不再补建条目；发现新作品由 Scan downloaded 负责。
- [x] GLOSSARY 修订「Unindexed（未索引）」相关表述：未索引内容不再由 Rebuild 自动登记，仍可被 Scan downloaded 发现。
- [x] 补 ADR：重建与检索的职责拆分，以及「书架归属只能由用户显式动作改变」的原则。
- [x] 补 ADR：在线封面持久化与 Program state 封面缓存；明确封面不属于 Download library、不进入 Backup。
- [x] 所有新增/修改文案在全部支持语言中同步，生成访问器已重新生成；废弃的「显示的是本机已保存的章节」key 已删除或明确标记。
- [x] 本批未引入数据库 schema 变更；如实现中不可避免，补充迁移说明与兼容性验证。
- [ ] 完整测试套件通过，包括本批新增的继续阅读、重建、检索、封面与横幅测试。（本批相关 317/317 通过；全量套件仍有与本批无关的历史遗留失败，见 Answer。）
- [x] 实现遵守 ADR 0008（UI fidelity）与既有下载/封面边界，不新增平行实现。

## Answer

- Worktree 分支：`worktree-agent-a2642d89d260b4def`；基线 `0980acde`（ticket 07 之后）。
- Commits：
  - `553e94c3` `docs(domain): split rebuild vs scan downloaded and document cover cache`
  - `37184114` `i18n: fill missing rebuild/scan/source keys in all locales`
  - `161f1aa8` `test: refresh stale guards after manga-only shell and schema split`
  - `99c3bf33` `fix(manga): route shelf cover cache writes through MediaCoverService`
  - `bb07bb2c` `test(media): drop dead cover-deriver registry entries after manga-only shell`
  - `docs(scratch): resolve ticket 08`（本文件）
- GLOSSARY（`GLOSSARY.md`）：
  - 新增 **Scan downloaded（检索已下载）**：只读当前 Content root 的 `downloads`，只收至少一个完整 Chapter container 的作品；已有非书架记录原地提升并保留阅读状态与 History；tombstone 在显式执行时复活并清除；源未安装时登记为指向该 `downloads` 目录的本地条目；不移动/复制/删除文件，不重链已在 Library 的作品。
  - 修订 **Rebuild download index**：只重链 Library 成员；不新增 Manga、不改变 Library membership、不分配 Tag、不读取或改写非书架 Manga；发现新作品由 Scan downloaded 负责。
  - 修订 **Unindexed**：未索引内容不再由 Rebuild 自动登记，仍可被 Scan downloaded 发现。
  - 修订 **Import**：移除「重建索引仍是手动全量扫描」的旧表述，改为「只重链书架成员，`downloads` 中未入架作品由检索已下载发现」。
- ADR：
  - `docs/adr/0022-rebuild-vs-scan-downloaded-and-explicit-membership.md`：重建/检索职责拆分；Library membership 只能由用户显式动作改变（Rebuild 永不改变；Scan downloaded 只在显式执行时加入/提升/复活）。
  - `docs/adr/0023-online-cover-cache-in-program-state.md`：在线封面按 bookKey 持久化在 Program state（`<programState>/cache/shelf_covers`），经 Extension runtime 取字节（headers/cookies/鉴权）；不属于 Download library、不进入 Backup；清除缓存后回退远程 URL 或占位。
- i18n：
  - 基线缺口为 **15 个 locale × 16 key = 240**（任务说明的 14 个未含 zh-HK；zh-CN 原本完整）。
  - 用 `dart tool/i18n_sync.dart --add` 补齐：zh-HK 用繁体中文，其余 14 个 locale 用英文基线；`dart run slang` 重新生成 gitignored 访问器。
  - `flutter test test/i18n`：27 个测试全部通过（completeness / sorted guard / strings / mojibake 等）。
  - `manga_series_offline_hint` 在 `lib/`、`test/` 与全部 locale 文件中均无引用/定义；本批未发现其他废弃 key。
- 全量测试（`flutter test`，`fushi/`，`--concurrency=8`，2,799 个测试文件分 35 批）：
  - 结果：**+19,370 通过 / ~52 跳过 / -1,916 失败**（554 个测试文件；未走 heavy lease）。
  - 本批相关测试全部通过：继续阅读、重建、检索、封面、横幅、更新提醒排序、i18n 与设置守卫，**317/317**。
  - 剩余失败均为与本批无关的历史遗留，主要两类：
    1. `FushiDatabase.forTesting` 按 manga-only live schema（37 表）建库，而上游测试仍依赖已移除的非漫画表：`no such table: audiobooks / srs_local_state / dictionary_metadata / srt_books / reading_statistics / video_books / galgames / ...`（如 `test/srs/*`、`test/sync/*`、`test/database/*`）。
    2. manga-only shell（`ff3f2df0`）移除的视频 / AI / 阅读器设置与模块，上游测试仍断言其存在（如 AI 视频下载分区、lookup 音量滑杆、桌面更新分区）。
  - 未静默忽略：本 ticket 修掉了 3 个与本批封面改动直接相关的守卫失败（`media_cover_write_guard_test` 的 `evictLocalCoverCache` 违规 + 2 条已删除视频域的陈旧登记）；`media_cover_write_guard_test` 与 `manga_shelf_cover_resolution_test` 现为 12/12 通过。
  - 回归命令（本批 32 个测试文件/目录 + `test/media/media_cover_write_guard_test.dart`）：
    ```
    flutter test --concurrency=8 <上述文件>
    ```
    结果：`All tests passed!`（317 tests）。
- 数据库 schema：未改 `packages/fushi_core`、数据库或迁移文件（`git diff 0980acde..HEAD -- packages/fushi_core` 为空）；本批无 schema 变更。
- 合并：`git merge integration/manga-shelf-download-ux` → `Already up to date`（integration HEAD `0980acde` 已是本分支祖先）。
