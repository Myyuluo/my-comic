# 17: 恢复随包 Extension runtime 的本地构建

**Blocked by:** none
**Status:** ready-for-agent

## Problem Statement

在 Windows 上运行 my-comic 的本地构建时，Extension 无法安装：打开 Extension 页面或执行安装会弹出
`MihonRuntimeException (RUNTIME_MISSING): BundledJava/M-Extension-Server is missing from ...\Release\mihon_bridge`。

同一台机器上的官方 Fushi v3.0.0 可以正常安装和使用 Extension，说明这不是 Extension 兼容性回退，而是本地构建产物缺少
Bundled extension runtime。`flutter build windows` 不会生成 `mihon_bridge`；Fushi 的 Windows CI 会在构建后把官方 runtime
复制进 Release，而 my-comic 的本地构建流程没有这一步。结果是每次重新构建、或换一个 worktree 运行，都会复现同一个错误。

## Solution

把官方 Fushi v3.0.0 的 Bundled extension runtime 原样带入 my-comic 的本地 Windows 构建：

1. 先恢复当前正在运行的构建，让 Extension 立即可安装。
2. 新增一个 Windows build-and-run 脚本和根目录启动器，在每次构建后把仓库内的 runtime 缓存复制到 Release，
   校验 SHA256 与随附 checksums 一致后启动应用。
3. my-comic 继续只启动随包副本；runtime 缺失时明确失败，不做外部运行时发现。

## User Stories

1. 作为 Windows 用户，我希望本地构建的 my-comic 能像官方 Fushi v3.0.0 一样安装和运行 Extension，以便继续使用我已有的 Source。
2. 作为 Windows 用户，我希望用一条命令或双击启动器完成“构建 → 打包 runtime → 启动”，以便不用记住手动步骤。
3. 作为开发者，我希望每次重新构建后 Release 里自动出现 Bundled extension runtime，以便 `RUNTIME_MISSING` 不再复现。
4. 作为开发者，我希望代码和 worktree 没有变化时启动器跳过构建，以便快速启动。
5. 作为开发者，我希望启动器按仓库钉定的 Flutter 版本构建，以便不会误用系统上别的 SDK。
6. 作为开发者，我希望启动器在目标构建的 `fushi.exe` 正在运行时停止并提示，而不是强制结束进程，以便不丢失阅读或下载状态。
7. 作为开发者，我希望 runtime 来自官方 Fushi v3.0.0 的原件，以便扩展行为与兼容基准一致。
8. 作为维护者，我希望 runtime 复制前用 SHA256 与 checksums 核对，以便损坏或不匹配的副本不会进入 bundle。
9. 作为维护者，我希望 runtime 缺失时应用和构建流程都明确失败，以便打包缺口不会被静默降级掩盖。
10. 作为维护者，我希望有回归守卫测试钉住“构建后必须打包 runtime”的契约，以便未来改动不会再次只 build 不打包。
11. 作为 Extension 用户，我希望添加 Keiyoushi 的 Extension store URL 并刷新索引，以便浏览可安装的 Extension。
12. 作为 Extension 用户，我希望安装 Extension 时看到 Signer 的 Trust 确认，以便知道内容由谁签名。
13. 作为 Extension 用户，我希望安装后看到该 Extension 提供的 Source，以便开始浏览。
14. 作为 Extension 用户，我希望对 Source 执行 Popular/Search、查看 Manga 详情与 Chapter 列表、读取 Page 图片，以便完整阅读。
15. 作为 Extension 用户，我希望 my-comic 的 Extension 行为以 Fushi v3.0.0 为基准，以便 Fushi 能用的 Extension 继续可用。
16. 作为开发者，我希望真实 runtime 的 E2E 验收复用现有构造注入 seam，以便不新增生产测试 seam。
17. 作为开发者，我希望 Extension store 升级时只需更新测试中的版本期望，而不改变行为断言，以便 harness 可维护。
18. 作为维护者，我希望 GLOSSARY 和 ADR 记录本次的术语与分发契约，以便后续工作不会把“随包运行时”改成“外部运行时发现”。
19. 作为开发者，我希望本地 Windows 构建文档说明 runtime 打包步骤，以便下一个人不会重复踩坑。
20. 作为用户，我希望本次修复不改变 UI，以便继续使用 Fushi v3.0.0 的设计。

## Implementation Decisions

- **兼容基准**：Extension 行为以 Fushi v3.0.0 为准（ADR-0003、ADR-0006）；本次不改变 UI（ADR-0008）。
- **分发契约**：新增 ADR-0009——Extension runtime 作为 Bundled extension runtime 随应用分发，应用只启动随包副本；
  不做 PATH、系统 Java、外部 Fushi 安装目录或其他 fallback 的运行时发现。缺失时以 `RUNTIME_MISSING` 失败。
- **Runtime 来源**：官方 Fushi v3.0.0 的 Bundled extension runtime 原件；JAR 的 SHA256 必须与随附 checksums 一致，并匹配固定的官方哈希。
  在缓存有效时不重新构建 runtime；源码构建只作为缓存缺失时的兜底，复用 Fushi 原有的 runtime 构建脚本，产物也必须匹配同一官方哈希。
- **本地缓存**：仓库内、已被版本控制忽略的 runtime 缓存；同一 checkout 的多次构建复用它。
  缓存缺失时，优先从显式指定的现有 runtime 来源复制（参数或环境变量），否则调用 Fushi 原有构建脚本；不硬编码本机路径。
- **Windows build-and-run 脚本**：
  - 从仓库的 Flutter 版本钉定位 SDK，候选顺序沿用现有 bootstrap；额外允许 `FUSHI_FLUTTER` 指向 SDK 目录。
  - 用 HEAD 与构建戳比较；未变化且目标 exe 存在时跳过构建。
  - 需要构建时执行 `flutter pub get` 与 `flutter build windows --release`。
  - 构建前确保 NuGet 可用（WebView2/WIL 依赖）；按参数/环境变量/仓库内缓存/常见目录/PATH 查找，找不到时明确失败。
  - `strings.g.dart` 是 Slang 的 gitignored 构建产物；缺失或 i18n JSON 更新时先执行 `dart run slang` 与 `dart format`。
  - 按完整路径检测目标构建的 `fushi.exe` 是否运行；运行中则中止并提示，不强制杀进程。`-NoLaunch` 只构建/打包不启动；`-SkipBuild` 跳过构建（验证/运维用）。
  - 确保 runtime 缓存存在，原样复制到 Release 的 `mihon_bridge`，覆盖旧副本。
  - 复制后核对 JAR 的 SHA256、checksums 与固定的官方哈希，并检查必需文件存在；显式指定但无效的 `-RuntimeSource` 直接失败；本地不执行需要 PowerShell 7 的 CI 校验脚本。
  - 启动目标 `fushi.exe`。
- **本地依赖解析**：本机 pub 镜像与 upstream lock 不一致时，脚本使用 `.dart_tool/my-comic/pubspec.lock` 的本地已知可用 lock + `pub get --enforce-lockfile`，构建用 `--no-pub`，提交的 `pubspec.lock` 不被改写。这是本地构建适配，不改变依赖清单。
- **启动器**：根目录新增一个薄的 `启动MyComic.bat`，调用 build-and-run 脚本；失败时保留窗口。
  旧的 `启动Fushi最新版.bat` 原样保留，不删除、不改写。
- **术语**：`GLOSSARY.md` 新增 **Signer（签名者）**、**Trust（信任）**、**Bundled extension runtime（随包扩展运行时）**；
  实现名（`mihon_bridge`、`M-Extension-Server`、`RUNTIME_MISSING`、脚本文件名）不写入 glossary，放在本 ticket 与开发文档。
- **不改扩展实现**：不修改 Mihon 扩展模块、sidecar Kotlin、Extension 安装/Trust 逻辑。
- **验收 harness**：复用 ticket 08 已存在的真实 runtime E2E 测试；使用 Keiyoushi 的 `index.pb` 与一个真实 Extension
  （Atsumaru）覆盖安装、Trust、Source、Popular/Search/Details/Chapters/Pages/Image。若 store 版本漂移，只更新版本/签名期望，
  不改变行为断言。
- **工作流**：在新的 ticket 分支/worktree 实施，验收通过后合并回 `integration/my-comic-v1-restored`；ticket 状态改为 resolved。
- **立即恢复**：先把官方 Fushi v3.0.0 的 runtime 原样复制到当前运行的构建产物；这是本地操作，不进入提交。

## Testing Decisions

- 好的测试只断言外部行为：真实 Sidecar 能否启动、Extension 能否安装、Signer 是否被 Trust、Source 的 Manga/Chapter/Page
  能否被读取；不测试私有字段、缓存实现或文件复制细节。
- **Seam 1（生产 seam，复用现有构造注入，不新增）**：通过 `DesktopMihonRuntime` 的 `resourceDirectory` 构造参数，
  以及 `MihonManager` 的 `runtime` / `database` / `rootDirectory` 构造参数注入真实 runtime、内存数据库与临时目录。
  覆盖 `/capabilities`、Keiyoushi store 拉取解析、Extension 安装写库、Signer Trust、Source 列表、Popular/Search/
  Details/Chapters/Pages/Image。prior art 是 ticket 08 的真实 Extension E2E 测试。
- **Seam 2（测试专用静态守卫，复用现有 build-guard 模式）**：源码守卫测试断言 Windows build-and-run 脚本保留
  “缓存 → 复制到 `Release\mihon_bridge` → 固定官方 SHA256 核对 → 无外部 runtime 发现（无 PATH/系统 Java/外部安装目录）”的契约。
  prior art 是仓库现有的 build/workflow guard tests。
- **网络门控**：Keiyoushi `index.pb` 用例访问网络，只在 `FUSHI_TEST_MIHON_STORE_E2E=1` 时运行；默认 Windows 套件保持离线可跑。
- **手工验收**：用户用 `启动MyComic.bat` 在 UI 中添加 Keiyoushi 的 Extension store URL、安装 Extension、确认 Source 可用。
- **版本漂移**：store 升级导致 Atsumaru 版本或 Signer 变化时，只调整测试期望值；安装/Trust/浏览的行为断言保持不变。

## Out of Scope

- 在 runtime 缓存有效时重新从源码构建。
- 给应用增加运行时备用查找路径或外部 runtime 发现。
- 修改 CMake、CI workflow 或发布流水线。
- Windows 安装器与打包（属于 ticket 09）。
- 任何 UI 改动。
- 修改 Extension 实现、sidecar Kotlin 或 Trust 逻辑。
- 超出 Fushi v3.0.0 的 Extension 兼容性。
- 非漫画域功能。
- 删除或改写旧的 `启动Fushi最新版.bat`。

## Further Notes

- 本机官方 Fushi 为 v3.0.0+19763；其 Bundled extension runtime 的 `m-extension-server.jar` SHA256 为
  `648886cac618a0119c9108573ba0d7bf09db420926e3044d76ec16ec7777e4df`，与仓库内已有缓存及 aca worktree 的副本逐字节一致；
  vendored sidecar 源码自基线导入以来零改动。
- 仓库现有的 runtime 校验脚本依赖 PowerShell 7；本机只有 Windows PowerShell 5.1，
  因此本地流程用 SHA256 + 必需文件检查替代，CI 的 verify 保持原样。
- ticket 08 的 E2E harness 目前存在于 aca worktree 的 WIP 分支并标记为临时；本 ticket 将其纳入正式测试并去掉临时标记。
- 当前报错的 a728 worktree 构建比集成分支落后两个提交；立即恢复只补 runtime，不重建应用。
- 源码构建兜底的可复现性未单独验证；脚本会用固定的官方哈希拒绝任何不匹配的产物。现有官方 runtime、缓存与 aca 副本的哈希一致。
- Keiyoushi Extension store URL：`https://github.com/keiyoushi/extensions/raw/repo/index.pb`。
- ticket 编号 17 避开 aca 分支已存在但未合并的 12–16，防止撞号。

## Comments

- 2026-11-05 立即恢复：官方 Fushi v3.0.0+19763 的 `mihon_bridge` 原样复制到 a728 worktree 的 Release；JAR SHA256 `648886ca…e4df` 与 checksums 一致。
- 2026-11-05 本地构建：`script/build_and_run.ps1` + `启动MyComic.bat` 在 ticket 分支完成首次构建（exit 0）；`Release/mihon_bridge/m-extension-server.jar` SHA256 与官方一致。二次运行命中 HEAD 戳，输出 `build is current` 并只重新打包 runtime。
- 运行中阻断：启动 Release 的 `fushi.exe` 后再次运行脚本，脚本以 `Close my-comic before building: ... is running.` 中止；随后进程已停止，无残留 java/fushi 进程。
- 真实扩展 E2E（ticket 分支自己构建的 Release runtime）：sidecar `/capabilities` 全为 true；Atsumaru v1.6.26（lib 1.6，signer `9add…`）inspect、Popular 40、Search 1、Details、147 章、17 页、页面图片 192,776 B、封面 94,396 B 全部通过；`MihonManager` 安装写库并 Trust signer；Keiyoushi `index.pb` 拉到 1458 个 Extension。
- 测试：build guard 3/3（目录级 `flutter test --no-pub`）；真实扩展 E2E 3/3（store 用例在设置 `FUSHI_TEST_MIHON_STORE_E2E=1` 时运行）。按仓库约定，本地验收只跑定向测试，不把全量套件作为门禁。
- 环境补充（已写入脚本与 `docs/agent/build.md`）：本机 `FUSHI_FLUTTER` 指向 SDK 目录时脚本自动补 `bin\flutter.bat`；NuGet 从 `.dart_tool/nuget/nuget.exe` 解析；`strings.g.dart` 缺失时自动 `dart run slang` + `dart format`。本地仍不跑需要 PowerShell 7 的 `verify_desktop_runtime.ps1`。
- 依赖解析：本机 pub 镜像与 upstream lock 的 URL 不匹配，plain `pub get` 会升级到 image 4.12 / dio 5.11 / dartssh2 2.14 并导致 `flutter build` 失败。脚本改用 `.dart_tool/my-comic/pubspec.lock` 的本地已知可用 lock + `pub get --enforce-lockfile`，构建用 `--no-pub`，工作区 lock 保持 upstream 版本。
- 评审修复：脚本钉住官方 JAR SHA256（缓存/来源/打包/清单四层校验）；显式指定但无效的 `-RuntimeSource` 直接失败；store E2E 加 `FUSHI_TEST_MIHON_STORE_E2E=1` 门控；守卫测试钉死复制目标与官方哈希。
- 待办：用户在 UI 里用 `启动MyComic.bat` 手工确认一次（添加 Keiyoushi store → 安装 Extension → Source 可用），之后把 ticket 置 resolved 并合并回 `integration/my-comic-v1-restored`。
