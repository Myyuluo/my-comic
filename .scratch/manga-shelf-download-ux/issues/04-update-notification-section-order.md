# 04: 更新提醒分组置顶

**What to build:** 把「设置 → 系统与关于」里的「更新提醒」分组移动到该子视图的最上方，分组内部条目顺序保持不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 「更新提醒」分组出现在「系统与关于」子视图的最上方，位于「通用」等其他分组之前。
- [x] 分组内部条目顺序不变，「无痕阅读」仍位于该分组最后一项。
- [x] 其他分组的内部顺序和可见性不受影响。
- [x] 现有更新提醒默认值与可见性测试继续通过；补充或更新顺序 guard，锁定新位置。
- [x] 设置页视觉与组件保持不变，遵守 ADR 0008。

## Answer

- Merge commit: `be81ba9e85b9e11c416354501928deccac2f190a`（`--no-ff` 合并 `worktree-agent-a8322de583992fe20`，无冲突）
- 来源 commit: `45b503838dd3248afe6734e8acc4c903ef0c7f8b` `feat(settings): move update notifications to top of system view`
- 改动摘要：`fushi/lib/src/settings/settings_schema_system.dart` 将「更新提醒」分组移动到系统与关于子视图顶部，分组内条目顺序不变；新增 `fushi/test/settings/settings_system_section_order_guard_test.dart` 锁定分组置顶与组内顺序（无痕阅读仍为最后一项）。未改动设置页视觉与组件。
- 测试（`fushi/`，`PUB_HOSTED_URL=https://pub.dev`，Flutter 3.47.6）：
  - `flutter test test/settings/settings_system_section_order_guard_test.dart test/settings/update_notification_defaults_test.dart test/settings/incognito_reading_settings_test.dart test/settings/settings_destination_order_guard_test.dart`
  - 结果：All tests passed（9 passed）
