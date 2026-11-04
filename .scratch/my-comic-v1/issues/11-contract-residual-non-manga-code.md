# 11: Contract：删除残留非漫画 Dart 代码与旧表声明

**What to build:** 在 Mihon Backup Import 完成后，完成 ticket 05 的 contract 阶段：删除不可达的非漫画 Dart 代码、Fushi backup 服务、recommended pack；把 `@DriftDatabase` 表声明缩到 37 张漫画表；删除非漫画 Table 类/DAO/旧测试；确保没有旧表或 `.fushi.zip` 引用，构建和漫画功能保持 green。

**Blocked by:** 07: Backup Import：完整字段

**Status:** ready-for-agent

- [ ] 删除 `fushi/lib/src/sync/backup_service*`、migration_import/export、recommended pack 等不可达 Fushi backup 链路
- [ ] `tables.dart` 拆为漫画表 + 待删除 legacy 表；删除非漫画 Table 类/DAO
- [ ] `@DriftDatabase(tables: ...)` 缩到运行时 37 张漫画表
- [ ] 删除/更新引用旧表或 `.fushi.zip` 的 dead code/tests
- [ ] `flutter analyze` 无 error；`flutter build windows --release --no-pub` 成功；漫画 Library/Category/History/Progress/Download/Local source 冒烟通过
- [ ] 源码守卫测试确认没有非漫画表声明/旧 backup 入口
