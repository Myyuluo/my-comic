# 09: 换品牌、License、打包

**What to build:** 把应用改为 my-comic 独立品牌，补齐 GPL-3.0/第三方 notices 和安装器，准备发布。

**Blocked by:** 08: 漫画功能与 Extension 兼容验收

**Status:** ready-for-agent

- [ ] 应用名称、图标、applicationId 为 my-comic；UI 和安装器不再出现 Fushi/Mihon 品牌
- [ ] About 显示 GPL-3.0、基于 Fushi v3.0.0、第三方 notices
- [ ] README/UPSTREAM 写清来源、license、不托管 Extension
- [ ] 安装器按用户安装，干净机器可安装
- [ ] 仓库快照不含 Fushi 完整历史、`.tachibk` 或本地 fixture
- [ ] Windows build 和 installer 成功
