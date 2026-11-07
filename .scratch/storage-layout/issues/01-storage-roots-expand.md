# 01: Storage roots expand（wide refactor）

**What to build:** 应用启动后使用两个新的根：Content root（默认 `Documents\MyComic`，含 `downloads`、`autobackup`、`localcomic`）与 Program state root（`exe\userdata`，含 `state`、`cache`）。数据库、设置、扩展、更新包落到 `state`，可丢弃缓存落到 `cache`；旧数据不再被读取。现有下载/导入/阅读流程在旧的哈希布局下继续可用，只是暂时挂在 Content root 下。旧 data-root 设置与整目录迁移器移除。旧 root getter 暂作 alias，保证全仓编译与测试保持 green；真正的删除在 ticket 12。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 全新启动创建 Content root 下 `downloads`、`autobackup`、`localcomic`，以及 Program state root 下 `state`、`cache`
- [x] 数据库、`shared_preferences`、Mihon runtime、更新包位于 `state`；缓存位于 `cache`
- [x] 现有下载、导入、阅读流程仍可用（临时旧的哈希布局挂在 Content root 下），且不再读取旧 `Documents/Fushi/data` 或 `%APPDATA%` 数据
- [x] 旧 data-root 设置、迁移器和布局锚点不再影响根解析
- [x] 新 root API 可被调用方使用，旧 root getter 以 alias 形式保留；有测试/源码守卫
- [x] 全仓构建与测试保持 green
