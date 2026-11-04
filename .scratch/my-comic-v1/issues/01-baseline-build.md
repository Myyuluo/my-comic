# 01: Baseline build + repo snapshot

**What to build:** 在 Windows 上从源码构建并启动 Fushi v3.0.0，作为后续所有改动的可运行基线；建立 my-comic 本地仓库快照和构建记录。此 ticket 不改变任何用户可见功能。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 使用项目专用 Flutter 3.47.6 SDK（不污染全局 SDK），PATH 指向正确
- [ ] 获取 Fushi v3.0.0 源码快照；不推送完整 Fushi 历史
- [ ] 建立仓库快照，包含 `UPSTREAM.md`、LICENSE、`.gitignore`；`*.tachibk`、构建产物、本地 fixture 被忽略
- [ ] `flutter build windows --release` 成功，基线 exe 能启动
- [ ] 记录基线安装包/exe 体积和各原生库占用
- [ ] 不做删除或功能修改
