# 03: 删除独立非漫画包与 engine 子域

**What to build:** 删除不再属于漫画域的独立 workspace 包和 engine 子域，让依赖图和编译面只剩漫画功能。

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] 删除 `fushi_anki`、`fushi_audio`、`fushi_srs`、`fushi_dictionary`、`fushi_server`、`fushi_p2p` 包。
- [ ] 删除 `fushi_engine` 中的非漫画子域（如 ai、anki_sync、asr、dictionary、epub、leaderboard、audiobook、video、collections、srs、tts、sync、mining），保留漫画、Source、下载、本地图源、历史等共享能力。
- [ ] 更新根 workspace/Melos、`pubspec.yaml`、`pubspec.lock`、CI 与构建脚本。
- [ ] 删除仅被这些包使用的依赖和原生构建入口；与 04 协调原生库归属，避免重复删除。
- [ ] 保留 `fushi_core` 的漫画 schema、`fushi_platform`（如仍被使用）与 `fushi_cli` 外壳；`fushi_cli` 的非漫画命令在 04 清理。
- [ ] 保留 `ModuleId`/`HomeTab` 旧枚举值与旧偏好键，不因删包改动兼容面。
- [ ] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；无 import 指向已删除包。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。如果某个被删子域仍被漫画代码共享，先抽出最小共享模块再删，不要连坐漫画功能。
