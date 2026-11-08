# 02: 本地源根目录更名 `local`

**What to build:** 应用创建并使用 `<Content root>/local` 作为 Local source root；本地图源行的路径副标题、扫描、登记、阅读与重建下载索引都指向 `local`。旧 `localcomic` 不再被扫描、不被删除、不做迁移；用户可见文案与文档同步更名。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 默认与自定义 Content root 首次启动都创建 `local`
- [x] Content root 切换在新位置创建 `downloads`、`autobackup`、`local`
- [x] 本地图源行副标题显示 `local` 的实际路径；扫描、登记、阅读、重建都跟随 `local`
- [x] 旧 `localcomic` 不被扫描、不被删除、不被搬移；旧登记行显示 Missing（开发阶段接受的代价）
- [x] 用户可见的 `localcomic` 文案改为 `local`（删除本地文件确认、移出书架提示、重建确认等）
- [x] 存储用量分类使用 `local`；旧 `localcomic` 目录归入「其他」
- [x] 安装器 guard 使用路径限定的 `{userdocs}\MyComic\local`，不误匹配 `localappdata`
- [x] 内部 Dart API 名保持现有命名，只改文件夹常量值与注释
- [x] AppPaths、Content root switch、存储契约、本地源、重建与安装器 guard 测试更新并通过

## Answer

Implemented in `cdf7f1e9`, merged as `d697023a`. 本地源根目录改为 `local`；旧 `localcomic` 不扫描、不迁移、不删除，旧登记行变为 Missing（已接受）；用户文案、存储分类、安装器 guard 同步；内部 API 名不变。
