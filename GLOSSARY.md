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

**Manga（漫画）**:
书架中的一部作品，是 Library、Category、Reading progress 和 Tracking 的归属对象。
_Avoid_: 条目、书籍

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
Library 内用户自定义的分组。
_Avoid_: 标签、文件夹

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

**Mihon-compatible**:
本项目在四个轴上的兼容承诺：Extension、Backup、Manga 功能、数据映射。它不表示 UI 与 Mihon 相同，也不表示代码是 Mihon 的移植。
_Avoid_: Mihon 移植、Mihon 分支

**Extension compatibility（扩展兼容）**:
my-comic 的扩展行为以 Fushi v3.0.0 为基准：Fushi 能安装/运行的 Extension，my-comic 也必须能；不承诺超出 Fushi 的兼容范围。
_Avoid_: 全扩展兼容、100% 插件支持

**Snapshot（快照）**:
锁定在 Fushi v3.0.0 的代码基线；不包含上游后续提交。
_Avoid_: 分支、fork
