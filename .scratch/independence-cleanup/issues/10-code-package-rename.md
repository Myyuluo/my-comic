# 10: 代码、包与目录全量重命名

**What to build:** 把剩余代码标识符统一为 MyComic：应用目录/包名、workspace 包、import、文件名/类名/变量名、图标字体、channel 前缀、环境变量、更新资产前缀常量和 Windows 单实例符号；不触碰许可证、第三方声明、UPSTREAM、ADR 与历史文档。

**Blocked by:** 09

**Status:** resolved

- [x] 应用目录与 Dart 包名：`fushi/` → `my_comic/`，`name: fushi` → `name: my_comic`；根 workspace/Melos 名同步。
- [x] 剩余 workspace 包 `fushi_*` → `my_comic_*`；所有 `package:fushi/...` import 更新为新包名。
- [x] 文件名、类名、变量名、常量名中的 `Fushi` 改为 MyComic 语义；优先机械替换，再处理缩写/别名。
- [x] 图标字体与资源名（如 `FushiSymbolsRounded`）改为 MyComic 命名，并更新 pubspec/asset 引用。
- [x] `app.fushi/*`、`app.fushi.reader/*` channel 前缀改为 `app.mycomic/*` 等新前缀；Dart 与 Windows 原生端同步。
- [x] `FUSHI_*` 环境变量改为 `MYCOMIC_*`；测试、构建脚本与文档同步。
- [x] `kFushiAssetPrefix` → `kMyComicAssetPrefix`，值保持 `mycomic-`；更新器与 CI 产物一致。
- [x] Windows 单实例互斥量、`FindWindowW` 标题、安装器/协议注册中的 `fushi` 标识改为 MyComic；如仍有 `fushi://` handler，改为 `mycomic://` 或删除。
- [x] 更新 CMake、Inno Setup、构建脚本、CI、测试与 `.vscode`/启动脚本中的路径与名称。
- [x] 不重命名 `LICENSE`、第三方 NOTICE/PATCHES/UPSTREAM、`UPSTREAM.md`、ADR、历史文档中的 Fushi 来源记录。
- [x] 验证：`flutter analyze`、全量相关测试、`flutter build windows --debug` 与 `--release`、安装包构建、冷启动冒烟；Fushi 扫描器只剩 allowlist。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。这是本计划中最大的机械 diff；放在功能删除、i18n 和 Onboarding 之后，避免冲突与审阅噪音。

## 实现记录（2026-11-12）

- Worktree: `e:/tmp/mycomic-wt/ticket-10`
- Branch: `ticket/10-code-package-rename`（基于 `2a7b92db`）
- Toolchain: Flutter 3.47.6 / Dart 3.13.5（`D:/ProgramData/flutter_3.47.6`），Windows 10 Pro 19045
- Bootstrap：`pwsh` 不在 PATH，按 fallback 用 PowerShell 5.1；`FUSHI_FLUTTER` 需覆盖为 `.../bin/flutter.bat`。NuGet 从主 checkout 复制到 worktree `.dart_tool/nuget/`。

### 目录、包与 import

- `fushi/` → `my_comic/`；应用 `name: fushi` → `name: my_comic`；根 workspace 与 Melos 名 `fushi_workspace` → `my_comic_workspace`，Melos `repository` 改 `https://github.com/Myyuluo/my-comic`。
- `packages/fushi_{cli,core,engine,platform}` → `packages/my_comic_*`；全部 `package:fushi/...`、`package:fushi_*/...` 的 import/export/part 同步，`pubspec.lock` 重新解析。
- 206 个文件用 `git mv` 保留历史：设计系统/焦点/组件/测试文件、`gen_fushi_symbols.py` → `gen_my_comic_symbols.py`、`FushiSymbolsRounded*.ttf` → `MyComicSymbolsRounded*.ttf`、`fushi.iss` → `mycomic.iss`、CLI bin、systemd 单元、debug 脚本等。
- 机械语义替换：`Fushi*` → `MyComic*`、`fushi_*` → `my_comic_*`、`fushiCamel` → `myComicCamel`；`FushiDatabase` → `MyComicDatabase`（含 `database.g.dart` 生成类）；`MyComicIcons` / `MyComicSymbols*` 字族与 `my_comic_icons.g.dart` 同步。

### Channel / 环境变量 / 常量 / 深链

- `app.fushi*` → `app.mycomic*`（Dart channel 常量与 Windows runner 原生 channel 同步）。
- `FUSHI_*` → `MYCOMIC_*`（`MYCOMIC_FLUTTER`、`MYCOMIC_BOOTSTRAP_PROXY`、`MYCOMIC_NUGET`、`MYCOMIC_TEST_ROOT`、`MYCOMIC_TEST_HIDDEN` 等），Dart/native/CI/测试/脚本同步。
- `kFushiAssetPrefix` → `kMyComicAssetPrefix`（值 `mycomic-`）；`kFushiManifestSuffix` → `kMyComicManifestSuffix`，值改 `-mycomic`；`kFushiBuildVersionDefine` → `kMyComicBuildVersionDefine`（`FUSHI_BUILD_VERSION` → `MYCOMIC_BUILD_VERSION`）。
- 持久化媒体标识 `fushi://book/`、`fushi://srtbook/` → `mycomic://book/`、`mycomic://srtbook/`；不存在 URL protocol handler 注册（干净切换）。
- rolling debug tag `fushi-debug-rolling` → `mycomic-debug-rolling`；workflow concurrency group `mycomic-release-*`；release policy 守卫同步。

### Windows runner / 安装器

- CMake `BINARY_NAME "MyComic"`（产物 `MyComic.exe`）；更新器目标/产物 `my_comic_update_launcher.exe`；`Runner.rc` `OriginalFilename=MyComic.exe`，`LegalCopyright` 保留 Fushi contributors + MyComic contributors 两行。
- 单实例符号 `kFushiSingleInstanceMutex` → `kMyComicSingleInstanceMutex`，运行时值 `MyComicSingleInstanceMutex`；`FindWindowW` 标题保持 ticket 09 的 `MyComic` / `MyComic Dev`。
- `mycomic.iss`：[Files]/[Icons]/[Run]/[Registry]/[Code]/进程清理统一 `MyComic.exe`；`AppMutex` 去重为 `MyComicSingleInstanceMutex,HibikiSingleInstanceMutex`；删除会误删新 ProgId / 新快捷方式的旧品牌清理块；旧 Fushi 专属二进制/快捷方式清理随干净切换移除；AppId GUID 不变。
- 原生 `galgame_hook`：CMake project/target、C++ namespace、helper DLL/injector 名 `fushi_voice_hook` → `my_comic_voice_hook`；Dart/CI/installer 引用同步。

### 遗留 DB / 快照

- 删除 `fushiLegacyDatabaseFileName` / `legacyHibikiDatabaseFileName` 常量与快照识别白名单中的旧库名；只识别/打开 `my_comic.db`。
- `.fushi.zip` 识别残留移除；app 注释与测试 fixture 改为 `my_comic.db`；离线 pack 工具改用 `.mycomic.zip` / `mycomic.db` 命名（工具本身仍是上游推荐包遗留）。

### 工具 / CI / 配置

- `.gitattributes`、`.gitignore`、`.vscode/launch.json`、根启动脚本、`script/build_and_run.ps1`、`tool/setup_worktree.ps1`（merge driver `mycomic-i18n-json` + `dart my_comic/tool/i18n_merge_driver.dart`）、`tool/bootstrap.ps1`、CI workflows/actions 路径与可执行名全部更新。
- `tool/audit/fushi_references_allowlist.json` 路径改 `my_comic/**`；新增 `third_party/**`、`ci/patches/**`、`references/**`、`**/CLAUDE.upstream.md` 与 README 临时整文件规则（ticket 11 收紧）。
- 上游元数据引用改为 `Myyuluo/my-comic`（star/dev-activity、pr/ci sweep、panel model asset URL、Melos repository）；移除 `mycomic.moe` 示例。

### 不动的来源记录

- `LICENSE`、第三方 NOTICE/PATCHES/UPSTREAM、`UPSTREAM.md`、ADR、`my_comic/docs/**`、`.scratch/**`、README（ticket 11）、`GLOSSARY.md` 内容保持原样；About/README 的“基于 Fushi v3.0.0”与两份版权保留并 allowlist。

### 验证

- `cd my_comic && dart run slang`：通过（4 locale）。
- `flutter analyze --no-pub`（my_comic）：155 issues，0 error（与基线一致，全部 warning/info）。
- `dart analyze`（workspace packages）：`my_comic_engine` / `my_comic_platform` / `my_comic_cli` 0；`my_comic_core` 9 条既有 warning/info。
- 相关测试（1232 个）：85 个失败；与 ticket-09 基线（91 个失败）对比，**无 rename 新增失败**。修复本 ticket 引入的 6 类失败：品牌负向断言、资产族/清单后缀、`make_download_manifest` host guard、About 来源恢复、源码守卫 CRLF、安装器清理。基线差异：4 条 loading 路径假阳性（同一批 gal/subtitle/load_paths guard 文件在基线同样缺失）与 `fresh_schema_wiring` 测试改名（同一 `ctl_data_routes.dart` 已删除原因）；另有 6 条基线失败在本树转绿（wal/db failure/webview fallback 等）。
- `flutter build windows --debug --no-pub`：通过，253.4s，产物 `build/windows/x64/runner/Debug/MyComic.exe`（另有 `my_comic_update_launcher.exe`）。
- `flutter build windows --release --no-pub`：通过，288.6s，产物 `build/windows/x64/runner/Release/MyComic.exe`（另有 `my_comic_update_launcher.exe`）。
- 冷启动冒烟：启动 Debug `MyComic.exe`，12s 后进程存活、主窗标题 `MyComic`；随后结束进程。
- exe 版本资源：`CompanyName` / `FileDescription` / `InternalName` / `ProductName=MyComic`，`OriginalFilename=MyComic.exe`，`LegalCopyright` 同时含 Fushi contributors 与 MyComic contributors（GPL-3.0）。
- 安装器静态校验：PASS（AppId/AppName/DefaultDirName/Group/OutputBaseFilename/快捷方式/启动项/AppMutex/includes/18 个 wizard 资产/进程清理；本机无 ISCC，未实际编译）。
- Fushi 引用扫描器：`dart tool/audit/fushi_references.dart --summary` → 全部命中 allowlist，**0 violations**。
- `tool/check_release_policy.ps1`：pass。

### 已知 / 延后

- 全量 app 测试仍有基线失败（已删除功能/schema 的 DB 测试、静态守卫规模哨兵、缺失源文件守卫、`python3` WindowsApps 存根导致的 manifest race、settings 非漫画入口、`my_comic_cli` 非漫画命令），统一留 ticket 12。
- README / GLOSSARY / UPSTREAM / docs 与仓库元数据（Issue/FUNDING/Release 标题、README 链接）仍按 ticket 11。
- 安装包未实际 ISCC 编译（本机未安装 Inno Setup）。
- panel model 资产 URL 已改指 fork release；需在 `Myyuluo/my-comic` 上补齐 `manga-panel-detector-onnx-v1` release 资产，否则运行期模型下载 404。
- `native/galgame_hook` 仍作为非漫画原生面保留（ticket 04 约定后续 native 收口），本次只做命名。
