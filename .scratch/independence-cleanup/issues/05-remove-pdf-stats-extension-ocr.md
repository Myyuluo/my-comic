# 05: 删除 PDF 导入、阅读统计、浏览器扩展与 OCR 残留

**What to build:** 移除 Q9 明确删除的剩余非漫画能力：PDF 导入、阅读统计、浏览器扩展，以及端上 OCR/无入口渲染胶水；保留漫画图片导入、Local source 与 `.mokuro` 数据路径（如仍被 Local source 使用）。

**Blocked by:** 04

**Status:** resolved

- [x] 删除 PDF 导入路径、导入对话框中的 PDF 选项、`pdfrx` 依赖与相关测试；确认图片/CBZ/ZIP/文件夹导入仍正常。
- [x] 删除 Reading statistics 的写入、聚合、查看入口和测试；保留 History 与 Reading progress，二者语义不变。
- [x] 删除浏览器扩展目录、manifest、options、语言字典、测试与所有引用；确认旧 Onboarding 已不依赖它。
- [x] 删除端上 OCR/AI 推理与已无入口的 `.ocr-box` 渲染胶水；如果 Local source 的 `.mokuro` overlay 仍需要文本框渲染，保留最小数据路径，不保留 OCR 推理。
- [x] 删除仅被这些功能使用的依赖、资源和测试 fixture。
- [x] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；漫画图片导入、阅读器、Local source 与 `.mokuro`（如保留）可用。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。不要删除 Local source 或 Download library 的图片/章节容器能力。

## 实现记录

### 删除的功能面

- **PDF**：`pdfrx` / `pdfium` 依赖与 native asset；`lib/src/pdf/`（`PdfEngine` / `PdfImporter`）、
  `reader_pdf_page.dart`、`reader_pdf_source.dart`、`manga_pdf_importer.dart`；
  `book_format_convert.dart` / `book_format_rebuild.dart`（书 ↔ 漫画转化，唯一调用方是 PDF 转漫画）；
  导入载体、拖放/外部打开白名单、漫画导入对话框、目录批量导入、`MangaModule` 与桌面 CTL 的 PDF 分支；
  PDF 路由/读账/集成测试。PDF 现在统一落到 `ImportCarrier.unsupported` 被如实拒绝。
- **Reading statistics**：`lib/src/stats/`（7 个文件）、统计中心与阅读统计页、全部 `stat_*` 组件、
  阅读器统计侧栏、阅读器底部状态行（计时/字数读数）、`manga_reading_stats.dart`、
  `stat_contribution_heatmap.dart`；漫画阅读器的 `StudyClock` / `ReadUnitLedger` 写入与字数/页数换算；
  设置中的阅读统计段、首页统计入口、统计诊断导出、统计快捷键、阅读器控制布局的统计/计时项、
  阅读计时开关；`AppModel` / `PreferencesRepository` 的统计偏好；
  书架删除 / 历史批量 / Local source / CTL 的「同时删除统计」选项与进度重置里的学习记录选项；
  统计 UI/聚合测试，以及 live schema 没有 legacy 统计表而必然失败的 DB 统计测试。
- **浏览器扩展**：`tools/browser-extension/` 全目录（manifest/options/locales/测试/vendor）、
  扩展镜像同步工具、扩展管理页、安装助手/服务、浏览器探测、`AppModel` 兼容桩与 `fushiApi*` 偏好、
  `manga_external_mokuro_path` 之外的扩展路径偏好、相关测试与 `.gitignore` 例外。
- **OCR / AI 推理**：`flutter_onnxruntime`（app 依赖 + workspace override）、
  `external_mokuro_runner.dart`、`.ocr-box` 渲染函数/字符区域/句子分组、overlay 中的 OCR CSS/JS
  （`__mangaReplaceOcr`、OCR 命中/选词/barrier/Shift 悬停）、漫画阅读器的 OCR 视口/补挂代码、
  `manga_external_mokuro_path` 的路径重基声明。
- **依赖/资源/测试**：`pubspec.lock` 移除 `pdfrx`、`pdfrx_engine`、`pdfium_dart`、`pdfium_flutter`、
  `flutter_onnxruntime`；删除对应的测试、集成测试与 fixture；`windows/CMakeLists.txt` 移除 pdfium
  native-asset 排除规则。

### 兼容保留（有意保留）

- `ModuleId.browserExtension` / `HomeTab.browserExtension` 枚举值与模块映射、导航项文案/图标：
  规格要求保留旧枚举值，避免旧偏好/深链解析崩溃；运行时 `isInMyComicScope` 使其永远不可见。
  `FushiIcons.browserExtension` 仍被 Mihon 扩展 UI 当通用图标使用。
- `BookFormat.pdf`、`LibraryCtlKind.pdf`、`book_file_location.dart` 的 pdf 分支：仅用于读取旧库行，
  不再有导入或阅读器入口；旧 PDF 行路由回退到书源，打不开时按普通失败处理。
- `reading_statistics` / `study_segments` / `activity_events` 等 DB 表与 `fushi_core` DAO 原样保留：
  schema 不变（spec 用户故事 69），同步/备份/`fushi_server` 仍共享这些表；未删表、未改 schema。
- `.mokuro` 数据路径：payload/sidecar 下载与 Local source 读取保留；删除的只是端上 OCR 推理与
  已无入口的文本层渲染。
- `auto_ocr` 列/参数形状、`manga_ocr_*` / `reading_goal_*` / `manga_external_mokuro_path` 等旧偏好键
  与 `reader_selection_scripts.dart`：冻结键/兼容字段保留；旧 reader override JSON 仍可解析。
- Windows 原生截屏 OCR / 悬浮球 C++（`screen_ocr_*`、`system_ocr_*`）保留：ticket 04 已明确把
  `native/galgame_hook` 与相关原生面留待后续 native 收口；此处删除会破坏 Windows runner 链接。
- 安装器的旧 ONNX/PDFium 文件清理行保留：那是升级时清除历史残留，不是随包资源。
- `ci/patches/hosted/pdfrx_engine-0.4.4/` 未删：本 ticket 不改 `ci/patches`；不再被依赖后可在后续清理。

### 验证

- `cd fushi && dart run slang`：通过。
- `flutter analyze`：0 errors（200 warnings/infos，低于 ticket 04 约 200 条的基线）。
- 相关测试：**545 passed，1 failed**（唯一失败为本节「已知失败」里的
  `activity_events_test` 视频改名用例，属 ticket 04 遗留，与本次删除无关）。覆盖：
  - 漫画 overlay/手势/JS：`manga_overlay_html_test`、`manga_overlay_background_tap_zone_test`、
    `manga_pan_ownership_test`、`manga_reader_transforms_js_test`、swipe/pinch/wheel/zoom 各 JS 测试。
  - 删除/重置 UI：`manga_shelf_batch_remove_test`、`manga_series_page_unified_removal_test`、
    `manga_series_page_batch_delete_downloads_test`、`local_source_selection_batch_test`、
    `manga_reset_reading_state_dialog_test`、`library_progress_reset_dialog_test`、
    `fushi_destructive_confirm_dialog_test`。
  - 路由/注册/设置/布局：`manga_routing_guard_test`、`book_history_split_guard_test`、
    `manga_source_registration_test`、`settings_schema_coverage_test`、`settings_renderer_test`、
    `reader_control_layout_test`、`home_page_tabs_test`。
  - 导入/存储/i18n/审计：`test/media/import`、`test/media/manga` 的导入用例、
    `app_paths_portable_state_test`、`path_rebase_coverage_guard_test`、`test/tools/audit`、
    `test/i18n`、`test/language`。
- `flutter build windows --debug --no-pub`：**通过**（255.5s，产物
  `build/windows/x64/runner/Debug/fushi.exe`；NuGet 从主 checkout 的
  `.dart_tool/nuget/nuget.exe` 注入 PATH）。
- 冷启动冒烟：构建产物启动后 12s 进程仍存活（`alive=True`）。

### 已知失败 / 延迟项（非本 ticket 引入）

- ticket 04 遗留的静态守卫仍红，未在本 ticket 修改对应源文件：
  `test/tools/test_source_path_exists_guard_test.dart`（引用已删的词典/视频/小说/有声书页面）、
  `test/tools/book_format_discipline_guard_test.dart` 的「裸字符串比较 format」用例、
  `test/models/ai_module_gate_guard_test.dart`、`test/models/app_model_audit_hardening_guard_test.dart`、
  `test/models/theme_single_factory_guard_test.dart`、`test/models/prerelease_only_capability_test.dart`、
  `test/models/app_model_storage_permission_test.dart`、`test/models/app_model_init_retry_race_guard_test.dart`、
  `test/pages/module_settings_header_alignment_guard_test.dart` 的词典页用例、
  `test/database/activity_events_test.dart` 的视频改名用例、`mihon_source_browse_page_test`（4 条）。
  记录待 ticket 12 复核。
- `reader_selection_scripts.dart` 等 ticket 04 查词/选区 JS 仍无生产调用；本 ticket 已确认 manga
  overlay 不再注入它们，但整体删除属查词域清理，未在本 ticket 扩大范围。
- Windows 原生截屏 OCR / 悬浮球 C++ 与 `native/galgame_hook` 的收口仍待后续 native 清理。
