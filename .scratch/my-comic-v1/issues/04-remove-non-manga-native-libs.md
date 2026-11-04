# 04: 删除非漫画原生库并测量体积

**What to build:** 在非漫画 UI 移除后，删除或禁用不再需要的原生库（libmpv、libtorrent、ONNX Runtime、ffmpeg 等），并验证漫画功能不受影响、安装包体积下降。

**Blocked by:** 02: Manga-only shell：移除非漫画域；03: 移除阅读器内嵌的非漫画控件

**Status:** resolved

- [x] 记录删除前后的安装包/exe 体积
- [x] libmpv、libtorrent、ONNX Runtime、ffmpeg 已删除或禁用；如某项仍被漫画功能依赖，保留并记录原因
- [x] Extension 安装、搜索、阅读正常
- [x] HTTP Chapter Download 正常；BT/torrent 不存在
- [x] Local source（CBZ/ZIP/文件夹/.mokuro）正常
- [x] 无缺失 DLL/runtime 错误

## Comments

- Built at commit b34c04e9; see docs/agent/baseline-build.md
- 体积 357.3 MiB → 104.3 MiB（-70.8%），DLL 160 → 18
- Local source CBZ/ZIP/folder/.mokuro 冒烟通过；HTTP 下载单测 12 项通过
- Extension runtime / 真实 HTTP 下载 E2E 阻塞，留给 ticket 08
- 保留的 non-manga Dart 包（media_kit、pdfrx、flutter_onnxruntime、flutter_webrtc、fushi_torrent、fushi_dictionary）仅因残留死代码可编译；原生库已不在 bundle 中
