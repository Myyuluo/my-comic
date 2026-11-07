# 07: Local source CBZ chapters

**What to build:** 用户把 `localcomic/{manga}/{chapter}.cbz` 放进 Local source root，点击导入后应用扫描、登记并阅读 CBZ 章节；包根 `pages.json` 优先，缺失时扫描压缩包内图片构建页表。读取可以按需解压到 `cache` 或流式进行。移出书架/删除文件语义与文件夹章节一致。

**Blocked by:** 06

**Status:** resolved

- [x] 放入 `localcomic/{manga}/{chapter}.cbz` 并导入后，作品与章节出现在 Library 且可阅读
- [x] 包根 `pages.json` 被优先使用；缺失或损坏时回退到图片扫描
- [x] 读取按需解压/流式进行，不把 CBZ 永久复制到受管目录
- [x] 移出书架不删 CBZ；删除文件是单独且二次确认的动作
- [x] CBZ 扫描、缺失 metadata 回退、阅读、移出均有自动化测试
