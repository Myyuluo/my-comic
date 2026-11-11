# 04: 删除非漫画应用面与运行时残留

**What to build:** 删除应用层所有非漫画页面、服务/provider、CTL 端点、深链、运行时装配、原生库和测试；删除旧 Onboarding，为 07 的新向导腾出空间。保留漫画域与 `ModuleId`/`HomeTab` 兼容值。

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] 删除小说/EPUB、视频/游戏/galgame/悬浮球/字幕、词典/查词、Anki/SRS、听书/TTS/ASR、云同步/互联/Server/P2P、AI/在线服务/Profile、反馈/排行榜/迁移/Tracking/首页 dashboard 的页面、服务、provider、模型与测试。
- [ ] 删除 `AppModel` 中非漫画服务构造、`main` 中 Anki/TTS 装配、`HomePage` 死方法与定时器、pair/card-source 调度、非漫画 CTL 路由和外部深链 handler。
- [ ] 删除 Windows 非漫画原生库与 CMake/installer 条目（fushidicts、aacs、torrent、p2p、fsrs、anki_sync、galgame、voice_hook）。
- [ ] 删除旧 Onboarding 页面、步骤、推荐包与依赖；不在这里实现新向导。
- [ ] 删除 `fushi_cli` 中的非漫画命令。
- [ ] 保留 `ModuleId`/`HomeTab` 旧枚举值和旧偏好键，加兼容保留注释。
- [ ] 保留漫画域：Library、Manga 作品页、Reader、Source、Extension store、Discovery、History、Download、Settings、Tag、Backup、Local source。
- [ ] 验证：`flutter analyze`、相关 `flutter test`、`flutter build windows --debug` 通过；冷启动冒烟；书架、阅读、下载、图源、Backup、Local source 仍可用。

**Notes:** 参考 [spec](../spec.md) 与 [ADR 0024](../../../docs/adr/0024-windows-only-independent-identity.md)。旧 Onboarding 删除是临时状态，07 会按三步漫画版重建。
