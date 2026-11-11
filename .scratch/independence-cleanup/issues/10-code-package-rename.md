# 10: 代码、包与目录全量重命名

**What to build:** 把剩余代码标识符统一为 MyComic：应用目录/包名、workspace 包、import、文件名/类名/变量名、图标字体、channel 前缀、环境变量、更新资产前缀常量和 Windows 单实例符号；不触碰许可证、第三方声明、UPSTREAM、ADR 与历史文档。

**Blocked by:** 09

**Status:** ready-for-agent

- [ ] 应用目录与 Dart 包名：`fushi/` → `my_comic/`，`name: fushi` → `name: my_comic`；根 workspace/Melos 名同步。
- [ ] 剩余 workspace 包 `fushi_*` → `my_comic_*`；所有 `package:fushi/...` import 更新为新包名。
- [ ] 文件名、类名、变量名、常量名中的 `Fushi` 改为 MyComic 语义；优先机械替换，再处理缩写/别名。
- [ ] 图标字体与资源名（如 `FushiSymbolsRounded`）改为 MyComic 命名，并更新 pubspec/asset 引用。
- [ ] `app.fushi/*`、`app.fushi.reader/*` channel 前缀改为 `app.mycomic/*` 等新前缀；Dart 与 Windows 原生端同步。
- [ ] `FUSHI_*` 环境变量改为 `MYCOMIC_*`；测试、构建脚本与文档同步。
- [ ] `kFushiAssetPrefix` → `kMyComicAssetPrefix`，值保持 `mycomic-`；更新器与 CI 产物一致。
- [ ] Windows 单实例互斥量、`FindWindowW` 标题、安装器/协议注册中的 `fushi` 标识改为 MyComic；如仍有 `fushi://` handler，改为 `mycomic://` 或删除。
- [ ] 更新 CMake、Inno Setup、构建脚本、CI、测试与 `.vscode`/启动脚本中的路径与名称。
- [ ] 不重命名 `LICENSE`、第三方 NOTICE/PATCHES/UPSTREAM、`UPSTREAM.md`、ADR、历史文档中的 Fushi 来源记录。
- [ ] 验证：`flutter analyze`、全量相关测试、`flutter build windows --debug` 与 `--release`、安装包构建、冷启动冒烟；Fushi 扫描器只剩 allowlist。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。这是本计划中最大的机械 diff；放在功能删除、i18n 和 Onboarding 之后，避免冲突与审阅噪音。
