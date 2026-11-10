# 01: 导入章节顺序与阅读器换章

**What to build:** `.tachibk` 导入的 Manga 保存 Mihon 的 `sourceOrder`，作品页按「最新在前」显示，阅读器独立按阅读顺序换章：读完第 1 话进第 2 话、往回翻进上一话；在线源行为不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 导入时把备份章节的 `sourceOrder` 保存到章节模型/JSON；缺失时回退章节号、上传日期。
- [x] 在线源适配器为章节补 `sourceOrder = 列表下标`（0 = 最新），在线源换章行为不变。
- [x] 作品页按「最新在前」显示导入章节；「第一话在前」切换正确反转；显示排序不改变章节身份。
- [x] 阅读器构造独立的升序阅读列表（`sourceOrder` 降序，缺失回退章节号/日期），上一话/下一话用 ±1，不依赖 `chaptersJson` 数组顺序。
- [x] 读完第 1 话进入第 2 话，第 2 话进入第 3 话；只有真正最后一话提示「已经是最新一章」。
- [x] 重新导入同一 `.tachibk` 幂等并补齐 `sourceOrder`；已有作品无需手工修数据。
- [x] 页面级与相邻章节测试覆盖新导入、重新导入、无章节号/日期的作品、在线源不回归；`flutter analyze` 与 Windows 构建通过。

**已接受的偏差（导出）：** 备份导出写入标准的 Mihon `BackupChapter.sourceOrder`（`chapter.sourceOrder ?? 列表下标`），而不是保持导出代码完全不变。这是 MyComic→MyComic 往返保留阅读顺序所需；它只填充 Mihon 既有字段，在线条目导出的值就是源列表下标，与 Mihon 行为一致，Mihon 兼容性不受影响。其余导出行为保持不变。
## Answer

Merged as `c08b79f9`. 导入持久化 sourceOrder，阅读器按独立升序阅读列表换章，作品页最新在前/第一话在前显示正确。
