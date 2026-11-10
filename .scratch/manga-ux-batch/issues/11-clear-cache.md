# 11: 清除缓存（图片/磁盘）

**What to build:** 在设置「存储与下载 → 数据存储位置」新增「清除缓存」行，显示当前占用并清理封面、页流、解包、远端封面、缩略图与内存图片缓存；保留登录态与阅读数据。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 在「数据存储位置」现有两行之后追加「清除缓存」动作行；副标题显示当前磁盘缓存占用（格式化可读大小）。
- [x] 清理 Mihon 封面缓存。
- [x] 清理在线页流缓存与 CBZ 解包缓存，只清不在活跃阅读会话中的目录。
- [x] 清理远端封面缓存与缩略图缓存。
- [x] 清理图片缓存管理器的磁盘缓存，并清 Flutter 内存 `ImageCache`。
- [x] 保留图源登录态、Download library、Local source 目录与 `cover.jpg`、History、Reading progress 与数据库。
- [x] 大小统计只扫描上述显式缓存目录，不扫描整个系统临时目录；内存缓存不计入显示值。
- [x] 确认框显示当前占用；执行时复用「重建下载索引」的进度框模式；完成后 toast 显示释放量；不需要重启。
- [x] 单文件删除失败时继续清理其余项，结果提示部分成功与释放量。
- [x] 页面级测试覆盖大小统计、清理范围、数据保留与部分成功。
- [x] `flutter analyze`、定向测试通过（按批量任务指令未运行完整 Windows 构建）。

## Comments

- 2026-11-09：实现完成。定向测试与 `flutter analyze` 结果见提交说明；完整 Windows 构建未运行（批量任务明确要求不跑）。WebView / HTTP 缓存步骤留给 ticket 12，通过 `MangaCacheClearStep` 列表扩展。

## Answer

Merged as `77852c42`. 设置新增「清除缓存」行，显示占用并清理封面/页流/解包/远端封面/缩略图/图片缓存，保留登录态与阅读数据。
