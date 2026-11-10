# 05: 刷新失败横幅文案

**What to build:** 修正漫画作品页刷新失败横幅：删除误导性的「显示的是本机已保存的章节」副标题，并把运行时失败标题改为「无法获取漫画信息，请重试或查看详情」；其他失败原因保留各自标题，但同样不再显示本机章节副标题。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 运行时刷新失败横幅标题显示「无法获取漫画信息，请重试或查看详情」。
- [x] 刷新失败横幅不再显示「显示的是本机已保存的章节」，无论失败原因是什么。
- [x] 来源停用、平台不支持等其他失败原因仍显示各自的原因标题。
- [x] 「重试」与「查看详情」动作及其可见性规则保持不变。
- [x] 测试覆盖运行时失败、来源停用、平台不支持三种情况下的标题与副标题。
- [x] 所有修改文案在全部支持语言中同步；不再使用的副标题 key 被删除或明确标记为待清理，并重新生成访问器。

## Answer

- Merge commit: `0f647a80a0775290981b7ef56dfcee0b1af25496`（`Merge ticket 05: clarify refresh failure banner copy`），来源分支 `worktree-agent-adf9856d199dd5589`（实现提交 `a8ba0e7c`），无冲突。
- 改动摘要：
  - `fushi/lib/src/media/manga/library/manga_series_page.dart` 删除失败横幅中固定的 `manga_series_offline_hint` 副标题。
  - 17 个 locale 的 `manga_series_refresh_failed` 改为「无法获取漫画信息，请重试或查看详情」对应译文，并移除不再使用的 `manga_series_offline_hint` key。
  - 用 `dart run slang` 重新生成 gitignored 的 `lib/i18n/strings.g.dart` 访问器。
  - 新增 `fushi/test/media/manga/manga_series_page_refresh_banner_test.dart`，覆盖运行时失败、来源停用、平台不支持三种情况的标题、副标题与动作；其他失败原因标题与「重试」「查看详情」动作保持不变。
- 测试（在 `fushi/` 下，`PUB_HOSTED_URL=https://pub.dev`，Flutter `D:\ProgramData\flutter_3.47.6\bin\flutter.bat`）：

  ```
  flutter test test/media/manga/manga_series_page_refresh_banner_test.dart \
    test/media/manga/manga_series_page_refresh_policy_test.dart \
    test/media/manga/manga_series_missing_source_test.dart \
    test/i18n/i18n_keys_sorted_guard_test.dart \
    test/i18n/strings_test.dart \
    test/i18n/zh_cn_mojibake_guard_test.dart
  ```

  结果：`All tests passed!`（49 个测试通过）。
