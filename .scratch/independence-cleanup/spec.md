# MyComic 独立化清理（independence-cleanup）

Status: ready-for-agent
Date: 2026-11-12

## Problem Statement

MyComic 是从 Fushi v3.0.0 快照分叉出来的 Windows 桌面漫画阅读器，但目前仍带着大量上游身份与非漫画残留：窗口标题、可执行文件、安装器、包名、类名、channel、环境变量、CI 产物和图片资源仍使用 Fushi 命名；界面仍提供 17 种语言；小说/EPUB、视频/游戏、词典/查词、Anki/SRS、听书/TTS/ASR、云同步/Server、AI/Profile、反馈/排行榜、Tracking、首页 dashboard、浏览器扩展等非漫画功能虽然没有入口，但代码、服务和字符串仍完整保留；macOS 从未同步漫画-only 改造，Linux 连 CI 都不构建。用户是当前唯一用户，处于开发测试阶段，希望得到一个真正独立的 MyComic：只保留 Windows 和漫画域，只保留简体中文/繁体中文/英语/日语，界面与代码中不再有 Fushi 品牌，同时保留 GPL-3.0 许可证、第三方声明和 ADR 历史作为来源记录。

## Solution

执行一次分阶段的独立化清理：只保留 Windows 平台；删除所有非漫画功能及其运行时残留；把界面语言精简为 `zh-CN`、`zh-HK`、`en`、`ja`，并让系统 `zh-TW`/`zh-Hant` 落到 `zh-HK`；把产品、包、目录、类名、channel、环境变量、更新资产前缀和安装器身份统一改为 MyComic；重写三步骤新手引导；重写两份 README，删除上游文档归档；保留 GPL-3.0、第三方许可/声明、`UPSTREAM.md`、ADR 与历史记录，并在 README/About 明确“基于 Fushi v3.0.0”。不重写 git 历史，不做旧用户数据迁移；开发阶段接受 Program state root 全新开始，Content root 中的下载、本地漫画与备份保持原位。

## User Stories

### 身份与品牌

1. 作为用户，我希望窗口标题、任务栏、快捷方式和安装器都显示 MyComic，以便应用不再看起来像 Fushi。
2. 作为用户，我希望可执行文件是 `MyComic.exe`、安装目录是 MyComic，以便在资源管理器里能认出它。
3. 作为用户，我希望安装器保持同一个 AppId，以便升级时不出现两个卸载项。
4. 作为用户，我希望通知、About、错误日志和诊断信息里的应用名都是 MyComic。
5. 作为用户，我希望 About 显示 MyComic、GPL-3.0 和“基于 Fushi v3.0.0”，以便来源与许可清楚。
6. 作为维护者，我希望版权行同时保留上游版权与 MyComic 版权，以便满足 GPL 的修改与署名要求。
7. 作为用户，我希望品牌图标、启动图、应用图标和安装器插画都使用 MyComic 的 M 标识。
8. 作为用户，我希望应用不再访问 fushi.moe 的反馈、排行榜、统计或使用上游 User-Agent。
9. 作为用户，我希望更新检查只查询 `Myyuluo/my-comic` 的 Release，不再回退到上游 Fushi。
10. 作为维护者，我希望 CI 产物名是 `mycomic-<版本>-windows-setup.exe`，而不是 `fushi-*`。
11. 作为维护者，我希望窗口单实例查找、互斥量、安装器进程清理和快捷方式在改名后仍一致工作。
12. 作为用户，我希望从旧版本升级或重装后，应用不会同时保留 Fushi 和 MyComic 两套卸载项。

### 平台

13. 作为 Windows 用户，我希望只维护 Windows 构建，以便不背 macOS/Linux/mobile 的维护债。
14. 作为维护者，我希望删除 Android、iOS、macOS、Linux、Web 平台目录及其打包配置。
15. 作为维护者，我希望删除移动端/非 Windows 的 CI job、发布流程和专用依赖。
16. 作为维护者，我希望删除仅移动端/非 Windows 的 Dart 平台分支、平台通道和测试。
17. 作为 Windows 用户，我希望 Windows runner、Inno Setup 安装器和随包 JVM sidecar 继续正常工作。
18. 作为维护者，我希望 CI 只运行 Windows 的 analyze、test、golden、debug/release build 和安装包构建。
19. 作为维护者，我希望删除 `fushi_server` 以及只服务非 Windows 平台的发布工作流。
20. 作为维护者，我希望 `fushi_cli` 保留 Windows 需要的命令，但删除非漫画命令。

### 非漫画功能

21. 作为用户，我希望只保留漫画功能：Library、Manga 作品页、Reader、Source、Extension store、Discovery、History、Download、Settings、Tag、Backup 和 Local source。
22. 作为用户，我希望没有小说/EPUB 阅读器。
23. 作为用户，我希望没有视频、游戏、galgame、悬浮球和悬浮字幕。
24. 作为用户，我希望没有词典、查词页和弹窗词典。
25. 作为用户，我希望没有 Anki、SRS 和制卡功能。
26. 作为用户，我希望没有听书、TTS 和 ASR。
27. 作为用户，我希望没有云同步、设备互联、Fushi Server 和 P2P。
28. 作为用户，我希望没有 AI、在线服务和 Profile。
29. 作为用户，我希望没有反馈中心、排行榜、Fushi 迁移和首页 dashboard。
30. 作为用户，我希望没有 Tracking 和阅读统计。
31. 作为用户，我希望没有浏览器扩展及其查词上下文菜单。
32. 作为用户，我希望没有 PDF 导入。
33. 作为用户，我希望阅读器里没有 OCR 残留、查词、制卡或统计按钮。
34. 作为用户，我希望没有非漫画的桌面控制（CTL）端点、深链和外部协议处理器。
35. 作为用户，我希望没有非漫画原生库、动态库和随包资源。
36. 作为用户，我希望删除这些功能后，Library、阅读、下载、图源、Extension store、Backup 和 Local source 仍然正常。
37. 作为维护者，我希望保留 `ModuleId`/`HomeTab` 的旧枚举值和旧偏好键，以免旧偏好或旧备份解析崩溃。
38. 作为维护者，我希望删除运行时仍装配的非漫画服务、定时器、回调和 CTL 路由。
39. 作为维护者，我希望删除不再使用的测试、fixture 和测试辅助代码，而不是留下死引用。
40. 作为维护者，我希望删除旧向导及其 Anki/词典/听书/同步/浏览器扩展依赖。

### 语言与字符串

41. 作为用户，我希望界面语言只有简体中文、繁体中文、英语和日语四种。
42. 作为繁体中文用户，我希望系统 `zh-TW`/`zh-Hant` 默认落到繁体 `zh-HK`，而不是简体。
43. 作为用户，我希望默认语言跟随系统；系统语言不受支持时回退英语。
44. 作为用户，我希望语言选择器只显示四个选项，并继续使用现有的内联选择器组件。
45. 作为用户，我希望四种语言的翻译完整，不出现空 key 或非专有名词的英文回退。
46. 作为维护者，我希望删除 13 个不再支持的语言文件、语言名表项和写死 17 的测试断言。
47. 作为维护者，我希望删除所有未被剩余代码引用的 l10n key。
48. 作为维护者，我希望 `dart run slang` 在构建/CI 中确定执行，生成文件不依赖本地缓存。
49. 作为用户，我希望已删除功能的字符串不再出现在设置、搜索、通知或错误提示中。
50. 作为维护者，我希望字符串 key 在删除后仍然排序一致，并通过完整性检查。

### Onboarding

51. 作为首次使用的用户，我希望启动后看到三步新手引导。
52. 作为首次使用的用户，我希望第一步调整界面语言和明暗主题。
53. 作为首次使用的用户，我希望第二步选择一个 Content root，并看到 `downloads`、`autobackup`、`local` 三个子目录的最终路径。
54. 作为首次使用的用户，我希望选择文件夹时使用系统目录选择器，并复用现有的 Content root 校验。
55. 作为首次使用的用户，我希望目录选择先保存，完成引导时才重启；没有改目录则不重启。
56. 作为首次使用的用户，我希望第三步看到 MyComic 是 Mihon 兼容的桌面阅读器，支持导入 Mihon Backup 和使用 Extension store。
57. 作为首次使用的用户，我希望完成页只有说明和“完成”按钮，不复制 Backup 导入或 Extension 安装 UI。
58. 作为已有数据的开发者，我希望升级后不会被新手引导打断。
59. 作为用户，我希望能在“设置 → 系统与关于”重新打开新手引导。
60. 作为用户，我希望新手引导沿用 Fushi v3.0.0 的向导组件、主题和布局，不出现新的视觉语言。
61. 作为维护者，我希望新手引导的步骤序列仍由现有纯函数生成，便于测试。

### 数据与兼容

62. 作为用户，我希望 Content root（默认 `Documents\MyComic`）及其中的下载、本地漫画和备份不被改动。
63. 作为开发者，我希望继续只使用 `my_comic.db`；删除 `fushi.db`/`hibiki.db` 识别和 `.fushi.zip` 残留。
64. 作为开发者，我希望不写 Program state root 的 userdata 迁移逻辑；开发阶段接受全新开始。
65. 作为开发者，我希望不重写 git 历史。
66. 作为用户，我希望文档明确说明旧 `fushi://` 深链和旧 `fushi-` 更新资产不再兼容，需要手动重装或更新一次。
67. 作为开发者，我希望 Content root switch 仍只创建空目录、不搬文件，旧路径下的下载显示 Missing。
68. 作为开发者，我希望 Backup 的 `.tachibk` 导入/导出和 Extension store 兼容行为不变。
69. 作为开发者，我希望 `my_comic.db` 的漫画 schema 不变，不新增或删除业务表。

### 文档与许可

70. 作为用户，我希望 `README.md` 和 `README.zh-CN.md` 重写为 MyComic 的介绍、Windows 安装、Mihon 兼容和 GPL 署名。
71. 作为维护者，我希望删除 `docs/bugs`、`docs/readme`、`docs/agent` 三类上游归档。
72. 作为维护者，我希望保留 ADR、`UPSTREAM.md`、`GLOSSARY.md` 和 fork 自己的 specs/plans 作为历史与来源记录。
73. 作为维护者，我希望更新 `UPSTREAM.md` 中关于 `docs/agent` 的说明，避免指向已删除文件。
74. 作为维护者，我希望 GLOSSARY 把产品名从 `my-comic` 更新为 `MyComic`，并说明仓库名与 Dart 包名。
75. 作为维护者，我希望非漫画领域术语标注为 MyComic 不包含，或从 glossary 中移除。
76. 作为用户，我希望 LICENSE 和第三方 NOTICE/许可保持完整。
77. 作为维护者，我希望新增 ADR 记录 Windows-only、全量改名与干净切换的决策。

### 构建、CI 与质量

78. 作为开发者，我希望 Windows analyze、test、golden、debug/release build 和安装包构建全部通过。
79. 作为开发者，我希望有一个 Fushi 引用扫描器，allowlist 只包含许可证、第三方许可、`UPSTREAM.md`、ADR、历史文档和 README/About 署名。
80. 作为开发者，我希望有一个未使用 l10n key 扫描器；清理阶段先报告，清理完成后转为门禁。
81. 作为开发者，我希望每个 ticket 都以 analyze/test/Windows build 为门禁。
82. 作为开发者，我希望最终手动验收覆盖全新安装、Onboarding、语言切换、Extension store、Backup 导入、Local source、下载和阅读器。
83. 作为开发者，我希望安装包、快捷方式、卸载项、About 和通知都显示 MyComic。
84. 作为开发者，我希望 CI、Issue 模板、FUNDING 和 Release 标题不再指向上游。
85. 作为用户，我希望清理后应用能正常启动、浏览、下载和阅读漫画，不因删除功能而崩溃。

## Implementation Decisions

### 身份与命名

- 产品显示名统一为 `MyComic`；Dart 包名使用 `my_comic` / `my_comic_*`；可执行文件 `MyComic.exe`；应用目录 `my_comic/`；窗口标题 `MyComic`。
- 重命名应用包、workspace 包、目录、包含 `Fushi` 的文件/类/变量、`package:fushi` import、图标字体与资源名。
- 重命名平台通道前缀、`FUSHI_*` 环境变量、发布资产前缀（`kFushiAssetPrefix` → `kMyComicAssetPrefix`，值 `mycomic-`）、Windows 单实例互斥量与窗口查找标题。
- 安装器保持同一个 AppId GUID，避免出现两个卸载项；但安装目录、显示名、快捷方式、程序组、卸载图标全部改为 MyComic。
- 更新检查只查询 `Myyuluo/my-comic`；没有可用 Release 时按“已是最新”处理，不回退上游。
- 删除 fushi.moe 反馈/排行榜/统计/User-Agent 以及对上游仓库的引用。
- 保留 GPLv3 全文、第三方许可与 NOTICE；在 README/About 增加“基于 Fushi v3.0.0（GPL-3.0）”；版权行同时保留上游版权与 MyComic 版权。
- 干净切换：不兼容旧 `fushi://` 深链、旧 `fushi-` 更新资产；文档注明需要手动重装/更新一次。

### 平台

- 仅支持 Windows 10/11。
- 删除 Android、iOS、macOS、Linux、Web 平台目录、打包配置、平台专用 Dart 分支、移动端依赖和移动端测试。
- 删除对应 CI：Android release、macOS/iOS desktop release、multiplatform 非 Windows job、linux-server、release-server、mirror-releases。
- 保留 Windows runner、Inno Setup、Windows 原生通道、JVM sidecar、Windows build/test/golden/release workflow。
- `fushi_cli` 保留 Windows 所需命令，删除非漫画命令；`fushi_server` 删除。

### 功能范围

- 保留漫画域：Library、Manga 作品页、Reader、Source、Extension store、Discovery、History、Download、Settings、Tag、Backup、Local source。
- 删除小说/EPUB、视频/游戏/galgame/悬浮球/字幕、词典/查词、Anki/SRS、听书/TTS/ASR、云同步/互联/Fushi Server/P2P、AI/在线服务/Profile、反馈/排行榜/迁移、Tracking、首页 dashboard、浏览器扩展、PDF 导入、阅读统计、OCR 残留。
- 删除对应的独立包、engine 子域、原生库、页面、服务/provider、CTL 端点、深链、运行时装配、定时器和测试。
- 保留 `ModuleId`/`HomeTab` 的旧枚举值和旧偏好键，并加注释说明是兼容保留；删除功能实现。
- 删除 `fushi.db`/`hibiki.db` 识别代码和 `.fushi.zip` 残留引用；继续只打开 `my_comic.db`。
- 不改变漫画域行为：Library membership、Reader、Download library、Local source、Backup 导入/导出、Extension runtime 语义保持不变。

### 语言与字符串

- 保留 `en`、`ja`、`zh-CN`、`zh-HK`；删除其余 13 个 locale 文件。
- `zh-CN` 显示为简体中文；`zh-HK` 显示为繁體中文；`en`/`ja` 保持现有显示名。
- 增加显式映射：系统 `zh-TW`/`zh-Hant` → `zh-HK`；其余系统语言按现有逻辑匹配，最后回退 `en-US`。
- 保持“跟随系统语言”的默认行为，不强制 `zh-CN`。
- 语言选择器剩 4 项后使用现有内联选择器；不改视觉语言。
- 删除写死 17 的测试断言；删除浏览器扩展及其语言测试。
- 语言删除后必须执行 `dart run slang`；在构建脚本/CI 增加生成与校验步骤。
- 功能删除和 Onboarding 重写完成后，运行未使用 l10n key 扫描；删除无引用 key，重新生成并跑完整性/排序测试。
- 字符串清理的目标是：剩余四种语言完整、无死 key、无已删除功能的文案。

### Onboarding

- 重写为三步：欢迎（界面语言/明暗主题）→ 选择 Content root（展示 `downloads`/`autobackup`/`local` 最终路径）→ 完成说明。
- 只选择一个 Content root，不在本 spec 中支持三个子目录独立选择；复用现有 Content root 校验与目录选择器。
- 选择目录后只写偏好；用户点“完成”时如果有变化才重启。没有变化则不重启。
- 完成页只显示说明文字和“完成”按钮；不提供 Backup 导入或 Extension store 操作按钮。
- 完成页文案使用“Mihon 兼容的桌面阅读器”，与 GLOSSARY 的 `Mihon-compatible` 定义一致；不使用“Mihon 的桌面版”（避免暗示官方分支）。
- 新装用户首次启动显示：新增 Onboarding 完成偏好，默认未完成，并用现有 `first_time_setup` 标记避免已有用户被打扰。
- 在“设置 → 系统与关于”增加“重新打开新手引导”入口。
- 复用 Fushi v3.0.0 的向导组件、主题、spacing tokens 和布局；不照搬 Mihon Android 截图视觉。
- 这次 Onboarding 重写是 ADR 0008 UI fidelity 的显式例外；其余页面不改视觉。

### 文档与领域模型

- 删除 `docs/bugs`、`docs/readme`、`docs/agent` 三类纯上游归档。
- 保留 ADR、`UPSTREAM.md`、`GLOSSARY.md`、fork 自己的 specs/plans/reviews；`fushi/docs/reviews` 等未在删除名单内的历史文档默认保留。
- 重写 `README.md`（英文）和 `README.zh-CN.md`（中文），内容覆盖 MyComic 定位、Windows 安装、漫画功能、Mihon 兼容、GPL 与“基于 Fushi v3.0.0”。
- 更新 `UPSTREAM.md`，删除指向 `docs/agent` 的说明，并链接新的独立化 ADR。
- 更新 `GLOSSARY.md`：产品名改为 `MyComic`，说明仓库名 `my-comic` 与 Dart 包名 `my_comic`；新增 Onboarding 术语；把 App snapshot、Reading statistics、Tracking、Sync、OCR 等非漫画术语标注为 MyComic 不包含。
- 新增 ADR 记录 Windows-only、全量改名、干净切换与无迁移的决策；不修改历史 ADR 的原文。

### 顺序与 UI fidelity

- 执行顺序：审计与工具 → 平台裁剪 → 删除非漫画应用面 → 删除 PDF/统计/扩展/OCR 残留 → 删除独立非漫画包 → 语言精简 → Onboarding 重写 → 未使用字符串清理 → 用户可见品牌 → 代码/包重命名 → 文档/README/仓库元数据 → 最终验收。先删应用面和最后的包消费者，再删包；语言精简可与 PDF/扩展清理并行，保证每一步都能编译。
- 代码/包重命名放在功能删除和 Onboarding 重写之后，减少机械 diff 与冲突。
- 除 Onboarding 外，不改变 Fushi v3.0.0 的 shell、组件、主题、布局和视觉语言；新增入口（例如“重新打开新手引导”）复用现有设置行组件。
- 与 ADR 冲突时明确记录：Onboarding 重写是 ADR 0008 的已批准例外；Windows-only 与全量改名由新 ADR 记录，不静默覆盖旧 ADR。

## Testing Decisions

### 好测试的标准

- 只测试外部行为：用户能否完成 Onboarding、语言选择器是否只显示四种语言、繁体系统是否落到 `zh-HK`、Content root 是否切换成功、About/安装器/窗口是否显示 MyComic、已删除功能的入口和字符串是否消失。
- 不测试实现细节：不断言某个类是否存在、不依赖私有方法、不依赖文件路径或生成代码内部结构。
- 对删除/改名类工作，最高层的验收是 Windows 构建 + 冷启动冒烟；编译通过本身就是重要信号。

### 建议 seam

1. **主 seam（优先）**：Windows analyze/test/build + 冷启动应用冒烟。覆盖整个应用能编译、启动、进入 Library、打开 Settings、切换语言、打开阅读器。
2. **Onboarding seam**：现有纯函数 `onboardingStepSequence` + 向导页面 + `ContentRootSwitch`。覆盖三步序列、目录选择、重启时机、首次启动门控、设置重开入口。
3. **Locale seam**：`AppModel` 的 locale 解析 + 语言选择器 + i18n 完整性与排序 guard。覆盖四种语言、`zh-TW`/`zh-Hant` 映射、系统语言回退、删除 key 后的完整性。
4. **静态扫描 seam（新增，最高层脚本）**：Fushi 引用扫描器 + 未使用 l10n key 扫描器。扫描器只读仓库，不进入产品代码；allowlist 覆盖许可证、第三方声明、`UPSTREAM.md`、ADR、历史文档和 README/About 署名。

### 会测试的模块

- Onboarding 步骤序列、向导页面、首次启动门控、设置重开入口。
- 设置 destination：语言选择器、About/版本、重新打开新手引导。
- `AppModel` locale 解析与持久化。
- `ContentRootSwitch` 与 Content root 选择。
- i18n 文件完整性、排序、四种语言切换。
- Fushi 引用扫描器、未使用 l10n key 扫描器。
- Windows 安装器与冷启动冒烟。

### Prior art

- 现有 Onboarding 步骤序列测试与向导 widget 测试。
- 现有语言切换不重启测试、i18n 完整性与排序 guard。
- 现有设置 destination/renderer 测试。
- 现有 Content root 切换测试。
- 现有 Windows golden 测试与安装器冒烟脚本。

### Seam 确认

已确认（2026-11-12）：保留 4 个 seam。主 seam 是 Windows analyze/test/build + 冷启动冒烟；Onboarding、Locale、Scanner 作为现有/只读脚本 seam 保留。

## Out of Scope

- 旧用户数据迁移：不做 userdata 复制、迁移或兼容层。
- 重写 git 历史或清理历史提交中的 Fushi 字样。
- 重新设计 UI、重做书架/阅读器/下载页视觉；除 Onboarding 外不改 Fushi v3.0.0 外观。
- 新增漫画功能或修改 Library、Reader、Download library、Local source、Backup 的业务语义。
- 恢复 PDF 导入、阅读统计、浏览器扩展、词典、Anki、SRS、听书、同步、AI、Tracking。
- 三个子目录（downloads/autobackup/local）分别独立选择；仍只选择一个 Content root。
- 便携版、自动备份、跨平台支持、Mihon 官方分支或官方桌面版。
- 翻译到四种语言之外的新语言。
- 修改 Mihon Extension runtime 的兼容范围。
- 删除未在 `docs/bugs`/`docs/readme`/`docs/agent` 名单内的历史文档（例如 `fushi/docs/reviews`）。

## Further Notes

- Ticket 文件位于 `.scratch/independence-cleanup/issues/01-*.md` 到 `12-*.md`，按编号顺序执行。
- 当前是开发测试阶段，用户只有一人；因此不写 userdata 迁移，不做旧版本兼容层。安装新版本前建议手动卸载旧版；如要保留当前测试数据，唯一手动操作是复制旧 `userdata`。
- `my_comic.db` 已经是当前数据库文件名；Content root 默认 `Documents\MyComic`，下载、本地漫画和备份不受改名影响。
- `strings.g.dart` 目前被 gitignore 且 CI 没有生成步骤；语言精简 ticket 必须补生成与校验。
- 干净切换意味着旧版本无法自动发现新的 `mycomic-` 更新资产；需要手动更新/重装一次，这是已接受的代价。
- Onboarding 重写是用户明确批准的 ADR 0008 例外；其余 UI 保持 Fushi v3.0.0。
- GLOSSARY 当前仍以 `my-comic` 作为产品名，且包含 Tracking/Sync/OCR/Reading statistics 等非漫画术语；本 spec 要求同步更新为 MyComic 并标注非漫画术语为不包含。
- Fushi 引用 allowlist：`LICENSE`、第三方许可/NOTICE/PATCHES、`UPSTREAM.md`、ADR、历史文档、README/About 的“基于 Fushi v3.0.0”署名，以及 git 历史。
- 未在 Q4 删除名单内的上游历史文档默认保留；如果后续决定删除，另开 ticket。
- `fushi/docs/reviews`、旧五平台构建 spec 等历史文档会继续包含 Fushi 字样，但不再出现在产品、CI 或用户可见文案中。
- 产品文案已确认（2026-11-12）：完成页使用“Mihon 兼容的桌面阅读器”，与 GLOSSARY 的 `Mihon-compatible` 定义一致；不使用“Mihon 的桌面版”。
