# 06: 下载库识别、索引与删除 CBZ 章节（expand）

**What to build:** 下载库的章节载体同时支持文件夹与 `.cbz`：显式记录容器类型，完整性检查、删除、重建下载索引与互联解析都能处理压缩包。验证方式是把一个手工制作的 CBZ 放进下载库，重建后能被识别、列出、删除。本票不改变下载写入格式，现有文件夹行为保持绿。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 章节映射表增加显式容器类型（folder / archive），已有行迁移为 folder；schema v2→v3
- [x] 现有文件夹章节的解析、完整性检查、删除、重建与互联行为不变，已有测试保持通过
- [x] 章节载体抽象可表示文件夹与压缩包；解析与完整性检查按类型处理
- [x] 重建下载索引同时枚举漫画目录下的子目录与 `.cbz` 文件，压缩包从包根读取 `pages.json` 并重新关联映射
- [x] 删除压缩包章节删除对应文件；删除漫画删除其目录（目录内可含多个 `.cbz`）
- [x] 互联对端读取下载章节的路径支持压缩包或安全跳过，不出现运行时会崩的分支
- [x] 手工放置的 CBZ 能在下载库中被识别、列出并删除
- [x] 相关 storage/index/rebuild/delete 测试覆盖两种容器

## Answer

Implemented in `9e90c4ac`, merged as `65374568`. Schema v3 增加 containerKind；载体解析/完整性/删除按类型处理；重建索引扫描 `.cbz` 并读取包根 `pages.json`；互联对压缩包安全跳过。
