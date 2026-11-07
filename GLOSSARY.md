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
内容站点或来源，是搜索、详情、章节和页面的实际提供者，通常由 Extension 提供。图源列表也包含不由 Extension 提供的内置伪源，例如「本地图源」；这类源不进入扩展源枚举。
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
从 Library、在线 Source 或「本地图源」点击一部 Manga 后打开的详情页；左栏展示封面、书名、作者与状态 chip，并提供章节列表与阅读入口。书名与作者可点击，以当前显示的文字去「Manga 全局搜索」检索全部已启用的在线 Source。
_Avoid_: 详情页（与小说 / 视频作品页混淆时）、书页

**Manga 全局搜索（搜索全部来源）**:
在全部已启用的在线 Source 中按关键词执行搜索的页面；Source 自身与提供它的 Extension 都启用才参与搜索。从 Manga 作品页点击书名或作者会带着该关键词进入并自动执行搜索。本地图源不是在线 Source，不参与该搜索。
_Avoid_: 聚合搜索、全源搜索（口语；正式术语用本名）

**Chapter（章节）**:
Manga 的一个章节，包含一组 Page。
_Avoid_: 话

**Chapter container（章节载体）**:
Chapter 的磁盘形态：平铺页图的文件夹，或包含页图的 CBZ 压缩包。在线下载默认生成 CBZ；既有文件夹章节继续以文件夹存在，两种形态共存。
_Avoid_: 章节文件夹（只指一种）、压缩包（泛指）

**Page（页）**:
Chapter 中的一页图片。
_Avoid_: 图片

**Library（书架）**:
用户保存的 Manga 集合。
_Avoid_: 收藏、书库

**Remove from Library（移出书架）**:
把 Manga 从 Library 移除。Local source 的 Manga 移出后不删除磁盘文件；在线 Manga 可另行选择是否删除已下载文件。
_Avoid_: 删除（删除文件是另一个动作）

**Add to Library（加入书架）**:
把一部在「本地图源」里扫描到但尚未入库的 Manga 显式登记进 Library 的动作；点开该作品某一章阅读时也会先静默执行同一登记。已移出书架但文件仍在的本地 Manga 可由此重新加入。
_Avoid_: 导入（批量导入已退役）、自动入库

**Category（分类）**:
Mihon 备份中的 Library 内用户自定义分组。仅为 Mihon 备份兼容而保留；my-comic v1 已无分类 UI，书架不再按分类分组。
_Avoid_: 标签、文件夹、视图页签

**Tag（标签）**:
Library 条目的用户自定义标记，存放在 `book_tags` 标签池及条目映射中，以书架顶部的筛选 chips 呈现（点选筛选、长按拖动排序）。
_Avoid_: 分类、合集、文件夹

**View tab（视图页签）**:
页面顶部用来切换平级视图的页签（例如浏览页的「图源 / 发现」；「导入」子视图已移除）。它属于页面内部切换项，不是一级导航项——「下载」是一级导航页（见「下载页」），不是视图页签。漫画页只剩书架一个视图后不再显示视图页签，Tag chips 占据该位置。
_Avoid_: 子标签、标签页、分类页签

**下载页（Downloads page）**:
一级导航中的「下载」页，位于「浏览」之后、「设置」之前。标题使用与浏览页一致的页内浮动标题胶囊（向下滚动收起、向上滚动或回到顶部重新显示），不显示视图页签；内容为漫画章节下载任务列表与空态提示。任务行不显示来源标签、不可展开、整行不可点；排队中/下载中的任务在行尾直接取消，失败/已取消的在行尾直接重试，已完成的不显示行尾操作。它不是「视图页签」，也不绑定任何功能模块。
_Avoid_: 下载视图、下载页签、子标签

**Reading progress（阅读进度）**:
某部 Manga 最后阅读到的 Chapter/Page。
_Avoid_: 书签、位置

**History（历史）**:
用户阅读 Manga 的时间记录。
_Avoid_: 记录

**Incognito reading（无痕阅读）**:
「设置 → 系统与关于 → 更新提醒」里的设备本地开关，默认关闭。开启后阅读仍保留 Reading progress（下次能接着读，「继续阅读」指向当前 Chapter），但不新增 History 的可见信号（书架「最近阅读」排序与继续阅读 hero、Chapter 已读标记、完成标记）；已有 History 保留，Tracking 与统计照常。开关不随 Profile / Backup 同步，换设备按新设备的选择。
_Avoid_: 隐身模式、隐私浏览、无痕模式（浏览器同名词会让人误以为会清除已有记录）

**Download（下载）**:
通过 Source 的 HTTP 接口把 Chapter 的 Page 保存到本地。
_Avoid_: 缓存、BT 下载

**Save as CBZ（保存为CBZ压缩包）**:
「设置 → 存储与下载 → 下载」里的开关，默认开启。开启时新开始的在线 Chapter 下载保存为 `.cbz` 压缩包，关闭时保存为文件夹；只影响任务开始运行时的新下载，运行中的任务与已有章节保持原形态。
_Avoid_: 批量转换、自动压缩、打包下载

**Download library（在线下载库）**:
由应用管理的已下载在线 Chapter 集合，按 Source → Manga → Chapter 组织在 Content root 下。新开始的下载默认把 Chapter 保存为 `.cbz` 压缩包（见 Save as CBZ）；已有的文件夹章节保持原样，两种 Chapter container 共存。
_Avoid_: 下载文件夹、下载目录（与「下载页」混淆）

**Download index（下载索引）**:
Library 中的 Manga/Chapter 与磁盘上已下载文件及其状态之间的映射。
_Avoid_: 漫画索引、书库、缓存

**Rebuild download index（重建下载索引）**:
用户触发的恢复扫描：从 Content root 重建 Download index，补建缺失的 Library 条目并更新下载状态；只增改、不删记录或文件。
_Avoid_: 导入、恢复备份、同步

**Not downloaded（未下载）**:
下载状态：该 Chapter 从未下载到本地。
_Avoid_: 文件缺失

**Missing（文件缺失）**:
下载状态：Download index 认为该 Chapter 已下载，但文件在预期位置不存在。
_Avoid_: 未下载

**Unindexed（未索引）**:
磁盘上存在 Chapter 内容，但还没有对应的 Library/Download index 条目。
_Avoid_: 未下载、孤儿

**Tracking（追踪）**:
把阅读状态发布到外部服务（Bangumi、MAL、AniList、Kitsu、Shikimori 等）。
_Avoid_: 同步

**Backup（备份）**:
Mihon 或 my-comic 生成的 `.tachibk` 快照。
_Avoid_: 存档、导出文件、应用快照（`.fushi.zip` 是另一种东西）

**App snapshot（应用快照）**:
my-comic 旧版生成的 `.fushi.zip` 全量应用导出；不是 Backup，计划弃用。
_Avoid_: 备份、Backup、导出

**Backup directory（备份目录）**:
Content root 下存放 Backup 的目录；my-comic 的目录名是 `autobackup`，也是导入/导出 `.tachibk` 的默认位置。
_Avoid_: 自动备份、应用快照

**Automatic backup（自动备份）**:
无需用户操作、按计划生成 Backup 的任务；v1 不实现。
_Avoid_: 备份目录、autobackup（那是目录名）

**Import（导入）**:
把 Backup 读入 my-comic 的 Library。
_Avoid_: 恢复（除非特指 Mihon 的 restore 行为）、同步

**Export（导出）**:
从 my-comic 生成 Backup，供 Mihon 读取。
_Avoid_: 同步、上传

**Sync（同步）**:
设备之间的实时数据交换。本项目明确不做。
_Avoid_: 追踪、导入

**Local source（本地图源）**:
图源列表第一位的内置伪源，从 Local source root 原地读取 Manga 与 Chapter；不由 Extension 提供，也不走扩展的启用与安装检查。进入「本地图源」时自动扫描并展示封面网格，只展示、不自动登记；用户对单部作品执行 Add to Library 才进入 Library。它不参与 Manga 全局搜索、发现页来源磁贴或热门行。`.mokuro` 覆盖层属于本地图源。
_Avoid_: 本地文件、离线模式、本地源

**Local source root（本地图源根）**:
承载 Local source 的目录；用户把 Manga/Chapter 文件夹或 CBZ 放在这里，my-comic 原地读取、不复制。扫描时机只有两种：进入「本地图源」时自动扫描，或运行 Rebuild download index。
_Avoid_: 本地库、离线库

**OCR**:
在设备上从图片识别文字。本项目不包含端上 OCR/AI 生成。
_Avoid_: 本地图源

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
本项目在四个轴上的兼容承诺：Extension、Backup、Manga 功能、数据映射。它不表示 UI 与 Mihon 相同，也不表示代码是 Mihon 的移植，也不表示 Storage layout 可由 Mihon 直接读取；见 Mihon-style layout。
_Avoid_: Mihon 移植、Mihon 分支

**Mihon-style layout（Mihon 风格布局）**:
沿用 Mihon 的 Source → Manga → Chapter 目录习惯的布局；只表示目录形状，不承诺 Mihon 能读取。
_Avoid_: Mihon 兼容、数据结构统一

**Mihon local-source layout（Mihon 本地源布局）**:
按 Mihon 本地源的习惯组织 Local source root（章节文件夹平铺图片或 `.cbz`）；不承诺跨设备拷贝后 Mihon 能直接扫描。
_Avoid_: Mihon 本地源兼容

**Extension compatibility（扩展兼容）**:
my-comic 的扩展行为以 Fushi v3.0.0 为基准：Fushi 能安装/运行的 Extension，my-comic 也必须能；不承诺超出 Fushi 的兼容范围。
_Avoid_: 全扩展兼容、100% 插件支持

**Snapshot（快照）**:
锁定在 Fushi v3.0.0 的代码基线；不包含上游后续提交。
_Avoid_: 分支、fork、应用快照（那是 `.fushi.zip`）

### Storage and portability

**Content root（内容根）**:
用户可见的漫画内容根，包含 Download library、Backup 文件与 Local source；卸载应用不会删除它。设置里的 UI 文案为「存储位置」。
_Avoid_: 数据根、数据目录、数据存储位置（未限定是哪一类时）

**Program state root（程序状态根）**:
随程序目录存放应用状态的根：数据库、设置、扩展、字体、WebView 数据和缓存；卸载应用会删除它。
_Avoid_: 用户数据、appdata、%APPDATA%

**Content root switch（切换内容根）**:
把 Content root 改到另一个目录的操作；只创建新的空目录，不搬移旧文件；旧路径下的下载变为 Missing，直到用户搬移文件并运行 Rebuild download index。
_Avoid_: 数据迁移、搬移（暗示自动移动文件）

**Portable state（便携状态）**:
把程序目录连同 Program state root 一起拷贝到另一台机器后仍保留 Library、设置和扩展的状态；不包含 Content root，也不是 Backup。
_Avoid_: 便携版（发行物）、备份

**Portable build（便携版）**:
不经过 Windows 安装器、以 ZIP 分发的程序形态；v1 不发行，只作为未来发行物。
_Avoid_: 便携状态（这是数据属性）、绿色版
