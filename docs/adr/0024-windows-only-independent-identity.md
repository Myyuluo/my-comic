---
status: accepted
---

# Windows-only 的 MyComic 独立身份与干净切换

MyComic 基于 Fushi v3.0.0 快照，但目前只有 Windows 被实际维护和测试：macOS 从未同步漫画-only 改造，Linux 不在 CI 构建，移动端也不是目标。我们决定把 MyComic 收窄为 Windows-only 的独立产品：删除非 Windows 平台、非漫画域和隐藏运行时；界面语言只保留 `zh-CN`、`zh-HK`、`en`、`ja`，并让系统 `zh-TW`/`zh-Hant` 落到 `zh-HK`；产品名、包名、目录、类名、channel、环境变量、更新资产前缀和安装器身份全部改为 MyComic。这是一次干净切换：不迁移 Program state root、不兼容旧 `fushi://` 深链或旧 `fushi-` 更新资产。Fushi 只作为 GPL 来源与历史记录保留在 LICENSE、第三方声明、`UPSTREAM.md`、ADR、历史文档和 README/About 的来源署名中。

**Considered Options**

- **保留 macOS/Linux**：macOS 能构建但从未同步漫画-only 改造，Linux 不在 CI 构建；保留等于长期维护两套更接近上游的分支，且容易误发更“脏”的包。
- **保留 17 种语言**：非目标语言没有维护收益，且会让已删除功能的字符串继续存在；四种语言覆盖当前产品与用户。
- **只改用户可见品牌、保留内部 Fushi 标识**：会留下半套命名，后续清理成本更高；用户已确认接受全量改名与手动更新一次的代价。
- **迁移 Program state root 或重写 git 历史**：当前是开发测试阶段、只有一名用户，迁移与历史重写成本高于收益，且 GPL 署名仍须保留。

**Consequences**

- 旧版本的自动更新无法识别新的 `mycomic-` 资产，需要手动更新/重装一次；旧 `fushi://` 深链不再兼容。
- Program state root 全新开始；Content root（默认 `Documents\MyComic`）中的下载、本地漫画和备份保持原位。
- Fushi 字样只允许出现在许可证、第三方声明、`UPSTREAM.md`、ADR、历史文档和 README/About 的来源署名中；产品、代码标识符、CI 产物和用户可见文案零残留。
- Onboarding 重写是 ADR 0008 UI fidelity 的显式例外；其余 UI 继续使用 Fushi v3.0.0 的 shell、组件、主题和布局。
- 未来若恢复跨平台，需要从 git 历史恢复被删除的平台代码，并重新设计平台适配；这是有意的取舍。

## Amendment 2026-11-12（M-Extension-Server 冻结契约）

随包的 M-Extension-Server jar 是固定版本（v1.0.5.0）的预编译二进制，不能随宿主代码一起改名。它的 `FUSHI_MIHON_TOKEN` / `FUSHI_MIHON_PROXY_POLICY_PORT` 环境变量、`FUSHI_MIHON_READY port=` stdout 标记、`fushiMihonBridge` capabilities 键，以及 `X-Fushi-Cookies` / `X-Fushi-Set-Cookie` cookie 头都是与 jar 绑定的冻结契约；宿主在改名后仍必须发送/接受这些旧名字，否则 sidecar 会在启动时抛出 `FUSHI_MIHON_TOKEN is required`（表现为 `START_TIMEOUT`），或 capabilities/cookie 同步失败。这些字符串是二进制兼容契约，不是用户可见品牌，列入 Fushi 引用扫描器 allowlist；要彻底改名必须先重建并重新钉住 jar 与 checksum。
