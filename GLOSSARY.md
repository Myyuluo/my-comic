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

**Missing source（缺失来源）**:
被一部 Manga 引用、但对应 Source 未安装或未启用的状态。该 Manga 记录仍保留（在书架或作为非书架 Manga）；备份带来的远程封面与本机已有封面仍可显示，已下载 Chapter 仍可离线阅读，但刷新章节、加载在线页面与下载需要先安装并启用对应 Extension。用户界面统一用「来源未安装」表达此状态，已知名称时显示「来源未安装：<名称>」。运行时按数字 sourceId 解析到已安装的 Source，不改写条目的来源身份，因此 Reading progress、Chapter 状态、History、Tag 与下载映射都无需迁移；同一数字 sourceId 命中多个已启用的 Source 时按缺失处理，不随意选择。
_Avoid_: mihon.unavailable（内部占位值，不是领域术语）、来源失效、未知来源

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
一部漫画作品在应用中的持久记录，可以属于 Library，也可以是非书架 Manga；Chapter、Reading progress、History、下载与 Tracking 都归属于它。
_Avoid_: 条目、书籍

**Manga 作品页（Manga series page）**:
从 Library、在线 Source 或「本地图源」点击一部 Manga 后打开的详情页；左栏展示封面、书名、作者、状态 chip 与全部源分类，并提供章节列表与阅读入口。书名、作者与源分类都可点击，以当前显示的文字去「Manga 全局搜索」检索全部已启用的在线 Source。
_Avoid_: 详情页（与小说 / 视频作品页混淆时）、书页

**Manga 全局搜索（搜索全部来源）**:
在全部已启用的在线 Source 中按关键词执行搜索的页面；Source 自身与提供它的 Extension 都启用才参与搜索。从 Manga 作品页点击书名、作者或源分类会带着该关键词进入并自动执行搜索。本地图源不是在线 Source，不参与该搜索。
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
用户主动保存的 Manga 集合；集合成员由 Library membership 决定。
_Avoid_: 收藏、书库

**Library membership（书架归属）**:
一个 Manga 是否属于 Library 的状态。书架页、Home 继续阅读、Tag 页签与计数、订阅与自动追更、更新探测以及备份的「书架中的作品」只使用书架成员；阅读器、Chapter 状态、History、下载与下载索引使用全部 Manga。加入或移出书架只改变这个状态，不重建 Manga 记录。
_Avoid_: 入库、收藏状态

**Remove from Library（移出书架）**:
把 Manga 从 Library 移除的动作，默认非破坏：只清除 Library membership、Tag 分配与订阅/自动追更，保留 Manga/Chapter 记录、Reading progress、Chapter 已读标记、已下载文件与 Download index、History；之后重新加入复用同一条记录与同一个下载文件夹。确认弹窗中的「同时删除本地文件」默认不勾选：在线 Manga 勾选时删除已下载文件与下载索引，但保留非书架记录与阅读状态，之后可重新下载；本地作品（Local source 或应用管理的本地卷）勾选时删除本地文件，并连记录与阅读状态一起删除（History 仍保留）。文件删除失败时该 Manga 仍留在 Library。「同时删除统计数据」仍只在用户显式勾选时移除该作品的 Reading statistics。
_Avoid_: 删除（删除文件是另一个动作）

**Add to Library（加入书架）**:
把 Manga 变为 Library 成员的动作。已有非书架记录时只翻转同一条记录的 Library membership，不新建记录，作品身份、阅读状态、已下载文件与 History 原样保留；尚不存在记录时创建书架记录。在线作品从作品页执行；Local source 作品从作品页或本地图源页的选择模式显式执行，点开本地作品章节阅读时也会静默执行同一登记。加入时仍可选择 Tag。
_Avoid_: 导入（批量导入已退役）、自动入库

**Non-library Manga（非书架漫画）**:
持久化但不属于 Library 的 Manga。打开在线源作品或阅读章节时会创建/复用，导入未收藏的作品也会创建；可阅读、保存进度、标记已读、下载与写 History，但不进入书架、Home 继续阅读、Tag 页签与计数、更新探测、订阅/自动追更或备份的「书架中的作品」，也不能分配 Tag、订阅或使用 Tracking。其下载任务出现在下载页。
_Avoid_: Non-library work、未入书架作品（旧称）、未收藏、临时作品

**Category（分类）**:
Mihon 备份中的 Library 内用户自定义分组，与 my-comic 的 Tag 双向映射：导出时每个 Tag 成为同名 Category，导入时每个 Category 按名称成为 Tag（同名合并）。Mihon 的 Default（不属于任何 Category）对应 my-comic 的「书架」页签。my-comic 不提供分类 UI，书架不按分类分组。
_Avoid_: 标签、文件夹、视图页签

**Tag（标签）**:
Library 条目的用户自定义标记。漫画页把它呈现为标签栏中的单选页签，标签栏是「漫画」标题下方的二级浮动胶囊行；每项显示当前搜索与筛选条件下的漫画数量，数量用更轻的次要色小号数字呈现；不再是彩色多选 chip，页签栏内也不提供长按拖拽排序（顺序仍在标签管理页调整）。每个 Tag 在 Backup 中导出为同名 Mihon Category，导入 Mihon 备份时同名 Category 恢复为 Tag；Tag 颜色不进入 Backup。
_Avoid_: 分类、合集、文件夹

**书架页签（Library tab）**:
漫画页标签栏的第一项，也是默认页签；它固定在这行二级浮动胶囊的最左端。只收没有任何用户 Tag 的 Manga；有标签的 Manga 不会出现在这里，只出现在对应的标签页签下（多标签 Manga 在每个对应标签里都出现）。页签数量反映当前搜索与筛选条件下该页签会显示的 Manga 数，始终显示（包括 0），同样用更轻的次要色小号数字呈现。
_Avoid_: 全部页签、未分类、默认分类

**源分类（Source genre）**:
Source 为 Manga 提供的分类标签，显示在 Manga 作品页上；它由 Source 给出，不是用户的 Tag。作品页有多少就显示多少，每一枚都可点击，点击以该分类名为关键词进入 Manga 全局搜索。
_Avoid_: 标签、用户标签、分类（未指明来源时）

**View tab（视图页签）**:
页面顶部用来切换平级视图的页签（例如浏览页的「图源 / 发现」；「导入」子视图已移除）。它属于页面内部切换项，不是一级导航项——「下载」是一级导航页（见「下载页」），不是视图页签。漫画页只剩书架一个视图后不再显示视图页签，顶部 chrome 行现在是继续阅读胶囊（见「继续阅读胶囊」），标签栏则在「漫画」标题下方的二级浮动行。
_Avoid_: 子标签、标签页、分类页签

**继续阅读胶囊（Continue reading pill）**:
漫画页顶部 chrome 行里的紧凑继续阅读入口：圆形封面、主色「继续阅读」文字与主色圆形播放钮，不显示书名与进度；悬停时以 tooltip 显示书名。整颗胶囊可点击并打开当前的继续阅读作品；没有继续阅读条目时不显示。它取代了旧布局里网格顶部的继续阅读大卡片。
_Avoid_: 继续阅读大卡片、继续阅读 hero（旧布局的网格顶部大卡片）

**下载页（Downloads page）**:
一级导航中的「下载」页，位于「浏览」之后、「设置」之前。标题使用与浏览页一致的页内浮动标题胶囊（向下滚动收起、向上滚动或回到顶部重新显示），不显示视图页签。内容只列可操作任务：排队中、下载中、暂停与失败；已完成的任务不再显示（文件保留、仍可阅读），取消的任务直接移除，失败的任务保留并同时提供「重试」与「取消」。下载任务同时包含书架与非书架 Manga。任务行不显示来源标签、不可展开、整行不可点；排队中 / 下载中 / 暂停 / 失败的任务在行尾可直接取消。右下角有全局「全部暂停 / 全部继续」气泡胶囊按钮，暂停与继续只由它控制：列表为空时隐藏，全部任务都是暂停或失败时显示「全部继续」，否则显示「全部暂停」。它不是「视图页签」，也不绑定任何功能模块。
_Avoid_: 下载视图、下载页签、子标签

**Reading progress（阅读进度）**:
某部 Manga 最后阅读到的 Chapter/Page。
_Avoid_: 书签、位置

**History（历史）**:
用户阅读 Manga 的会话记录，按 Manga 去重，每部一条，记录最近一次打开 Chapter 的时间；由「历史」页直接展示。书架与非书架 Manga 都会写入；历史卡片优先显示当前标题与本地封面，匹配不到时回退到导入快照，绝不显示内部作品标识。History 不设条数上限，写入新作品不会裁剪更早的记录。History 与 Reading progress 相互独立：删除 History 不会清除续读位置或 Chapter 已读标记。无痕阅读期间不新增、不更新 History。
_Avoid_: 记录、阅读记录（可能指 Reading progress）

**Reading statistics（阅读统计）**:
统计中心「阅读」页所展示的阅读活动汇总：阅读时长、页数、阅读速度与会话等，以及查词/制卡计数。它按作品与时间范围聚合，与 History、Reading progress 是三套独立数据：History 记录每部 Manga 最近一次阅读会话，Reading progress 记录续读位置；删除阅读统计不会删除 History 或 Reading progress，移出书架时也只有显式勾选「同时删除统计数据」才会移除该作品的统计。非书架 Manga 的阅读同样计入。
_Avoid_: 历史、阅读进度（它们是独立的数据；阅读统计不是阅读会话记录）

**Incognito reading（无痕阅读）**:
「设置 → 系统与关于 → 更新提醒」里的设备本地开关，默认关闭。开启后阅读仍保留 Reading progress（下次能接着读，「继续阅读」指向当前 Chapter），但不新增或更新 History 条目，也不自动新增或推进书架「最近阅读」排序、不自动写入 Chapter 已读标记与完成标记；已有 History 保留，手动标记已读/未读不受影响，Tracking 与统计照常。开关不随 Profile / Backup 同步，换设备按新设备的选择。
_Avoid_: 隐身模式、隐私浏览、无痕模式（浏览器同名词会让人误以为会清除已有记录）

**Download（下载）**:
通过 Source 的 HTTP 接口把 Chapter 的 Page 保存到本地。
_Avoid_: 缓存、BT 下载

**暂停（Paused）**:
下载任务的一种非终态状态：任务停止继续取页，但已下载的部分保留，恢复后接着下载。只能通过下载页的全局「全部暂停」产生；暂停期间新入队的章节也以暂停状态等待。
_Avoid_: 取消（取消会删除任务与未完成的部分）、停止

**Save as CBZ（保存为CBZ压缩包）**:
「设置 → 存储与下载 → 下载」里的开关，默认开启。开启时新开始的在线 Chapter 下载保存为 `.cbz` 压缩包，关闭时保存为文件夹；只影响任务开始运行时的新下载，运行中的任务与已有章节保持原形态。
_Avoid_: 批量转换、自动压缩、打包下载

**Download library（在线下载库）**:
由应用管理的已下载在线 Chapter 集合，按 Source → Manga → Chapter 组织在 Content root 下。新开始的下载默认把 Chapter 保存为 `.cbz` 压缩包（见 Save as CBZ）；已有的文件夹章节保持原样，两种 Chapter container 共存。书架与非书架 Manga 共用同一套 Download library 与 Download index。
_Avoid_: 下载文件夹、下载目录（与「下载页」混淆）

**Download identity（下载身份）**:
在线 Manga 在 Download library 中的稳定身份，由运行时、数字 Source ID 与 series/manga key 组成；扩展包名只作 tie-breaker。文件夹复用、已下载状态与 Rebuild download index 都使用这一判据，目录名不参与。
_Avoid_: 标题匹配、文件夹名身份

**Download index（下载索引）**:
Manga/Chapter 与磁盘上已下载文件及其状态之间的映射，覆盖书架与非书架 Manga。
_Avoid_: 漫画索引、书库、缓存

**Rebuild download index（重建下载索引）**:
用户触发的恢复扫描：扫描当前 Content root 的 Download library 与 Local source root，按 Download identity 把文件关联到已有 Manga（含非书架；身份不足时按文件名回退），并为未索引内容补建条目。多个目录都能证明同一身份时不猜，优先已记录目录或唯一最新完整副本，否则跳过并在报告中说明；只增改，不删除或重命名文件与映射。
_Avoid_: 导入、恢复备份、同步

**Not downloaded（未下载）**:
下载状态：该 Chapter 从未下载到本地。
_Avoid_: 文件缺失

**Missing（文件缺失）**:
下载状态：Download index 认为该 Chapter 已下载，但文件在预期位置不存在。
_Avoid_: 未下载

**Unindexed（未索引）**:
磁盘上存在 Chapter 内容，但还没有对应的 Manga/Download index 条目。
_Avoid_: 未下载、孤儿

**Cache（缓存）**:
应用为了加速在线源与阅读会话而保留的可再生临时数据，例如封面与页面图片、网页响应、压缩包解包临时文件。缓存不是 Download，也不包含 Local source 的用户文件；清除缓存不改变 History、Reading progress 或 Download library。
_Avoid_: 下载、离线文件、书库

**Clear cache（清除缓存）**:
「设置 → 存储与下载 → 数据存储位置」里的动作：清理应用管理的 Cache，并在行内显示当前磁盘占用（含图片管理器磁盘缓存与 WebView 的安全 HTTP cache 子目录）。它保留图源登录态、数据库、History、Reading progress、Download library 与 Local source 文件。WebView/HTTP 缓存清理只在 Windows（WebView2）上可用；其它平台跳过该部分并在结果中提示部分成功。
_Avoid_: 清理下载、重置应用

**Clear database（清理数据库）**:
「设置 → 存储与下载 → 数据存储位置」里的动作，按 Mihon 的 Clear database 语义：列出有非书架 Manga 的 Source 及数量供多选，默认保留有已读章节或阅读进度的作品；删除所选 Source 的非书架 Manga 记录及其章节、阅读进度、已读、下载索引与被清理作品的 History，并清理无归属的阅读状态。保留书架作品与其 History、下载文件、Local source 文件、设置、源、扩展与 Tracking 数据；它不等同于恢复出厂设置。
_Avoid_: 清除数据库（旧称）、恢复出厂设置、重置应用、清除缓存

**Tracking（追踪）**:
把阅读状态发布到外部服务（Bangumi、MAL、AniList、Kitsu、Shikimori 等）。
_Avoid_: 同步

**Backup（备份）**:
Mihon 或 my-comic 生成的 `.tachibk` 快照。my-comic 可在「创建备份」页按所选范围生成 Backup，供 Mihon 或另一台 my-comic 导入。
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
把 Backup 读入 my-comic：恢复 Library 与阅读数据，并补齐本机缺失的 my-comic 设置。Merge 语义，按 Manga 与 Source 去重；未收藏的作品会恢复为非书架 Manga（含章节、阅读进度、已读与可恢复的 History），绝不进入 Library。导入后会尝试把已下载文件与可识别身份的本地文件关联到导入作品，不额外创建 Library 条目；「重建下载索引」仍是手动全量扫描。
_Avoid_: 恢复（除非特指 Mihon 的 restore 行为）、同步

**Export（导出）**:
从 my-comic 生成 Backup 的动作：在「创建备份」页选择导出范围后写出 `.tachibk`，产物可由 Mihon 读取，也可由 my-comic 重新导入。「书架中的作品」只包含书架成员；「所有已读作品」把未加入书架的已读作品写成 `favorite=false` 条目。
_Avoid_: 同步、上传

**Sync（同步）**:
设备之间的实时数据交换。本项目明确不做。
_Avoid_: 追踪、导入

**Local source（本地图源）**:
图源列表第一位的内置伪源，从 Local source root 原地读取 Manga 与 Chapter；不由 Extension 提供，也不走扩展的启用与安装检查。进入「本地图源」时自动扫描并展示封面网格，只展示、不自动登记；用户对单部作品（作品页）或多部作品（本地图源页的选择模式）显式执行 Add to Library 才进入 Library。它不参与 Manga 全局搜索、发现页来源磁贴或热门行。`.mokuro` 覆盖层属于本地图源。
_Avoid_: 本地文件、离线模式、本地源

**Local source root（本地图源根）**:
承载 Local source 的目录，即 Content root 下的 `local`；用户把 Manga/Chapter 文件夹或 CBZ 放在这里，my-comic 原地读取、不复制。扫描时机只有两种：进入「本地图源」时自动扫描，或运行 Rebuild download index。旧目录名 `localcomic` 已停用，不扫描、不迁移、不删除。作品根目录缺少封面时，扫描会从第一页生成可见的 `cover.jpg`；已有封面绝不覆盖，也不写隐藏元数据。
_Avoid_: 本地库、离线库、localcomic（旧目录名）

**OCR**:
在设备上从图片识别文字。本项目不包含端上 OCR/AI 生成。
_Avoid_: 本地图源

**Sidecar（伴生进程）**:
随应用启动的 JVM 进程，负责运行 Extension。Backup 的解析与生成由 my-comic 自身完成。
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
