# 05: 导入后标签页签即时刷新

**What to build:** `.tachibk` 导入成功后，书架顶部的 Tag 页签与作品归属立即刷新，不再需要进入「管理标签」页再退出。刷新沿用现有标签管理页的 invalidation 语义，并继续遵守 ADR 0016。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 导入成功且报告非空后，成对 invalidate `allTagsProvider` 与 `bookTagMapProvider`。
- [x] 导入完成后标签页签立即出现，数量正确，带 Tag 的作品立即从「书架」移到对应标签页签。
- [x] 「书架」页签只显示无 Tag 作品；多 Tag 作品出现在每个对应标签页签（ADR 0016 不变）。
- [x] 导入报告弹窗显示期间或关闭后，背后的书架已经是最新状态。
- [x] 导入失败或取消时不触发刷新。
- [x] 空备份或零 Tag 场景仍只有「书架」页签，不出现空页签。
- [x] 重复导入同一备份时标签页签保持幂等，不重复出现或重复计数。
- [x] 当前选中的页签保持不变，除非选中的 Tag 已被删除。
- [x] 不改变标签管理页、标签选择器或批量打标签的现有行为。
- [x] 页面级测试覆盖导入后立即出现页签、数量、归属、失败/取消不刷新与零 Tag 场景。

## Answer

Implemented in `9deaf71f`, merged as `b84f3033`; review follow-up in ticket 07 修正了失效范围与刷新判定条件。漫画侧的失效语义现在提取为 `tag_filter_sheet.dart` 的共享 helper `invalidateMangaTagProviders(ref)`：它只 invalidate 漫画页签 / 归属读取的 `allTagsProvider` 与 `bookTagMapProvider`。`runMihonBackupImport` 与 `tag_management_page.dart` 的漫画部分共用这个 helper；标签管理页再自行 invalidate SRT / 视频 / 游戏 / 合集映射（因为编辑标签池会影响全部媒体类型），导入流程不会重建这些无关媒体。`runMihonBackupImport` 在导入流程返回、且报告表明标签可能变化时先失效，再显示导入报告弹窗，因此弹窗背后的书架在显示期间已是最新：页签立即出现、数量正确、带 Tag 作品立即从「书架」移入对应页签。判定条件为 `report != null && (!report.isEmpty || report.hasCategoryTagWrites)`：分类可以在没有任何 Library 条目时单独写入 Tag 表（`isEmpty` 不覆盖分类），所以仅含分类的备份也会刷新；失败或取消时 `outcome == null` 直接返回，不含任何分类/条目变化的全空备份仍不触发刷新。ADR 0016 的归属规则未改动：仍为单选胶囊页签，「书架」= 无任何用户 Tag 的漫画，多 Tag 漫画出现在每个对应页签且各计一次，不新增「全部」页签；当前选中的页签在刷新后保持，仅当对应 Tag 被删除时由现有页签收敛逻辑回退。标签管理页、标签选择器与批量打标签的现有行为均未改动。新增 `fushi/test/pages/manga_library_tag_refresh_test.dart`（6 个页面级 widget 测试）覆盖：导入成功后弹窗显示期间页签/数量/归属立即刷新、失败不刷新、取消选择文件不刷新、零 Tag 备份仍只有「书架」、重复导入幂等且选中页签保持，以及仅有分类、零 Library 条目的导入同样立即刷新页签。
