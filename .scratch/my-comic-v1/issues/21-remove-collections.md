# 21: 删除合集功能代码

**What to build:** 从用户可见行为与代码中移除「合集 / media collections」功能。schema 保持 v1 不动（合集表保留为休眠表，不迁移、不清理旧数据）。

**Blocked by:** 20

**Status:** resolved

## 背景（2026-11-05 用户口径）

Q10：不需要合集功能，合集相关功能和代码删除。
Q12：彻底删除（功能代码），但 Q16 确认不升 schema；因此物理表与 `collection_book_aliases` 保留。
Q13：删除自动分卷后，本地多卷漫画每卷独立显示。

## 范围

- 删除书架合集卡、合集详情页、合集上下文菜单、拖拽入合集、多选整选合集、批量组合/解散、合集 AI 排序。
- 删除 `BookSeriesGrouper.groupAll()` 自动分卷调用链（书架、扫描器、主机清单、服务端 scanner）。
- 删除合集 domain/UI：`fushi/lib/src/media/collections/*` 中与 media collections 相关的部分、`media_collection_*` 页面、`series_shelf_card.dart`、合集对话框/拖拽/选择代码。
- 删除同步/备份/主机 API/桌面 CTL/CLI 中的合集逻辑。
- 保留：schema 表声明与 live schema、`collection_book_aliases` 及远端删除身份换算 DAO（`syncDeletionBookKeyOf` / `getPeerToLocalBookKeys`）、`shelf_sort.dart` 等通用排序、阅读器插画画廊用的通用 volume helpers、标签系统。
- 视频/游戏/galgame 模块中的合集引用：本 ticket 先剥离到可编译；模块本体在 ticket 22 删除。

## 验收

- [x] App 内无任何合集入口；书架不再自动折叠多卷。
- [x] 单卡/批量删除、标签、阅读进度、系列页、下载不受影响。
- [x] 同步 / 主机 / CTL / CLI 编译通过并移除合集读写；备份仍按 v1 快照携带休眠的 `media_collections*` 表数据，但无 UI / 选择 / 合并语义。
- [x] 合集相关书架测试删除或改写；`flutter analyze`、定向测试、release 构建通过。

## Comments

- 2026-11-05 第一段完成（live 路径）：
  - 书架改为单卡平铺（`_shelfSlotSortKey` + `_buildShelfSlotSlivers`），删除合集卡片/上下文菜单/详情页入口/成员菜单/合集多选/批量解散/拖拽入合集/合集标签过滤/远端合集收养。
  - `_loadShelfMaps` 不再调用 `BookSeriesGrouper.groupAll()`，不再读取合集字典/成员序。
  - 批量栏只保留下载/标签/重置进度/删除。
  - `flutter analyze lib test` 仅剩仓库既存错误；release 构建通过。
- 未完成（阻塞）：同步 / 备份 / 主机 API / 桌面 CTL / CLI / 合集 domain+engine 的代码删除。尝试直接删除 `media/collections/*` 与合集页面会立刻牵出视频/游戏/galgame/media-server 等模块（它们仍参与编译）以及 `app_model` / 设置 / 同步 / 备份的合集引用，单次 analyze 错误量上千。已恢复到可构建状态，等待与 ticket 22 的非漫画模块删除合并推进。
- 2026-11-06 完成（与 ticket 22 合并收尾）：
  - 删除合集用户可见入口、合集详情/选择/拖拽/批量组合、统计页合集归属展示；书架保持单卡平铺，不再调用 `BookSeriesGrouper.groupAll()`。
  - 删除引擎主机 API 的 `CollectionManifest` 读写与合集路由、桌面 CTL 合集路由/处理器、CLI `collection` 命令组；标签命令不再接受 `collection:<id>` 目标。
  - 保留 schema 表、`collection_book_aliases`、远端删除身份换算、`shelf_sort` 与阅读器多卷 helpers。
  - 验证：app `lib/test/integration_test` 与 engine/server/cli/core 的 `dart analyze` 均 0 error；定向测试 34 个文件修复后 `225 passed / 13 skipped`；`flutter build windows --release` 通过。
  - 已知既存：备份/合并仍会搬运休眠合集表（v1 数据保全）；`loadStatFacts` 仍查询已不在 v1 live schema 的游戏/视频表，仪表盘远程数据路径因此可能提前吞错（既有 schema 遗留，另行跟进）。
