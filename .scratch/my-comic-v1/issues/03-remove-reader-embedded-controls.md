# 03: 移除阅读器内嵌的非漫画控件

**What to build:** 从漫画 Reader 中移除查词、Anki 制卡、统计等非漫画控件和弹窗，保留阅读器其余视觉与交互。接受 Reader UI 的相应变化（ADR-0002）。

**Blocked by:** 01: Baseline build + repo snapshot

**Status:** resolved

- [x] Reader 中不再出现查词、Anki、统计按钮或弹窗
- [x] Paged LTR/RTL、Webtoon/vertical、双页、翻页、Reading progress 保存仍正常
- [x] Reader settings 只保留漫画阅读相关项
- [x] Windows build 成功

## Comments

- Built at commit aff6f3d3; see docs/agent/baseline-build.md
- 196 项定向测试通过；Reader settings 只有 3 页签；构建/启动成功
- 遗留（留给 ticket 04/05）：`settings_schema_manga_ocr.dart` 残留 import、`settings_schema_floating_ball.dart` 的 `ocr_boxes` 映射、mokuro/OCR 兼容字段、Anki `SourceReviewBanner` 管线
