# 10: Rebuild full recovery

**What to build:** 在「重建下载索引」中，`downloads` 和 `localcomic` 里书架没有的作品也会被创建成 Library 条目。尊重「主动移出书架」的 tombstone；源未安装时降级为指向该文件夹的本地条目；没有 `pages.json` 时扫描图片建本地条目。操作只增改、不删除，结束后报告新增/更新/缺失/跳过数量。

**Blocked by:** 05, 07, 09

**Status:** ready-for-agent

- [ ] 只在 `downloads`/`localcomic` 中存在、书架没有的 Manga，重建后出现在 Library
- [ ] 有 tombstone 的作品不会被重新加入
- [ ] 源已安装时创建在线条目并标记已下载章节；源未安装时创建本地条目并报告
- [ ] 没有 `pages.json` 的目录通过图片扫描创建本地条目
- [ ] 报告新增/更新/缺失/跳过数量；只增改、不删记录或文件；幂等
- [ ] 有自动化测试覆盖每种恢复分支与 tombstone
