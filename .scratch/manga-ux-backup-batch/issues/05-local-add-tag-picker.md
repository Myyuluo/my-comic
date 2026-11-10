# 05: 本地作品页与本地图源批量加入时选择标签

**What to build:** 本地 Manga 作品页「加入书架」与 Local source 页批量「加入书架」接入 04 的统一标签选择器；批量只弹一次并把同一组 Tag 应用到本批新加入作品；重新加入已移出书架的本地作品同样生效；静默加入保持无弹窗、未打标签。

**Blocked by:** 04（加入书架前选择标签：核心选择器与在线作品页）

**Status:** resolved

- [x] 已有 Tag 时，本地 Manga 作品页加入书架先弹标签选择；零 Tag 时直接加入。
- [x] Local source 页批量加入在已有 Tag 时只弹一次，副标题显示本批要加入的作品数量。
- [x] 批量所选 Tag 应用到本批所有新加入作品；已在 Library 的作品不重新加入、不应用 Tag。
- [x] 重新加入已移出书架的本地作品时同样弹选择器并可打 Tag。
- [x] 关闭弹窗取消整批加入，不创建条目、不写 Tag。
- [x] 点开未入架作品的章节仍静默加入，不弹窗且未打标签；拖拽导入、批量导入、重建下载索引、远程接管与 CLI/API 行为不变。
- [x] 页面级测试覆盖单本本地加入、批量本地加入、重新加入、取消与静默加入。

## Answer

Implemented in `029f35bb`, merged as `92a24ae7`. 本地 Manga 作品页与 Local source 页批量「加入书架」均接入票 04 的统一标签选择器（`showTagPickerSelection`），只选不写。

单本本地加入：`fushi/lib/src/media/manga/library/manga_series_page.dart` 的 `_addScannedLocalToLibrary` 先按 `localSourceBookKeyFor(directoryPath)` 调用共享的 `_pickTagsBeforeLibraryAdd`（已重构为接收 bookKey，供在线与本地路径复用）；已有 Tag 时弹选择器，关闭/取消返回 null 则直接放弃登记，不创建 Library 条目、不写 Tag。选中的 Tag 在 `_registerScannedLocal` 登记成功后才通过 `_applySelectedTags` 写入，登记失败不会留下 Tag 分配；零 Tag 时直接加入。重新加入已移出书架（tombstone）的作品走同一路径，同样弹选择器并可打 Tag、清墓碑。点开未入架作品的章节仍走 `_openChapterAt` → `_registerScannedLocal` 的静默登记，无弹窗、未打标签；拖拽导入、批量导入、重建下载索引、远程接管与 CLI/API 行为不变。

批量本地加入：`fushi/lib/src/media/manga/local_source/local_source_browse_page.dart` 的 `_batchAddToLibrary` 在过滤掉已入架作品后，仅调用一次 `_pickTagsForBatch`，选择器副标题显示本批待加入作品数量；关闭弹窗则整批取消，不登记、不写 Tag。所选 Tag 在每部作品登记成功后逐个写入，单部加入或写 Tag 失败只提示且不产生残留分配；已在 Library 的作品不重新加入、不应用 Tag。标签读取失败时降级为按未打标签直接加入。

测试：`fushi/test/media/manga/manga_series_page_local_add_to_library_tag_picker_test.dart`（单本加入、重新加入、零选取、外部取消、零 Tag）与 `fushi/test/media/manga/local_source_batch_add_tag_picker_test.dart`（批量只弹一次、副标题数量、应用到全部、跳过已入架、重新加入、取消、静默路径），连同票 04 的 `manga_series_page_add_to_library_tag_picker_test.dart` 一并运行，17 项全部通过。
