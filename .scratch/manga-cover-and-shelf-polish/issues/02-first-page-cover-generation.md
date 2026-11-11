# 02: 缺失封面时从第一页生成封面

**What to build:** 源未安装或没有可用封面的 Manga，只要本地有完整 Chapter container，就从规范阅读顺序下第一个完整容器的第一页生成封面；生成字节只写入 Program state 缓存，书架与作品页都能显示，且不会污染下载目录。

**Blocked by:** 01（书架封面缓存写入后立即刷新）

**Status:** resolved

- [x] 从规范阅读顺序下第一个完整 Chapter container 取第一张图片：CBZ 取归档内第一张图片，文件夹章节取自然排序第一张图片；跳过 `ComicInfo.xml` 等非图片文件。
- [x] 生成字节只写入 Program state 的 shelf cover 缓存（按 bookKey），不写 Content root / Download library，不创建下载目录，不改 `cover_path`。
- [x] 缓存 sidecar 使用本地文件 sentinel（容器规范路径、大小、mtime）；容器替换或更新后视为需要重新生成。
- [x] 书架与作品页封面优先级：本地 `cover.*` 文件 → 可用 Source 的当前封面（含持久字节缓存）→ 第一页生成封面 → 占位。
- [x] 来源未安装/停用时，作品页先检查本地封面与持久/生成缓存，再显示「来源未安装」占位，不发起远程请求。
- [x] Source 恢复可用并成功取得真实封面后，真实封面替换生成封面；生成封面缓存被更新。
- [x] 第一页损坏、不是图片、容器不完整或解码失败时保留占位，不崩溃，记录日志。
- [x] 书架或作品页在缺封面时可懒生成一次；生成成功后通过 ticket 01 的 revision 让书架立即显示。
- [x] 生成封面适用于书架中任何有本地完整容器且没有可用封面的 Manga，不限于源未安装作品。
- [x] 测试覆盖：源未安装 + CBZ、文件夹章节、封面优先级、坏页、容器变化重生成、不写 Content root、书架与作品页显示。
- [x] 按 ADR 0008/0023 记录生成封面属于 Program state Cache，不属于 Download library。

## Answer

已合并到 `integration/manga-cover-and-shelf-polish`。

- Merge commit: `47f6061d047393fd49e12717770e7dfa83e1bc00`（`Merge ticket 02: generate missing shelf covers from the first page`）
- 合并前 integration HEAD: `1418cedc85591bbe7e534b7330c92acfd4bb5cee`
- 合并后 integration HEAD: `47f6061d047393fd49e12717770e7dfa83e1bc00`
- 冲突: 无（ort 策略自动合并；ticket 01 revision、ticket 04 自动续签、引擎 bytes API 与 Program state sentinel 均保留）

改动摘要：

- 引擎新增 `generateLocalSourceFirstPageCover` / `localSourceFirstPageCoverSentinel`（`packages/fushi_engine/lib/media/manga/local_source/local_source_cover.dart`）：CBZ 取归档内第一张图片、文件夹章节取自然排序第一张图片，`ComicInfo.xml` 等非图片天然跳过；返回宽 600、质量 85 的 JPEG 字节且**不写任何文件**。sentinel 由容器规范路径 + 大小 + mtime 组成；第一页损坏、容器不可读或解码失败返回 null，不会偷偷改用下一页。
- 新增 `fushi/lib/src/media/manga/library/manga_first_page_cover_service.dart`：按规范阅读顺序取第一个完整容器懒生成封面，字节只写入 Program state 的 `MangaShelfCoverCache`（按 bookKey），不写 Content root / Download library、不创建下载目录、不改 `cover_path`。sidecar 用 `local-first-page:` sentinel 与真实来源 URL 区分；同书并发生成合并为一条链；sentinel 变化后重新生成；成功后 bump ticket 01 的 `MangaShelfCoverRevision`，书架立即重算。
- `reader_fushi_source.dart`：书架封面优先级改为本地 `cover.*` → 来源当前封面（含按 bookKey 的持久字节缓存）→ 第一页生成封面 → 占位。生成链进入后台 pending 集合，书架与作品页共享。
- `manga_series_page.dart`：作品页同优先级；来源未安装/停用时先检查本地封面、持久缓存与生成封面，再显示「来源未安装」占位，不发起远程请求；来源恢复并取得真实封面后，真实封面替换生成封面并更新缓存。
- 测试新增/扩展：第一页生成（CBZ、文件夹章节、规范阅读顺序、坏页/坏容器、容器变化重生成、只写 Program state）、作品页显示、书架解析优先级、引擎 bytes API 与不写盘断言。
- ADR 0023/GLOSSARY 的正式文档修订按计划留给 ticket 07；本 ticket 在服务注释与实现中固定「生成封面属于 Program state Cache」的语义。

测试（Flutter 3.47.6 / Dart 3.13.5，先 `dart run slang`）：

- `packages/fushi_engine/test/media/manga/local_source_cover_bytes_test.dart`：5 个通过。
- `packages/fushi_engine/test/media/manga/local_source_cover_test.dart`（回归）：13 个通过。
- `fushi/test/media/manga/manga_first_page_cover_test.dart`
- `fushi/test/media/sources/manga_shelf_cover_resolution_test.dart`（含 ticket 04 自动续签用例）
- `fushi/test/media/manga/manga_series_page_cover_test.dart`
- `fushi/test/media/media_cover_write_guard_test.dart`
- `fushi/test/media/manga/rebuild_download_index_service_test.dart`
  → 5 个文件共 76 个测试全部通过。
- 额外回归：`manga_cover_retry`、`mihon_cover_cache`、`local_source_cover_browse`、`cover_file_writer_validation`、`media_cover_service`、`media_cover_source`、`reader_fushi_source_watch_guard` 共 51 个测试通过；`cover_write_sink_bug_2496_guard_test.dart` 的 3 个用例失败，但该失败在合并前 integration HEAD 已存在：`bba3599e`（fix: stop materializing downloads on browse and read）移除了 `online_manga_library_service.dart` 对 `MediaCoverService.applyCoverBytes` 的调用，基线守卫未同步更新。该文件与本 ticket 改动无交集，非本次合并引入。
