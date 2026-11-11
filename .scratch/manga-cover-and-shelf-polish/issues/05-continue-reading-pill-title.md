# 05: 继续阅读胶囊显示书名

**What to build:** 书架顶部继续阅读胶囊在「继续阅读」下方增加漫画书名：小号灰黑色，宽度与「继续阅读」一致，超出省略；完整书名仍在 tooltip 中，胶囊整体保持单一点击目标。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 胶囊第二行显示当前作品的显示标题（`getDisplayTitleFromMediaItem`，含改名覆盖），不是数据库原始标题。
- [x] 书名使用小号灰黑色文字（MD3 `onVariant`，Apple `secondaryLabel`），不是纯黑，也不抢主色「继续阅读」的视觉重心。
- [x] 书名宽度按本地化「继续阅读」的实际渲染宽度通过 `TextPainter` 测量并约束；`maxLines: 1`，超出显示省略号。
- [x] 完整书名保留在悬停 tooltip 中；胶囊整体仍是单一点击目标，点击任意位置打开当前作品。
- [x] 桌面 MD3 的顶部 chrome 行高度不变；Apple 渲染路径不被裁切，如增高胶囊表面则页面 chrome 正确适配。
- [x] 没有继续阅读候选时胶囊保持隐藏，不出现空书名行。
- [x] 更新现有「胶囊不显示书名」测试，并新增/扩展：书名可见、改名覆盖、宽度/省略号、tooltip、无候选隐藏。
- [x] 按 ADR 0008 要求补 ADR 0016 修订，记录用户批准的「胶囊显示书名」UI 变更；不改其他书架视觉。

## Answer

- Worktree 分支：`worktree-agent-a44dd5bc99dd8c555`；基线 `80d70736`（ticket 03 已合入 integration）。
- Commit：`115f44d7` `feat(manga): show display title in continue reading pill`。
- 合并：`git merge --no-ff worktree-agent-a44dd5bc99dd8c555` → merge commit `87de298e` `Merge ticket 05: show title in continue reading pill`；无冲突。
- 本文件随后以 `docs(scratch): resolve ticket 05` 提交（其 SHA 见 `git log`）。

### 改动

- `fushi/lib/src/pages/implementations/reader_fushi_history_page.dart`：`_buildContinueReadingPill` 在「继续阅读」下方新增书名行。
  - 书名取 `mediaSource.getDisplayTitleFromMediaItem(item)`（含编辑弹窗写入的改名 override，不直读 DB 原始 `item.title`）。
  - 样式 `labelSmall`；MD3 用 `tokens.surfaces.onVariant`，Apple 用 `appleColorsOf(context).secondaryLabel`。
  - 宽度用 `TextPainter` 按本地化 `t.book_continue_reading` 的实际渲染宽度测量（同字阶、同 `textScaler`、同 locale，`ceilToDouble`），`maxLines: 1` + `TextOverflow.ellipsis`。
  - 完整书名保留在 `FushiTooltip`；整颗胶囊仍是单一点击目标（外层 `GestureDetector` 与内部胶囊段都走同一 `open` 路径，播放钮仅视觉）。
  - Apple 设计把悬浮面增高到 48 容纳两行（内部胶囊段 40 + 内衬 8）；桌面 MD3 chrome 高度 56 不变（`FushiFloatingChromeBar` 的 Row 无定高，按内容自适应）。无继续阅读候选时胶囊不渲染。
- `docs/adr/0016-manga-page-tag-tabs.md`：新增 Amendment 2026-11-11，记录用户批准的「胶囊显示书名」UI 变更、配色 / 宽度 / 省略 / tooltip / Apple 高度例外，属 ADR 0008 明确例外，不改其余书架视觉。
- 测试：
  - `fushi/test/pages/manga_library_continue_pill_test.dart`：更新原「胶囊不显示书名」断言，新增书名可见、`labelSmall` / `onVariant` 配色、宽度等于「继续阅读」、短书名不截断、超长书名单行省略、tooltip 完整书名、Apple 48 高度不裁切、改名 override、MD3 chrome 高度不变等覆盖。
  - `fushi/test/pages/manga_library_page_harness.dart`：`buildScaffold` / `buildApp` / `pumpPage` 支持传入 `ThemeData`，供 Apple 设计路径测试使用。
  - `fushi/test/pages/shelf_continue_hero_override_title_guard_test.dart`：新增两个源码扫描 guard，要求胶囊书名经 `getDisplayTitleFromMediaItem`，且不得直读 `item.title`。

### 验证

- 在 `fushi/` 下运行（`PUB_HOSTED_URL=https://pub.dev D:/ProgramData/flutter_3.47.6/bin/flutter.bat test ...`）：

  ```
  test/pages/manga_library_continue_pill_test.dart
  test/pages/shelf_continue_hero_override_title_guard_test.dart
  test/pages/manga_shelf_continue_reading_progress_test.dart
  test/pages/manga_library_membership_test.dart
  ```

  结果：`All tests passed!`（26 tests）。
- `flutter pub get` 顺带重生成的 platform plugin registrant 与 `pubspec.lock` 已用 `git restore` 回退，未纳入合并或本 ticket 提交。

