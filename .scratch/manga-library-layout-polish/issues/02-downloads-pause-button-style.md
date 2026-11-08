# 02: 下载页全局暂停按钮改用图二样式

**What to build:** 下载页右下角的「全部暂停 / 全部继续」按钮改为图二的浅蓝胶囊样式，同时保留暂停/播放图标、文字、状态机、位置与 key。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 按钮使用 `FushiFloatingTextAction` 的默认样式：浅蓝 `secondaryContainer` 底、`onSecondaryContainer` 前景、stadium 圆角、柔和投影。
- [x] 保留暂停 / 播放图标与粗体文字「全部暂停 / 全部继续」。
- [x] 按钮仍在下载页右下角，列表底部留白保证最后一张任务卡不被遮挡。
- [x] 状态机不变：列表为空隐藏；全部暂停或失败显示「全部继续」；存在排队中/下载中显示「全部暂停」。
- [x] 点击行为与按钮 key 不变。
- [x] 既有全局暂停 / 继续测试全部通过。

## Answer

Implemented in `edc058f2`, merged as `161d441f`. 移除上一轮自定义的 `surfaceContainer` / 前景覆写，按钮恢复 `FushiFloatingTextAction` 默认 `secondaryContainer` / `onSecondaryContainer`；图标、粗体文字、位置、key、状态机与底部留白不变；新增样式断言测试。Code review fixes in `106ad7d0`, merged as `cd805538`.
