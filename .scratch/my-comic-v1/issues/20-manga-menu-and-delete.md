# 20: 漫画页删除修复 + 长按菜单与批量栏精简

**What to build:** 漫画页（mangaOnly 书架）长按/右键菜单的「删除」恢复可用；同一菜单移除查看插画、识别文字OCR、查看统计、内容语言、转换回书、加入合集、指定配置、编辑书籍CSS、作品页九项；选择模式底部横条移除「组合成系列」「识别文字OCR」。移除后菜单仍保留删除、重命名、打开文件位置、标记已读完、重置阅读进度、标签、编辑信息。

**Blocked by:** None

**Status:** resolved

## 背景（2026-11-05 用户口径）

- Q1：删除失效按 `db.hasTable` 守卫修复。
- Q2：九项菜单入口直接删除，不按 `isManga` 限量；这些功能都不再需要。
- Q3：批量栏「组合成系列」「识别文字OCR」直接删除。
- Q7/Q14：能整块删的独占代码一并删除；统计 / Profile / 内容语言选择器 / `BookFormat`+`BookFormatRebuild` / 阅读器插画画廊 / `revealed_images` 是共享基础设施，只删入口、保留底层。

## 根因（已用真实 37 表库验证）

漫画-only 新 schema 没有 `audiobooks` / `srt_books` 表，但恢复后的删除链路仍无条件查询：
- `ReaderFushiSource.hasLocalFiles` 在弹确认框前查 `audiobooks` → 抛 `no such table`，删除按钮看起来“没反应”；
- `ReaderFushiSource.deleteBook` 无条件查 `srt_books` → 同样失败。
用户实际库 `%APPDATA%/Fushi/Fushi/my_comic.db` 只有 37 张表、两本 `format='manga'` 书。

## 验收

- [x] `ReaderFushiSource.hasLocalFiles` / `deleteBook` 在 `audiobooks` / `srt_books` 表不存在时跳过查询，不抛异常。
- [x] 新增回归测试：用真实 `FushiDatabase(tempDir)`（37 表）插入漫画行，单卡删除成功；`forTesting` 全表库行为不变。
- [x] 长按/右键菜单不再出现上述九项；删除、重命名、打开文件位置、标记读完、重置进度、标签、编辑信息仍在。
- [x] 选择模式底栏不再出现「组合成系列」「识别文字OCR」；下载、标签、重置进度、删除仍在。
- [x] 独占代码删除：书架「查看插画」查看器页、CSS 编辑器页及阅读器快捷设置入口、按书 Profile 弹窗、转回书方向、作品页菜单项；共享底层保留。
- [x] 守卫测试更新：`manga_book_ocr_test`、`booklongpress_floating_lyric_toggle_test`、`reader_shelf_batch_collection_ops_test`、`reader_remote_multiselect_test`、插画/CSS/Profile/格式转换相关测试。
- [x] `flutter analyze` 通过（仅剩仓库既存错误/警告）；定向测试通过（既存失败除外）；`flutter build windows --release` 通过。

## Comments

- 2026-11-05 范围确认：合集与 OCR 功能本体的删除拆到 ticket 21/22；本 ticket 只处理菜单/批量栏入口与独占代码。
- 2026-11-05 实现完成：
  - 删除修复：`hasLocalFiles` / `deleteBook` 用 `db.hasTable('audiobooks'|'srt_books')` 守卫；真实 37 表库回归测试通过。
  - EPUB/漫画长按菜单移除九项；SRT 菜单同步移除查看插画/加入合集/内容语言/指定配置/编辑 CSS（功能已删）。
  - 批量栏移除组合成系列与 OCR；删除 `_batchCombineIntoSeries` 三档、OCR 排队、`_addEpubToCollection`、`_openIllustrations`、`_openCssEditor`、`_openBookProfilePicker`、`_openBookLanguagePicker`、`_openItemStatistics`、`_convertBookFormat` 及作品页菜单项。
  - 删除 `illustrations_viewer_page.dart`、`book_css_editor_page.dart`；移除阅读器快捷设置 CSS 入口。
  - 更新受影响的守卫测试；`flutter analyze` 无新增错误；`flutter build windows --release` 成功。
  - 注：`mihon_import_segments_test`、`reader_fushi_source_test` 的 4 个 SRT 用例、`collection_member_menu_parity`、`reader_remote_multiselect`、批量合集解散等属基线既有失败（fresh schema 缺 `srt_books` 等），本 ticket 未引入。
