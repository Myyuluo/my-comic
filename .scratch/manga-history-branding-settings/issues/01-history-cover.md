# 01: 历史页使用书架封面缓存

**What to build:** History 页的漫画封面改用与书架相同的 Program state shelf cover 缓存解析（本地 `cover.*` → 持久/生成封面 → 可用 Source 远程 URL → 占位），并在页面挂载期间响应封面 revision。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] `loadMangaHistory` 支持可选的 shelf cover cache 输入；现有调用方不传时行为不变。
- [x] History 封面顺序：本地 `cover.*` → Program state 持久/生成封面 → 可用 Source 的 `series.coverUrl` → 占位；来源未安装/停用时跳过远程。
- [x] `[darklust]…`（源未安装、只有第一页生成封面）的 History 卡片显示生成封面，不再是灰占位。
- [x] History 页监听 `MangaShelfCoverRevision`（或等价 revision）；挂载期间封面写入成功后重新加载/刷新。
- [x] 不改变 History 的排序、去重、History 记录与阅读进度语义。
- [x] 测试覆盖：本地/持久/生成/远程/占位、来源缺失、revision 刷新；不新增 schema/Backup 变更。
- [x] 遵守 ADR 0008/0023，不写 Content root / Download library。

## Answer

Implemented in `9ced64aa` + `3a762b09`, merged as `e4442c55`（无冲突；ticket 分支已先合入 integration 的 `f0a80670`，ticket 02/03/04 改动保持不变）。

**顺序修正：** 最终顺序为 本地 `cover.*` → Program state 真实来源持久封面 → 可用 Source 的远程 URL → 第一页生成封面 → 占位。首版把持久封面与生成封面合并为一档（`_cachedShelfCoverPath`），会把过期的生成字节排在可用远程 URL 之前；`3a762b09` 拆成 `_cachedRealShelfCoverPath` 与 `_cachedGeneratedShelfCoverPath`，让可用来源的当前远程 URL 优先于生成封面，同时来源未安装/停用时仍跳过远程并回退到生成封面（`[darklust]` 场景）。

`loadMangaHistory` 新增可选 `shelfCovers` 参数，不传时走原远程/快照回退；`manga_history_page.dart` 通过 `mangaHistoryShelfCoverServiceProvider`（autoDispose，与书架共用 `<programState>/cache/shelf_covers`）注入，并在挂载期间订阅 `MangaShelfCoverRevision.events` 重新加载。未改动 History 排序/去重/记录/进度语义，无 schema/Backup 变更，不写 Content root / Download library。

测试（`fushi/`，`dart run slang` 后）：`test/pages/manga_history_cover_test.dart`、`test/pages/manga_history_page_test.dart`、`test/media/manga/manga_history_write_test.dart`、`test/media/manga/manga_first_page_cover_test.dart`、`test/media/sources/manga_shelf_cover_resolution_test.dart` 全部通过，合计 72 个测试（`All tests passed!`）。覆盖本地/真实持久/生成/远程/占位、来源缺失与未安装 darklust 场景、revision 自动刷新与重新进入页面读取最新缓存。
