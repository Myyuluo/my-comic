# 12: Contract 旧 root（wide refactor）

**What to build:** 在所有调用方迁移到新的 Content root / Program state root 后，删除旧的 `documents/support/temp` root getter、旧布局锚点、旧 data-root 偏好和死掉的非漫画存储路径。更新残余 call site，源码守卫确认不再有标题推导路径。全仓构建与测试保持 green。

**Blocked by:** 02, 03, 04, 05, 06, 07, 08, 09, 10, 11

**Status:** resolved

- [x] 代码中不再引用旧的 documents/support/temp root 或旧布局锚点
- [x] 死掉的非漫画存储 getter/目录规划被删除
- [x] 不再通过 Manga/Chapter 标题推导磁盘路径
- [x] 新 root API 是唯一的路径解析入口
- [x] 全仓构建、存储/下载/导入/设置测试与源码守卫保持 green
