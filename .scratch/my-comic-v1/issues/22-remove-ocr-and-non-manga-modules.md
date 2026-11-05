# 22: 删除 OCR 与非漫画模块代码

**What to build:** 删除漫画 OCR 的生成、显示与推理/模型层；删除视频 / 游戏 / galgame / 浮球模块代码。`.mokuro` 导入与下载 sidecar 合并保留（文本层不再显示）；schema 保持 v1 不动。

**Blocked by:** 21

**Status:** claimed

## 背景（2026-11-05 用户口径）

Q15：删整卷 OCR 生成层、全部漫画 OCR 按钮/设置、自动 OCR 钩子、阅读器增量缓存恢复；阅读器 `.mokuro` / `manga.json` 文本层显示也删除；视频/游戏 OCR 与推理模型层一并删除。
Q17：保留 `.mokuro` 导入；**不停止**下载时拉取/合并 mokuro sidecar。
Q18：整个视频 / 游戏 / galgame 模块代码删除；浮球模块代码删除；浮球系统 OCR 随之删除。
Q16：不升 schema，相关表/列保留但不再使用。

## 范围

- OCR 生成：wizard、background job、job stream、registry、`manga_book_ocr`、auto OCR（下载/阅读器）、cache recovery、remote host/client、desktop CTL `/api/admin/library/ocr`、`manga_ocr_selected_service`。
- OCR 推理/模型：`packages/fushi_engine/lib/ocr/*`、`manga_ocr_service/impl/pipeline`、模型下载/导入/存储、Google Lens、System OCR manga 服务、AI OCR、设置 OCR 页与模型/存储入口。
- OCR 显示：阅读器 `.ocr-box` 文本层、文本选择/查词钩子、`mangaOcrBoxesHtml` 渲染；保留 `MangaDownloadJobs.auto_ocr` 列但不再读写。
- 保留：`.mokuro` 导入（图片与页序、文本块按需保留即可）、`manga.json` 图片读取、下载 sidecar 拉取/合并、`manga_ocr_folder_job.dart` 中 import/scan 通用符号（`enumerateMangaPages` 等）需迁移到中性模块后再删其余。
- 非漫画模块：视频、游戏、galgame、浮球（含引用它们的设置页、sync/backup/CTL/CLI/首页/shelf 代码），保留 schema 表声明。
- `mangaOcrPollDelay` 在删除 interconnect client 前迁到中性 sync helper。

## Comments

- 2026-11-05 尝试记录：先删除 `media/video`、`media/torrent`、`floating_ball`、视频/游戏/galgame 页面与相关 ctl/sync 文件后，analyze 错误从数千到上万分，集中在 `app_model.dart`、`preferences_repository.dart`、`home_page.dart`、设置 schema、sync/backup/CTL 与大量测试；已将这些删除恢复，保持仓库可构建。结论：非漫画模块删除必须与共享层（AppModel / 设置 / 同步 / 备份 / 主页 / 桌面 CTL）和测试一起作为一个独立阶段推进，不能在 ticket 21 的合集删除里顺手做。
- 2026-11-05 第一阶段完成（OCR 用户可见入口，保留底层引擎）：
  - 作品页：删除 OCR 进度横幅/订阅、章节行「识别本章」接线、OCR 设置按钮、识别本章/全部已下载/自动识别方法；`MangaSeriesPage` 移除 `ocrEnginesOverride` / `lensDisclosureOverride` 测试缝。
  - 漫画导入对话框：移除「OCR 向导」按钮与参数。
  - 下载自动 OCR：所有 `autoOcr` 调用点改为 false（系列页、AppModel 新章入队、采集后端、桌面 CTL）。
  - 设置：移除「模型 › OCR」与「存储 › OCR 模型」入口。
  - 保留：`.mokuro` 导入、下载 sidecar 合并、`manga.json` 文本层显示、OCR 引擎/模型底层代码（待后续阶段删除）。
  - 验证：`flutter analyze lib test` 仅剩仓库既存错误；`flutter build windows --release` 通过；系列页/OCR 守卫测试更新并通过（`settings_schema_coverage_test` 焦点遍历为既存失败）。

## 验收

- [x] 无任何 OCR 入口/设置；下载不再触发自动 OCR；sidecar 仍按 Q17 合并。
- [x] 漫画阅读/下载/`.mokuro` 导入保持正常（release 构建通过）。
- [ ] 视频/游戏/galgame/浮球模块代码删除后 app 编译通过，相关设置/入口消失（延后）。
- [ ] OCR 文本层与生成/推理模型代码删除（延后，需与共享层一起做）。
- [x] 相关入口测试删除或改写；`flutter analyze`、定向测试、release 构建通过（既存失败除外）。
