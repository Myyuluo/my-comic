# my-comic v1 Spec

Status: ready-for-agent

## Problem Statement

我在 Android 上用 Mihon 看漫画，但坐到 Windows 电脑前时没有同等体验。现有的桌面方案要么要求我运行一个本地服务器（Suwayomi），要么界面难看、设置复杂，要么像 Fushi 一样是个多功能语言学习应用——它支持 Mihon 扩展，但不支持读取 Mihon 备份，而且塞满了我不需要的词典、小说、视频、Anki 功能。我想要的只是一个简单的 Windows 漫画阅读器：保留 Fushi 好看的设计，能安装和运行 Mihon 扩展，能读我的本地漫画，能把 Mihon 的备份完整导入过来。

## Solution

my-comic 是一个 Windows 桌面漫画阅读器，以 Fushi v3.0.0 的代码快照为基座，只保留漫画域。它保留 Fushi 的视觉设计和 JVM sidecar 扩展运行时，支持 Extension store、Extension、Source、Library、Category、Reader、Download、History、Update、Tracking（以 Fushi 实际支持的 provider 为准）和 Local source；它能把 Mihon v0.21.3 生成的 `.tachibk` Backup 导入到本地 Library。非漫画模块被删除，不需要用户运行服务器，不内置任何 Extension store，源码以 GPL-3.0 公开。

## User Stories

### 安装与首次运行

1. 作为 Windows 用户，我希望用一个安装器完成安装，以便快速开始使用。
2. 作为普通用户，我希望安装不需要管理员权限，以便在公司或受限电脑上也能安装。
3. 作为用户，我希望应用不依赖本地服务器或账号，以便安装后直接可用。
4. 作为用户，我希望数据保存在可预测的本地目录，以便备份或迁移。
5. 作为首次使用的用户，我希望添加 Extension store URL，以便安装 Extension。
6. 作为首次使用的用户，我希望从 Settings 导入 Mihon Backup，以便把已有 Library 带过来。
7. 作为用户，我希望应用界面里没有小说、视频、词典、Anki、galgame 等非漫画入口，以便界面保持专注。

### Library 与 Category

8. 作为用户，我希望 Library 显示封面、标题、未读数量，以便选择要读的 Manga。
9. 作为用户，我希望创建、重命名、删除 Category，并把 Manga 分配到 Category，以便组织 Library。
10. 作为用户，我希望按 Category、未读状态、标题、最近阅读排序和筛选，以便快速找到 Manga。
11. 作为用户，我希望从 Source 刷新 Manga 的元数据和封面，以便信息保持最新。
12. 作为用户，我希望从 Library 移除 Manga 而不删除已下载内容，以便控制数据。
13. 作为用户，我希望 Local source 的 Manga 也出现在 Library 并支持 Category 和 Reading progress，以便和在线 Manga 一样管理。

### Extension store、Extension 与 Source

14. 作为用户，我希望添加 Keiyoushi 等 Extension store 的索引 URL，以便浏览可用 Extension。
15. 作为用户，我希望看到 Extension 的名称、版本、语言和 Source 数量，以便选择。
16. 作为用户，我希望安装、更新、卸载 Extension，以便管理内容来源。
17. 作为用户，我希望在首次遇到新的签名者时确认 Trust，以便知道内容来自谁。
18. 作为用户，我希望看到 Extension 提供的 Source 列表，以便使用具体来源。
19. 作为用户，我希望 Extension 的安装和运行行为与 Fushi v3.0.0 一致，以便我常用的 Extension 继续可用。
20. 作为用户，我希望 Extension 无法运行时看到清晰错误，以便换一个 Source 或报告问题。

### 浏览与搜索

21. 作为用户，我希望浏览 Source 的 Popular 和 Latest，以便发现 Manga。
22. 作为用户，我希望在 Source 内搜索并应用过滤器，以便找到特定 Manga。
23. 作为用户，我希望查看 Manga 详情（标题、封面、作者、简介、状态、Chapter 列表），以便决定是否阅读。
24. 作为用户，我希望从详情页把 Manga 加入 Library 和 Category，以便持续跟踪。

### 阅读器

25. 作为用户，我希望打开 Chapter 逐页阅读，以便看漫画。
26. 作为用户，我希望支持 paged LTR/RTL、Webtoon/vertical 和双页模式，以便适配不同漫画排版。
27. 作为用户，我希望调整阅读模式、背景、亮度和点击区域，以便阅读更舒适。
28. 作为用户，我希望自动保存 Reading progress，以便下次继续。
29. 作为用户，我希望跳到上一章/下一章，以便连续阅读。
30. 作为用户，我希望把 Chapter 标记为已读/未读，以便管理进度。
31. 作为用户，我希望阅读器里没有查词、Anki、统计等非漫画按钮，以便界面保持漫画阅读所需的最小集合。

### 下载

32. 作为用户，我希望通过 Source 的 HTTP 接口下载 Chapter，以便离线阅读。
33. 作为用户，我希望看到下载队列、进度和错误，以便知道发生了什么。
34. 作为用户，我希望选择或查看下载目录，并删除已下载 Chapter，以便控制磁盘占用。
35. 作为用户，我希望下载任务在应用重启后仍然存在，以便继续下载。

### History、更新与 Tracking

36. 作为用户，我希望查看 History，以便回到读过的 Manga。
37. 作为用户，我希望设置 Library 更新计划并看到新 Chapter，以便不错过更新。
38. 作为用户，我希望把某些 Category 或 Source 排除在更新之外，以便减少噪音。
39. 作为用户，我希望在桌面允许的范围内看到新 Chapter 提示，以便注意到更新。
40. 作为用户，我希望连接 Fushi 实际支持的 tracker，以便发布阅读状态。
41. 作为用户，我希望在 Manga 详情页看到 Tracking 状态，以便知道是否已关联。

### Local source

42. 作为用户，我希望读取本地 CBZ/ZIP/文件夹，以便阅读自己的文件。
43. 作为用户，我希望 `.mokuro` 覆盖层可用于本地 Manga，以便继续使用已有的本地库。
44. 作为用户，我希望不包含端上 OCR/AI 生成，以便去掉不用的原生库和功能。

### Backup Import

45. 作为 Mihon 用户，我希望导入 Mihon v0.21.3 生成的 `.tachibk` Backup，以便迁移 Library、Category、Chapter、History、Reading progress、Tracking、Extension store 和 Source preferences。
46. 作为用户，我希望 Import 与现有 Library 合并并按 Manga/Source 去重，以便不丢数据。
47. 作为用户，我希望缺失的 Extension/Source 被标记为不可用并提示安装，以便修复后继续阅读。
48. 作为用户，我希望缺失的 tracker 被跳过并报告，而不是中止整个 Import，以便一个 tracker 不阻塞迁移。
49. 作为用户，我希望 Import 结束后看到汇总（成功/跳过/失败及原因），以便知道发生了什么。
50. 作为用户，我希望 Backup 文件只在本地处理、不上传，以便保护隐私。
51. 作为用户，我希望 Import 行为对齐 Mihon v0.21.3 的 restore 语义，以便结果符合预期。

### 设置、合规与数据

52. 作为用户，我希望有 Library、Reader、Download、Tracking、Backup 相关设置，以便配置应用。
53. 作为用户，我希望在 About 中看到版本、GPL-3.0 license 和第三方 notices，以便了解法律条款。
54. 作为用户，我希望应用不包含 telemetry、更新检查、云同步、AI 功能，以便简单且隐私友好。
55. 作为用户，我希望应用不内置、不托管任何 Extension store 或 Extension，以便自行选择来源。
56. 作为用户，我希望 my-comic 在 Extension、Backup、Manga 功能和数据映射四个轴上与 Mihon 兼容，以便知道能期待什么。
57. 作为用户，我希望源码以 GPL-3.0 公开并可修改，以便审计和二次开发。
58. 作为用户，我希望 my-comic 的 UI 与 Fushi v3.0.0 使用同一套设计和审美，以便获得我选择这个项目时的视觉体验；任何 UI 改动都要先得到我的允许。

## Implementation Decisions

- **代码基座**：使用 Fushi v3.0.0 的源码快照，保留 Flutter UI 和 JVM sidecar 扩展运行时；不跟随上游更新（ADR-0001、ADR-0003）。
- **UI fidelity（硬约束）**：保留 Fushi v3.0.0 的原版 shell、组件、主题、布局和视觉语言；只隐藏/移除非漫画入口，不得用自定义 shell 或重设计替换；任何 UI 改动必须先获得用户明确许可（ADR-0008）。
- **产品范围**：只保留漫画域。删除 EPUB/小说、视频/Aniyomi、有声书、词典/查词、Anki/SRS、galgame、AI/OCR、BT/发现、云同步/Interconnect、Fushi Server，以及阅读器内嵌的查词/Anki/统计入口（ADR-0002）。
- **数据库**：使用全新 schema，不迁移 Fushi 旧数据；只维护 my-comic 自己的迁移链（ADR-0002）。
- **领域模型**：Library、Manga、Chapter、Page、Category、Reading progress、History、Download、Tracking、Extension、Extension store、Source、Local source。术语以 `GLOSSARY.md` 为准。
- **Extension runtime**：保留 JVM sidecar 和 Android 兼容层；支持 Mihon extension-lib 1.6；兼容性以 Fushi v3.0.0 的行为为验收基准，不承诺超出 Fushi 的兼容范围（ADR-0006）。
- **Extension store**：由用户添加索引 URL；支持 Keiyoushi `index.pb`；不内置任何 store 或 Extension；签名 Trust 流程沿用 Fushi。
- **Backup Import**：在 JVM sidecar 中复用 Mihon 的 Apache-2.0 backup model 类解析 `.tachibk`；Import 采用 Merge 语义，按 Manga/Source 去重；缺失 Source 标记为不可用并提示安装；缺失 tracker 跳过并报告；生成结构化 Import 报告；不中止整个 Import（ADR-0005）。
- **Backup 语义**：Import 对齐 Mihon v0.21.3 的 restore 行为；不做设备间实时 Sync；Export 不在 v1 范围（ADR-0005）。
- **阅读器**：保留 Fushi 的漫画阅读器视觉与交互；删除查词/Anki/统计控件，接受相应 UI 变化（ADR-0002）。
- **删除顺序**：先删除非漫画 UI/路由/入口，再删除不用的原生库并验证漫画下载/阅读不依赖它们，最后切换到全新 DB schema 并删除未用表；每个阶段都要构建并手工验收。
- **原生库**：删除 libmpv、libtorrent、ONNX Runtime、ffmpeg 等非漫画依赖；保留图片解码、SQLite、JVM sidecar 和 Extension runtime 所需依赖。若漫画下载或阅读依赖某项，保留并记录原因。
- **下载**：只保留通过 Source HTTP 接口的 Chapter 下载；删除 BT/torrent 下载。
- **Local source**：保留 CBZ/ZIP/文件夹和 `.mokuro` 解析；删除端上 OCR/AI 生成。
- **Tracking**：使用 Fushi 实际支持的 provider；Mihon Backup 中无法映射的 tracker 跳过并报告；新增 tracker 属于后续工作。
- **平台**：Windows 10/11；Flutter Windows desktop + 随包 JVM sidecar；不要求用户运行服务器或创建账号。
- **打包**：单安装器、按用户安装；使用独立 applicationId、图标和产品名；不实现自动更新。
- **合规**：GPL-3.0、公开源码、保留 Fushi 和第三方组件 notices；README/About 明确写明“基于 Fushi v3.0.0”；不使用 Mihon 的名称、logo 或 applicationId；不内置/不托管 Extension（ADR-0004）。
- **仓库**：`Myyuluo/my-comic` 新仓库快照，`UPSTREAM.md` 记录 Fushi v3.0.0；不推送 Fushi 完整历史；必要时使用 Git LFS。
- **数据与隐私**：用户 Backup 只在本地处理，不提交到仓库、不上传；不包含 telemetry、更新检查、云同步、AI 功能。

## Testing Decisions

- **好测试**：只验证外部行为（输入 `.tachibk` 或 Extension 操作，返回领域结果/错误），不断言内部实现细节。
- **主 seam**：Sidecar HTTP API（Flutter ↔ JVM sidecar）。覆盖 Extension 安装/运行和 Backup Import 两个核心风险；这是 Fushi 已有的 seam，不新增。
- **被测模块**：sidecar 的 Backup Import 解析与报告、Extension runtime adapter、Import 去重与缺失 Source/Tracker 处理。
- **测试数据**：真实 Mihon v0.21.3 `.tachibk`（脱敏后用于本地测试，不入库）、Keiyoushi `index.pb`、一个真实 Extension JAR。仓库内使用脱敏/合成 fixture。
- **UI 验收**：Library、Browse/Sources、Reader、Settings/Backup Import 用人工验收清单；v1 不新增 Flutter widget/integration seam。任何 UI 改动必须与 Fushi v3.0.0 截图/组件对照，并在用户明确批准后才合并；ticket 11 的 `home_shell.dart` 替换是反例，恢复见 ticket 16。
- **发布冒烟**：启动 Windows exe → 添加 Keiyoushi → 安装一个 Extension → 搜索/阅读 → 导入 Backup；作为发布门，不是常驻测试。
- **Prior art**：Fushi 现有 Dart widget/integration 测试与 sidecar 测试；Mihon v0.21.3 的 backup model/restore 行为作为语义参照。
- **必须失败的场景**：Import 丢失 Library/Category/Reading progress；缺失 Source 中止 Import；缺失 Tracker 中止 Import；Extension 安装/运行相对 Fushi v3.0.0 回归。

## Out of Scope

- Backup Export（v1.5）。
- 手机与 PC 的实时 Sync；任何设备间通信。
- 非漫画域：EPUB/小说、视频/Aniyomi、有声书、词典/查词、Anki/SRS、galgame、AI/OCR、BT/torrent、云同步/Interconnect、Fushi Server。
- 超出 Fushi v3.0.0 的 Extension 兼容性修复。
- Fushi 不支持的 tracker；新增 tracker provider。
- 跟随 Fushi/Mihon 上游更新；应用自动更新。
- macOS/Linux 发行版；v1 只做 Windows。
- 代码签名、GitHub Actions CI、自动发布流水线。
- Fushi 旧数据迁移（`.fushi.zip` / 旧 DB）。
- 内置或托管 Extension store / Extension。
- Android/手机版本。

## Further Notes

- 真实 `.tachibk` 位于项目目录，只用于本地测试；必须加入 `.gitignore`，不读取进上下文、不提交、不上传。
- 兼容目标：Mihon v0.21.3、extension-lib 1.6、Keiyoushi `index.pb`。
- 参考文档：`GLOSSARY.md`、`docs/adr/0001`–`0008`、`docs/agents/domain.md`。
- 实现前先完成 M0：在 Windows 上从源码构建并运行 Fushi v3.0.0，记录基线体积；未完成 M0 不开始删除模块。
- GPL 合规：发布二进制时同时提供对应源码；保留 Fushi 和第三方 notices。
