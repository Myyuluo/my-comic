# 11: 文档、README 与仓库元数据

**What to build:** 收口文档与仓库元数据：删除三类上游归档，重写两份 README，更新 UPSTREAM/GLOSSARY/ADR 与 CI/Issue/FUNDING 元数据，保留许可证与来源署名。

**Blocked by:** 10

**Status:** resolved

- [x] 删除 `docs/bugs/`、`docs/readme/`、`docs/agent/` 三类纯上游归档。
- [x] 重写 `README.md`（英文）与 `README.zh-CN.md`（中文）：MyComic 定位、Windows 安装、漫画功能、Mihon 兼容、GPL-3.0、基于 Fushi v3.0.0。
- [x] 删除或重写应用子目录下的旧 README；不再指向 fushi.moe、上游仓库、Discord、TestFlight 或上游下载页。
- [x] 更新 `UPSTREAM.md`：保留上游快照/commit/许可证信息，确认 `docs/agent` 删除后的表述正确，链接 ADR 0024。
- [x] 更新 CI/FUNDING/Issue 模板/Release 标题，移除上游仓库与服务端/R2 工作流；只保留 Windows 发布线。
- [x] 保留 ADR、`GLOSSARY.md`、fork 自己的 specs/plans/reviews；未在删除名单内的历史文档默认保留。
- [x] 确认 LICENSE 与第三方 NOTICE/许可完整；README/About 的“基于 Fushi v3.0.0”署名存在。
- [x] 验证：README 两份可读且一致；活动文档中没有指向 fushi.moe/上游的链接；Fushi 引用扫描器只剩 allowlist。

## 实现记录（2026-11-12）

- Worktree: `e:/tmp/mycomic-wt/ticket-11`
- Branch: `ticket/11-docs-readme-repo-metadata`（基于 `e3c0e568`）
- Toolchain: Dart 3.13.5（`D:/ProgramData/flutter_3.47.6/bin/cache/dart-sdk/bin/dart.exe`；`dart` 不在 PATH）

### 删除的上游归档（3186 个文件）

- `docs/bugs/`：3148 个文件（BUG-* 正文与索引表素材）。
- `docs/readme/`：15 个文件（15 种语言的旧 README 翻译）。
- `docs/agent/`：23 个文件（Fushi-CLAUDE/AGENTS 快照、build/statistics/integration-testing 等操作手册、`fushi-claude-config/`）。

保留：`docs/adr/**`、`docs/agents/**`（fork 自己的 agent skill 文档）、`docs/specs/**`、`docs/plans/**`、`docs/reviews/**`、`docs/BUGS.md`、`docs/user-guide*.md`、`docs/design/**`、`docs/static-assets/**`、`docs/assets/**`、`my_comic/docs/**`（含 `my_comic/CLAUDE.upstream.md`）。

### 重写的文档

- `README.md` / `README.zh-CN.md`：同一结构的中英文版本。包含 MyComic 定位（Windows 桌面漫画阅读器、Mihon 兼容、非官方关联）、漫画功能（书架/标签、作品页与全局搜索、阅读器、在线图源、下载、本地图源、历史、备份、四种界面语言、新手引导）、Windows 10/11 安装（`mycomic-<version>-windows-setup.exe`、按用户安装）、从源码构建（Flutter 3.47.6、`tool/bootstrap.ps1`、`flutter build windows --release`、analyze/test/slang 门）、数据与隐私（Content root、Program state、无遥测/云同步）、项目结构、GPL-3.0 与第三方声明、Fushi v3.0.0 来源署名。不含 fushi.moe、Discord、TestFlight、上游仓库或上游下载页链接；并说明旧 `fushi://` 深链与 `fushi-` 更新资产不兼容、需手动更新/重装一次。
- `my_comic/README.md`：从上游应用说明改为指向根 README、ADR 与 CLAUDE.md 的短说明，不再含 Fushi 品牌或上游链接。
- `UPSTREAM.md`：保留上游仓库/tag `v3.0.0`/commit `51fbb9b…`/快照日期/获取方式/GPL-3.0；写明快照冻结、不跟随也不同步上游；说明 `docs/agent/` 已由独立化清理删除、`my_comic/CLAUDE.upstream.md` 作为历史快照保留；链接 ADR 0003 与 ADR 0024；保留 ANGLE 与 libtorrent provenance 说明。

### allowlist 收紧

`tool/audit/fushi_references_allowlist.json`：

- 删除 `README.md`、`README.zh-CN.md`、`my_comic/README.md` 的整文件临时放行。
- 两份 README 改为 `line_pattern`：英文 `[Ff]ushi v3\.0\.0|Fushi contributors|Fushi-based|fushi://|fushi-`，中文 `[Ff]ushi v3\.0\.0|Fushi 贡献者|fushi://|fushi-`，只覆盖来源署名、兼容基线与旧协议/资产兼容性说明。
- 保留：`LICENSE`/`COPYING`、`**/NOTICE*`、`**/PATCHES.md`、`**/UPSTREAM*`、`**/CLAUDE.upstream.md`、`third_party/**`、`ci/patches/**`、`references/**`、`docs/**`（ADR + 历史文档）、`my_comic/docs/**`、`.scratch/**`、`GLOSSARY.md`、扫描器自身与 fixture、About/Runner.rc/脚本/测试的署名行。

### CI / 仓库元数据核查

- `.github/FUNDING.yml`：`github: Myyuluo`。
- Issue 模板：标题/说明为 MyComic，平台选项仅 Windows 10/11，链接指向 `Myyuluo/my-comic`。
- Release 标题/产物：`MyComic desktop debug …`、`MyComic <version> beta …`、`MyComic <version>`、`mycomic-*-windows-setup.exe`；`release-desktop.yml` 只剩 Windows + publish。
- CI 不再引用上游仓库（`build-multiplatform.yml`、`release-desktop.yml`、`dev-activity.yml`、`star-history.yml` 使用 `github.repository` 或 fork 本地路径）；无 fushi.moe / Discord / TestFlight 链接。
- 未改动 workflow 行为。`pr-merge-gate.yml` 的 `ALLOWED_AUTHORS: 'hajisensai W1ght'` 与相关注释是 2026-09-07 用户明确决定的合并白名单，且有守卫测试钉死；改名单属于用户决策，本 ticket 不动。`release-desktop.yml` 的审批门注释仍提到历史审批人，属注释性历史说明。

### 验证

- `dart tool/audit/fushi_references.dart --fail-on-violations`：**0 violations**（5450 个受版本控制文件；2555 hits 全部 allowlist；user_visible_copy 87、code 89、docs 1330、third_party 511、historical_docs 538）。
- README 链接目标均存在：`LICENSE`、`docs/adr/0003…`、`docs/adr/0024…`、`UPSTREAM.md`、`my_comic/docs/licenses/`、`my_comic/windows/installer/mycomic.iss`、`packages/my_comic_*`、`third_party/`、`tool/bootstrap.ps1`、`CLAUDE.md`、`GLOSSARY.md`。
- `LICENSE`（GPL-3.0 全文）与 `third_party/**` 的 LICENSE/NOTICE/PATCHES 未改动；About 的 `about_based_on_upstream` 四语言署名与 `Runner.rc` 版权行保持。
- 未改动产品代码，未运行 Flutter analyze/test/build（本 ticket 无代码变更）。

### 已知遗留（留 ticket 12 / 后续）

删除三个归档目录后，以下代码/测试仍以旧路径为输入（本 ticket 按范围要求不改代码，留 ticket 12 处理）：

- `my_comic/tool/pre_push_check.dart` 运行时读取 `docs/agent/fast-workflow.md` 解析枚举守卫清单。
- `my_comic/test/tools/tests_for_changes_guard_test.dart` 直接断言 `docs/agent/fast-workflow.md` 存在且包含推导命令。
- `my_comic/test/tools/my_comic_rename_guard_test.dart` 的路径形态扫描根仍包含 `../docs/agent`、`../docs/readme`，并断言其为目录。
- `my_comic/test/tools/bugs_per_file_guard_test.dart` 断言 `docs/bugs/` 存在且 `docs/BUGS.md` 索引指向的文件都在。
- `tool/bug.dart` 与 `.github/workflows/bug-number-settle.yml` 仍以 `docs/bugs/` 为工作对象；归档删除后该 workflow 不会再被触发，工具本身保留（未在本 ticket 删除 CI 行为）。

以上都不影响 Windows 构建、Fushi 引用扫描器或 README；ticket 12 需要决定是删除这些上游 bug/agent 工具链，还是把仍需要的内容迁到保留的 `docs/agents/` 或工具内常量。

其他保留说明：`docs/static-assets/**`、`docs/assets/dev-activity.svg`、`docs/assets/star-history.svg`、`docs/user-guide*.md` 等历史资料默认保留，仍含 Fushi 字样/截图；它们在 allowlist 的 `docs/**` 下，不再被 README 引用。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。历史文档（如 `fushi/docs/reviews`、旧五平台 spec）默认保留，不纳入本 ticket 的删除范围。
