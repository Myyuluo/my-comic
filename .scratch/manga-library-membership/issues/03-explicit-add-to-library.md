# 03: 显式加入书架翻转 membership

**What to build:** 对已存在的非书架作品执行「加入书架」时，只把同一行的 membership 翻转为在书架，不新建行、不改变 bookKey/uid/下载目录/阅读状态；仍可选择 Tag；加入后订阅入口出现。若不存在行，则沿用现有创建书架行的路径。

**Blocked by:** 02（非书架行与在线阅读）

**Status:** resolved

- [x] 对已有非书架行执行加入书架，只翻转 membership，不新建行。
- [x] bookKey、uid、阅读进度、已读、下载目录与 History 在加入后保持不变。
- [x] 加入时仍显示 Tag 选择器，Tag 分配正常写入。
- [x] 加入后订阅/自动追更入口出现；移出后再次消失。
- [x] 不存在非书架行时，加入书架仍创建新的书架行。
- [x] 页面级测试覆盖翻转、状态保留、Tag、订阅入口与无行创建路径。

## Answer

Implemented in `2c81f5cc`; merged as `4a81bd65`.

Membership 翻转：`OnlineMangaLibraryService.add()` 命中已有非书架行时不再走「只刷新描述符」，改为调用新增的 `FushiDb.updateEpubBookInLibrary(bookKey, inLibrary: true)`，只把同一行的 `in_library` 写成 true；只有完全没有行时才 `_insert(entry, inLibrary: true)` 创建新的 Library 行，已在书架的行仍按原逻辑刷新。因此加入书架不会新建行，非书架行与书架行始终是同一条 Manga 记录。

状态保留：翻转只写 `in_library` 一列，bookKey、uid、extractDir、章节、阅读进度、已读、下载映射与 History 全部原样保留；测试断言加入后 bookKey/uid/下载目录不变且阅读状态、已读、History 仍在。

Tag 与订阅：`manga_series_page.dart` 的加入入口去掉了 `_row != null` 的提前返回，改为已在书架时跳过；有 Tag 时仍先弹选择器，目标 bookKey 用现有行的真实身份 `_row?.bookKey ?? bookKeyOf(entry)`（同源回退时可能与 seed 推导键不同），取消/零选/加入失败时 membership 保持 false 且不写 Tag。membership 变为 true 后订阅/自动追更入口出现，移出后再次消失（由既有 unified removal 测试与 03 新增测试覆盖）。

测试：指定 5 个套件 `flutter test` 共 76 项全部通过，覆盖带 Tag 翻转、无 Tag 直接翻转、零选、弹窗外部取消、Esc 取消、加入失败保持非书架、加入保留阅读进度/已读/下载映射/身份并出现订阅入口，以及无行时新建 Library 行的路径。本票未改动 i18n 字符串，无需重新生成 `strings.g.dart`。
