# 02: Manga-only shell：移除非漫画域

**What to build:** 把 Fushi 变成只看得到漫画的 my-comic shell：移除所有非漫画域的入口、路由、设置和资源，保留漫画 Library、Sources、Reader、Downloads、Settings。

**Blocked by:** 01: Baseline build + repo snapshot

**Status:** resolved

- [x] 导航中不再有小说/EPUB、视频/Aniyomi、有声书、词典/查词、Anki/SRS、galgame、AI/OCR、BT、云同步/Interconnect、Fushi Server 入口
- [x] Settings 不再暴露非漫画 sections
- [x] 移除 telemetry、更新检查、自动更新
- [x] 移除相关 assets/strings/routes，不留下可进入的隐藏入口
- [x] 漫画 Library、Sources、Reader、Downloads、Settings 仍可用
- [x] Windows build 成功

## Comments

Built at commit ff3f2df0; see docs/agent/baseline-build.md
