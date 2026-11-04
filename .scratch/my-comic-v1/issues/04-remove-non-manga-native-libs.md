# 04: 删除非漫画原生库并测量体积

**What to build:** 在非漫画 UI 移除后，删除或禁用不再需要的原生库（libmpv、libtorrent、ONNX Runtime、ffmpeg 等），并验证漫画功能不受影响、安装包体积下降。

**Blocked by:** 02: Manga-only shell：移除非漫画域；03: 移除阅读器内嵌的非漫画控件

**Status:** ready-for-agent

- [ ] 记录删除前后的安装包/exe 体积
- [ ] libmpv、libtorrent、ONNX Runtime、ffmpeg 已删除或禁用；如某项仍被漫画功能依赖，保留并记录原因
- [ ] Extension 安装、搜索、阅读正常
- [ ] HTTP Chapter Download 正常；BT/torrent 不存在
- [ ] Local source（CBZ/ZIP/文件夹/.mokuro）正常
- [ ] 无缺失 DLL/runtime 错误
