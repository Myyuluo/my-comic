# 03: 同名作品共享下载目录

**What to build:** 同一 Source 下标题相同的不同作品共用同一个漫画目录，不再生成 `(2)`；下载、阅读与下载状态按每个章容器的 `pages.json` 身份归属到正确作品；导入重链与重建索引都能处理共享目录。

**Blocked by:** 02（浏览与阅读不写 Download library）

**Status:** resolved

- [x] 同一 Source 下标题相同的不同作品解析到同一个漫画目录；同一部作品永不新建 `(2)` 目录。
- [x] 共享目录中的每个章容器按 `pages.json` 身份归属到正确作品；阅读、下载状态与章节列表互不串作品。
- [x] 导入后重链与 Rebuild download index 能处理一个目录内的多个作品身份，不把共享目录整目录跳过。
- [x] 不同身份、同名作品不生成 `(2)`；目录名保持可读。
- [x] 服务级测试覆盖两部同名作品下载、状态、重链与重建；`flutter analyze` 与 Windows 构建通过。
## Answer

Merged as `c08b79f9`. 同 Source 同名作品共享目录，无 (2)；按章容器 pages.json 身份归属；导入重链与重建支持共享目录。
