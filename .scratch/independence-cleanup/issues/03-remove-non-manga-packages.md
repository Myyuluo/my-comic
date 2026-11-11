# 03: 删除独立非漫画包与 engine 子域

**What to build:** 删除不再属于漫画域的独立 workspace 包和 engine 子域，让依赖图和编译面只剩漫画功能。

**Blocked by:** 04、05

**Status:** resolved

- [x] 删除 `fushi_anki`、`fushi_audio`、`fushi_srs`、`fushi_dictionary`、`fushi_server`、`fushi_p2p` 包。
- [x] 删除 `fushi_engine` 中的非漫画子域（如 ai、anki_sync、asr、dictionary、epub、leaderboard、audiobook、video、collections、srs、tts、sync、mining），保留漫画、Source、下载、本地图源、历史等共享能力。
- [x] 更新根 workspace/Melos、`pubspec.yaml`、`pubspec.lock`、CI 与构建脚本。
- [x] 删除仅被这些包使用的依赖和原生构建入口；与 04 协调原生库归属，避免重复删除。
- [x] 保留 `fushi_core` 的漫画 schema、`fushi_platform`（如仍被使用）与 `fushi_cli` 外壳；`fushi_cli` 的非漫画命令在 04 清理。
- [x] 保留 `ModuleId`/`HomeTab` 旧枚举值与旧偏好键，不因删包改动兼容面。
- [x] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；无 import 指向已删除包。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。如果某个被删子域仍被漫画代码共享，先抽出最小共享模块再删，不要连坐漫画功能。本 ticket 排在 05 之后，因为 05 会移除最后的 `fushi_dictionary` / 浏览器扩展消费者；不要在 05 合并前删包，否则编译会断。

## 实现记录

### 删除的 workspace 包

- `packages/fushi_anki`、`packages/fushi_audio`、`packages/fushi_srs`、
  `packages/fushi_dictionary`、`packages/fushi_server`、`packages/fushi_p2p`
  （整包删除；根 `pubspec.yaml` workspace 列表与 `pubspec.lock` 已同步）。

### 删除的 `fushi_engine` 子域

- 整目录：`ai/`、`anki_sync/`、`asr/`、`dictionary/`、`epub/`、`feedback/`、
  `leaderboard/`、`mining/`、`profile/`、`srs/`、`stats/`、`sync/`、`tts/`、
  `media/audiobook/`、`media/audio/`、`media/audio_cd/`、`media/collections/`、
  `media/import/`、`media/tracking/`、`media/video/`。
- 仅服务已删域的散件：`models/dictionary_directory.dart`、
  `models/local_audio_db_entry.dart`、`models/local_audio_source_pref.dart`、
  `media/image_mosaic.dart`、`media/manga/manga_page_crop.dart`、
  `utils/misc/desktop_audio_clipper.dart`、`utils/misc/snapshot_audio_coverage.dart`、
  `utils/misc/synchronized_video_exporter.dart`。
- 对应 engine 测试目录/用例（ai / feedback / leaderboard / srs / tts /
  audiobook / anki_sync / mosaic / crop）一并删除；engine `dart test` 现为 95 条全绿。

### 抽出的最小共享模块（漫画仍在使用）

- `media/manga/book_storage.dart`：原 `epub/epub_storage.dart` 的 `EpubStorage`
  （下载库书根、删书目录、测试注入点），附最小化的插图表缓存清理。
- `media/manga/book_title_conflict.dart`：原 `epub/book_title_conflict.dart`
  （`DuplicatePolicy` / `resolveDuplicateTitle`），漫画导入查重仍在用。
- `media/manga/shelf_sort.dart`：原 `media/collections/shelf_sort.dart`
  （书架排序纯函数），实际是漫画域，迁移路径而非删代码。
- `media/manga/epub_book.dart` + `media/manga/epub_parser.dart`：原 `epub/`
  的解析/模型层。仅保留漫画图片型 EPUB 导入所需能力；ISBN 解析与 `epub_importer`
  删除，`EpubStorage`/`book_title_conflict`/`reader_resource_host` 抽出。
- `foundation/reader_resource_host.dart`：`kReaderResourceHost` 常量。
- `utils/misc/study_char_count.dart`：章节字数/阅读位置归一化口径，漫画阅读器仍依赖。
- `utils/misc/ttu_filename.dart`：只保留 `sanitizeTtuFilename`（书籍跨设备身份键）。
- `media/manga/reader_position.dart`：从 `fushi_audio` 抽出 `ReaderPosition` /
  `ReaderPositionRepository` / `ReaderHistoryPolicy`（漫画进度/历史核心状态）。
- `media/manga/bookmark_repository.dart`：从 `fushi_audio` 抽出 `Bookmark` /
  `BookmarkRepository`（漫画书签）。
- `media/manga/reader_language.dart`：原 `fushi_dictionary` 的 `Language` /
  `JapaneseLanguage` 最小身份对象（书架 provider family key；`initialise()` 空实现）。
- `media/manga/mihon_tracking_compat.dart`：Mihon `.tachibk` 备份互认所需的
  tracking 词表（provider / 媒体类型 / 追踪种类 / 进度模式），值冻结。
- `media/manga/delete_scope.dart`：从 `sync/deletion_propagation.dart` 抽出
  `DeleteScope`（删除确认框仍使用；本机墓碑记账保留，远端发布已删）。
- `media/manga/panel_detection.dart` 内联最小 `OnnxTensor`/`OnnxSession` 抽象，
  去掉对 `fushi_asr_core` 的依赖；宿主未装配检测器时行为仍是 unavailable。
- app 侧 `lib/src/models/fushi_text_selection.dart`：原 `fushi_dictionary` 的
  `FushiTextSelection`（`MediaSource` 当前句状态仍在用），从 `models.dart`/`utils.dart` 导出。

### app 侧依赖清理

- 删除对已删包的 import/依赖：`fushi_anki`、`fushi_audio`、`fushi_srs`、
  `fushi_dictionary`、`fushi_asr_core`、`fushi_asr_subtitles`。
- 漫画共享代码改接新模块；删除 SRT / 有声书残留分支：`ReaderFushiSource` 的
  SRT 身份、删除、原件清理；书架/作品页/阅读器/历史页/卡片中的 SRT 卡与远端占位；
  `srtBooksProvider` 及其测试 override；听书反向跳转设置；SRT 标签 provider 调用。
- 删除查词/AI/同步残留：engine bindings 的词典 FFI 钩子、floating dict channel、
  AI key health prefs、usage stats/install attestation 与心跳、Android app challenge
  proxy 客户端（Windows-only 构建，`AndroidMihonRuntime` 不再配置该代理）。
- 删除已无消费者的 app 文件：`ctl_library_import.dart`、`ctl_library_routes.dart`
  （含 manage/shelf/tasks）、`reader_source_locator.dart`、`reader_study_unit_script.dart`、
  `floating_dict_channel.dart`、`floating_overlay_channel.dart`、`srt_book_reimport.dart`、
  `sidecar_finder.dart`、`audiobook_health_summary.dart`、`install_attestation.dart`、
  `usage_heartbeat.dart`、`app_native_proxy.dart`。
- 备份兼容面保留：Mihon backup 的 tracking 行仍按原词表导入/导出；`ModuleId` /
  `HomeTab` 枚举与旧偏好键未改（`isInMyComicScope` 仍只启用漫画域）。

### 依赖与 workspace 更新

- 根 `pubspec.yaml`：移除 6 个包 workspace 成员；移除 `fushi_asr_core` /
  `archive` / `media_kit_video` 的 `dependency_overrides`（不再被任何包使用）。
- `packages/fushi_engine/pubspec.yaml`：依赖收敛为
  `fushi_core / archive / crypto / dio / drift / ffi / html / http / image / meta / path / xml`；
  `fushi_audio`、`fushi_anki`、`fushi_dictionary`、`fushi_platform`、`fushi_p2p`、
  `fushi_srs`、`fushi_asr_*` 全部移除。
- `fushi/pubspec.yaml`：移除已删包、ASR git 依赖，以及只服务已删域的
  `audio_service`、`audio_session`、`just_audio`、`record`、`flutter_charset_detector`、
  `media_kit`、`media_kit_video`、`kana_kit`、`recase`、`async_zip`、`flutter_archive`
  与对应测试专用依赖。
- `pubspec.lock` 由 `flutter pub get` 重新生成（不再含 `fushi_*` / ASR / media_kit 家族）。

### CI 与构建脚本

- 删除 `.github/workflows/server-gate.yml`、`native-fsrs-gate.yml`、
  `native-fushidicts-gate.yml`、`native-p2p-gate.yml`、`native-cache-warm.yml`
  （后者平台裁剪后只剩 anki-sync 预热）与 `.github/actions/setup-fushi-anki-sync`。
- `build-multiplatform.yml` / `release-desktop.yml`：移除 `fushi_p2p` DLL、
  `fushi_fsrs` DLL、`fushi-anki-sync` helper 的构建/校验/持久库步骤与路径触发；
  同时移除已在前序 ticket 删除源码的 libtorrent / fushi_aacs / fushidicts
  构建与 bundle 校验步骤；`native-store-names` 收敛为 Windows 的 Mihon runtime
  与 galgame helper 两个产物。保留 Windows build、Mihon runtime、galgame helper、
  安装包流程与发布策略要求的所有字符串。
- `tool/` 下 ASR 模型工具（`asr_build_greedy_graph.dart`、`asr_convert_fp16.dart`）删除。

### 验证

- `cd fushi && dart run slang`：通过。
- `flutter analyze`：**0 errors**（154 warnings/infos，低于 ticket 05 的约 200 条基线）。
- `packages/fushi_engine` `dart analyze`：0 issues；`dart test`：**95 passed**。
- `packages/fushi_core` `dart analyze`：9 条既有 info；`fushi_cli` / `fushi_platform`：0 issues。
- 直接受影响的 app 测试（manga 书架/作品页/阅读器/历史/本地图源/下载/Backup/
  storage/import/i18n/audit）：**全部通过**，仅 ticket 04 已记录的两条既有失败
  （`manga_library_sort_menu_toggle_test`、`manga_library_tag_tabs_test`）。
- 全量 `flutter test`（最终树）：**7068 passed / 251 failed / 15 skipped**。
  失败集中在 ticket 04/05 已删除非漫画表面留下、尚未清理的守卫与 DB fixture
  （见下）；与本 ticket 改动文件相关的失败只有三条已记录基线：
  `drop_classification_test`（PDF/video 用例）、
  `manga_library_sort_menu_toggle_test`、`manga_library_tag_tabs_test`。
- `flutter build windows --debug`：**通过**（NuGet 从主 checkout `.dart_tool/nuget`
  注入；产物 `build/windows/x64/runner/Debug/fushi.exe`）；冷启动冒烟进程存活。

### 已知失败 / 延迟项（非本 ticket 引入或属于 ticket 12 复核）

- ticket 04 已记录的既有失败仍在：`activity_events_test` 视频改名用例、
  `mihon_source_browse_page_test`（4 条）、书架排序菜单 / 标签页签两条、
  `app_model_audit_hardening_guard`、`ai_module_gate_guard`、
  `theme_single_factory_guard`、`prerelease_only_capability`、
  `app_model_storage_permission`、`app_model_init_retry_race`、
  `module_settings_header_alignment_guard`、`book_format_discipline_guard`、
  `test_source_path_exists_guard`。
- ticket 04/05 删除非漫画页面/JS 后遗留的静态守卫与 fixture：大量
  `test/reader/*` JS 守卫引用已删文件（`reader_pagination_scripts.dart`、
  `audiobook/highlight_bridge.dart` 等）、`test/pages/*` 引用 video/dictionary/
  audiobook 页面、settings 守卫引用已删设置页、DB 测试假设 `srt_books` /
  `collections` / `videos` 表仍在测试 schema 中（live schema 已是漫画-only 37 表）。
- `mihon_backup_app_settings_export_test` 的 sensitive 设置导出语义在 ticket 04
  的 `PrefRedactionPolicy` 合并后与测试期望不一致（所有 device-local/credential
  都被无条件剔除）；属 ticket 04 遗留，记录待 ticket 12 复核。
- `tests_for_changes_guard` / `test_file_shards` / integration-test 规模哨兵因
  ticket 02/04/05 大范围删除测试文件而低于旧下界；本 ticket 未改这些守卫的
  业务判据，记录待 ticket 12 统一校准。
- Windows 原生收口（`native/galgame_hook`、截屏 OCR 等）仍按 ticket 04 约定留待后续；
  本 ticket 未改 `third_party/` 与 `ci/patches/`。
