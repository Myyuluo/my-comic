# 13: 导入：Mihon 分类恢复为标签

**What to build:** 导入 Mihon 备份时，把分类按名称创建或合并为 Tag、按分类 order 设置排序并分配给对应作品；不再写入隐藏合集；已有隐藏合集保持原样、不迁移。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 导入 Mihon 备份后，每个分类按名称创建为 Tag；已存在同名 Tag 时复用，不重复创建。
- [x] Tag 顺序来自分类 order；新 Tag 使用默认颜色。
- [x] 每部作品的分类 order 转换为对应 Tag 分配；多分类写入多个 Tag。
- [x] 导入不再创建新的隐藏合集或合集成员；已有的隐藏合集保持原样、不迁移。
- [x] 有分类的作品导入后出现在对应标签页签，不出现在「书架」页签（现有规则）。
- [x] 重复导入同一备份时 Tag 分配幂等，不重复挂载。
- [x] 备份导入 seam 测试覆盖新建、复用、排序、多分类、不写合集与幂等。

## Answer

Implemented in `b0dd380b`, merged as `c4615fc6`. 导入 Mihon 备份时，分类按 trim 后的名称解析为 Tag：不存在则创建（默认颜色 `0xFF9E9E9E`），存在则复用并保留其颜色；Tag 排序值取分类 order。每部作品的分类 order 映射为对应 Tag 分配，多分类写入多个 Tag，作品因此离开「书架」页签并出现在对应标签页签。导入不再创建隐藏合集或合集成员，已有隐藏合集保持原样、不迁移；重复导入按 `bookKey` 幂等 upsert Tag 分配。定向测试 `fushi/test/backup_import/mihon_backup_import_test.dart` 共 12 项全部通过，覆盖新建、复用、排序、多分类、不写合集、既有合集不变与重复导入幂等。
