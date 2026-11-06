# my-comic

一个 Windows 桌面漫画阅读器：以 Fushi v3.0.0 的代码快照为基础，只保留漫画域，并在扩展与备份数据上与 Mihon v0.21.3 兼容。

## Language

**my-comic**:
本项目的产品名与代码库名。它是独立发行版，不是 Fushi 的官方分支。
_Avoid_: Fushi、Mihon（指本产品时）

**Fushi**:
本项目的上游代码基座，锁定在 v3.0.0 快照。只作为来源与历史背景使用，不跟随其后续更新。
_Avoid_: 当前应用、我们的应用

**Mihon**:
Android 漫画阅读器，是本项目的扩展与备份兼容目标（v0.21.3）。
_Avoid_: Tachiyomi（历史前身，除非讨论历史格式）

**Extension（扩展）**:
一个可安装的 APK/JAR 包，提供一个或多个 Source。
_Avoid_: 插件、addon

**Source（源）**:
由 Extension 提供的一个内容站点或来源，是搜索、详情、章节和页面的实际提供者。
_Avoid_: 扩展、插件

**Extension store（扩展仓库）**:
Extension 的索引，例如 Keiyoushi 的 `index.pb`。它列出可安装的 Extension，本身不是 Source。
_Avoid_: 插件仓库、repo（容易与 Git 仓库混淆）

**Signer（签名者）**:
Extension 的签名身份，以证书指纹标识；一个 Signer 可以被用户标记为 trusted 或 untrusted。
_Avoid_: 签名者指纹、证书

**Trust（信任）**:
用户对某个 Signer 的明确接受记录；从未 trusted 的 Signer 安装 Extension 需要先确认。
_Avoid_: 授权、白名单

**Manga（漫画）**:
书架中的一部作品，是 Library、Category、Reading progress 和 Tracking 的归属对象。
_Avoid_: 条目、书籍

**Manga 作品页（Manga series page）**:
从 Library 或在线 Source 点击一部 Manga 后打开的详情页；左栏展示封面、书名、作者与状态 chip，并提供章节列表与阅读入口。书名与作者可点击，以当前显示的文字去「Manga 全局搜索」检索全部已启用的在线 Source。
_Avoid_: 详情页（与小说 / 视频作品页混淆时）、书页

**Manga 全局搜索（搜索全部来源）**:
在全部已启用的在线 Source 中按关键词执行搜索的页面；Source 自身与提供它的 Extension 都启用才参与搜索。从 Manga 作品页点击书名或作者会带着该关键词进入并自动执行搜索。
_Avoid_: 聚合搜索、全源搜索（口语；正式术语用本名）

**Chapter（章节）**:
Manga 的一个章节，包含一组 Page。
_Avoid_: 话

**Page（页）**:
Chapter 中的一页图片。
_Avoid_: 图片

**Library（书架）**:
用户保存的 Manga 集合。
_Avoid_: 收藏、书库

**Category（分类）**:
Mihon 备份中的 Library 内用户自定义分组。仅为 Mihon 备份兼容而保留；my-comic v1 已无分类 UI，书架不再按分类分组。
_Avoid_: 标签、文件夹、视图页签

**Tag（标签）**:
Library 条目的用户自定义标记，存放在 `book_tags` 标签池及条目映射中，以书架顶部的筛选 chips 呈现（点选筛选、长按拖动排序）。
_Avoid_: 分类、合集、文件夹

**View tab（视图页签）**:
页面顶部用来切换平级视图的页签（例如浏览页的「在线源 / 发现 / 导入」）。它属于页面内部切换项，不是一级导航项——「下载」是一级导航页（见「下载页」），不是视图页签。漫画页只剩书架一个视图后不再显示视图页签，Tag chips 占据该位置。
_Avoid_: 子标签、标签页、分类页签

**下载页（Downloads page）**:
一级导航中的「下载」页，位于「浏览」之后、「设置」之前。顶部只有固定展开、不随滚动收起的标题，内容为漫画章节下载任务列表与空态提示；它不是「视图页签」，也不绑定任何功能模块。
_Avoid_: 下载视图、下载页签、子标签

**Reading progress（阅读进度）**:
某部 Manga 最后阅读到的 Chapter/Page。
_Avoid_: 书签、位置

**History（历史）**:
用户阅读 Manga 的时间记录。
_Avoid_: 记录

**Download（下载）**:
通过 Source 的 HTTP 接口把 Chapter 的 Page 保存到本地。
_Avoid_: 缓存、BT 下载

**Tracking（追踪）**:
把阅读状态发布到外部服务（Bangumi、MAL、AniList、Kitsu、Shikimori 等）。
_Avoid_: 同步

**Backup（备份）**:
Mihon 或 my-comic 生成的 `.tachibk` 快照。
_Avoid_: 存档、导出文件

**Import（导入）**:
把 Backup 读入 my-comic 的 Library。
_Avoid_: 恢复（除非特指 Mihon 的 restore 行为）、同步

**Export（导出）**:
从 my-comic 生成 Backup，供 Mihon 读取。
_Avoid_: 同步、上传

**Sync（同步）**:
设备之间的实时数据交换。本项目明确不做。
_Avoid_: 追踪、导入

**Local source（本地源）**:
从本地 CBZ/ZIP/文件夹读取 Manga；`.mokuro` 覆盖层属于本地源。
_Avoid_: 本地文件、离线模式

**OCR**:
在设备上从图片识别文字。本项目不包含端上 OCR/AI 生成。
_Avoid_: 本地源

**Sidecar（伴生进程）**:
随应用启动的 JVM 进程，负责运行 Extension 和解析/生成 Backup。
_Avoid_: 服务器、后端（避免暗示需要用户自建服务器）

**Extension runtime（扩展运行时）**:
Sidecar 加上 Android 兼容层，用于执行 Mihon Extension。
_Avoid_: 插件引擎

**Bundled extension runtime（随包扩展运行时）**:
随应用构建或安装包分发的 Extension runtime 副本；my-comic 只启动这一份，不从系统或其他安装目录查找运行时。
_Avoid_: 外部运行时、系统 Java

**Mihon-compatible**:
本项目在四个轴上的兼容承诺：Extension、Backup、Manga 功能、数据映射。它不表示 UI 与 Mihon 相同，也不表示代码是 Mihon 的移植。
_Avoid_: Mihon 移植、Mihon 分支

**Extension compatibility（扩展兼容）**:
my-comic 的扩展行为以 Fushi v3.0.0 为基准：Fushi 能安装/运行的 Extension，my-comic 也必须能；不承诺超出 Fushi 的兼容范围。
_Avoid_: 全扩展兼容、100% 插件支持

**Snapshot（快照）**:
锁定在 Fushi v3.0.0 的代码基线；不包含上游后续提交。
_Avoid_: 分支、fork
