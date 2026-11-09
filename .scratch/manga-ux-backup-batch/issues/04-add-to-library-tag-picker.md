# 04: 加入书架前选择标签：核心选择器与在线作品页

**What to build:** 标签选择器增加“延迟写入”模式，只返回选择结果、不立即写数据库；在线 Manga 作品页点「加入书架」时，用户已有 Tag 则先弹选择器，没有 Tag 则直接加入；支持多选、零选、完成入架与关闭取消。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 用户已有至少一个 Tag 时，在线 Manga 作品页点「加入书架」先显示标签选择弹窗，标题为「标签」，副标题显示 1 个条目。
- [x] 用户没有任何 Tag 时，直接加入 Library，不显示弹窗。
- [x] 弹窗复用现有标签选择器的搜索、全部标签、新建标签与完成按钮。
- [x] 可以多选 Tag，也可以一个都不选；零选时加入后为未打标签，作品出现在「书架」页签。
- [x] 点「完成」才创建 Library 条目并写入所选 Tag；点弹窗外部、按 Esc 或关闭弹窗则取消加入，不创建条目、不写 Tag。
- [x] 选择阶段不写数据库；加入失败时不留 Tag 分配。
- [x] 加入并打 Tag 后，作品只出现在对应标签页签，不出现在「书架」页签（现有规则不变）。
- [x] 页面级测试覆盖有 Tag 与无 Tag、多选与零选、完成与取消、加入失败不留标签。

## Answer

Implemented in `97b236f0`, merged as `6fb6cc09`. `tag_picker_sheet.dart` 新增 `showTagPickerSelection`：复用共享选择器的搜索、全部标签、新建标签与「完成」按钮，但处于「只选不写」模式——勾选只改内存选择，不落 Tag 分配；「完成」返回选中 Tag id 集合（可为空集），点弹窗外部 / 按 Esc / 关闭返回 null。在线 Manga 作品页 `manga_series_page.dart` 点「加入书架」时先查询全部 Tag：没有任何 Tag 时直接入架；已有 Tag 时先弹选择器（默认标题「标签」、副标题「1 个条目」），取消则不创建 Library 条目，确认后才创建条目并按所选 Tag 写入分配，零选则按未打标签入架并出现在「书架」页签。标签写入发生在 Library 条目创建成功之后，加入失败时不会留下 Tag 分配；标签读取失败时降级为直接入架。测试：`fushi/test/media/tags/tag_picker_sheet_test.dart`、`fushi/test/media/manga/manga_series_page_add_to_library_tag_picker_test.dart`，共 15 项，覆盖有 Tag / 无 Tag、多选 / 零选、完成 / 取消（遮罩与 Esc）与加入失败不留标签。
