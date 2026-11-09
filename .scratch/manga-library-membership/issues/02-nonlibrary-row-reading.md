# 02: 非书架行与在线阅读

**What to build:** 打开在线源作品页时创建或复用一条 membership=false 的 Manga 行与章节；点章节不再自动加入书架，而是直接在阅读器中打开该非书架行。阅读进度、章节已读、当前章节、History 与阅读统计写入这条行，书架不受影响。

**Blocked by:** 01（Library membership 基础）

**Status:** resolved

- [x] 打开在线源作品页时创建或复用一条非书架 Manga 行，包含章节与来源 metadata。
- [x] 点章节阅读不再自动加入书架，阅读器可打开非书架行。
- [x] 阅读进度、章节已读、当前章节、History 与阅读统计持久化到该非书架行/uid。
- [x] 书架、Home、Tag 计数不出现该非书架作品。
- [x] 再次从在线源或 History 打开同一作品时复用同一行/uid，不重复建行。
- [x] 本地图源点章节仍静默登记，行为不变。
- [x] 页面级测试覆盖创建/复用、无自动入库、进度/History 持久化与书架隔离。

## Answer

Implemented in `16af48cd`; merged as `90c2325b`.

非书架行的创建/复用：新增 `OnlineMangaLibraryService.ensureNonLibrary()`，为在线源作品创建或复用一条 membership=false 且包含章节与来源 metadata 的 Manga 行。复用/插入路径与 `add()` 共享（bookKey/uid、封面、下载目录与文件夹复用逻辑），因此同一作品再次从在线源或 History 打开时复用同一行/uid，不重复建行；之后加入书架时 bookKey/uid/extractDir 也保持一致。

无自动入库：打开在线源作品页时只确保该非书架行；点章节改为经 `ensureNonLibrary()` 直接在阅读器中打开该行，不再走旧的隐式加入书架路径。本地图源点章节的静默登记行为未改动。

阅读进度与 History：阅读进度、章节已读、当前章节、History 与阅读统计持久化到该非书架行/uid，阅读统计仍以同一 bookKey 为键。书架列表（`ReaderFushiSource.getBooksFromDb`）继续只读 membership 行，非书架作品不出现在书架、Home 与 Tag 计数中；详情页加入/移出动作的判据改为 membership 而非行是否存在。

测试：指定套件 `flutter test` 65 项全部通过，覆盖创建/复用、无自动入库、阅读器进度持久化与书架隔离。已知 6 项失败位于 `test/media/manga/manga_series_page_add_to_library_tag_picker_test.dart`：本票在打开作品页时即创建非书架行，而显式「加入书架」仍是 no-op；这属于 ticket 03 的 membership flip 范围，由票 03 更新这些测试，不作为本票阻塞项。
