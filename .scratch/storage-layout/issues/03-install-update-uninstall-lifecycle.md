# 03: Install/update/uninstall lifecycle

**What to build:** Windows 安装器保留标准「选择安装位置」页和可写性预检，移除自定义「数据存储位置」页与 `data_root.bootstrap`。应用内更新原地覆盖安装并保留 `userdata`；卸载删除 `userdata`（包括回退的 `%LOCALAPPDATA%\MyComic\userdata`），但完全不碰 Content root。安装目录不可写时，程序状态回退到用户目录并明确提示便携状态不随安装目录走。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 安装器仍显示标准安装位置选择页，并能拦截/警告不可写目录
- [ ] 自定义数据位置页与 `data_root.bootstrap` 不再出现，首启也不再消费该文件
- [ ] 升级/原地覆盖安装后 `userdata` 中的数据库、设置、扩展保留
- [ ] 卸载删除 `userdata`（含回退位置），Content root 的 `downloads`/`autobackup`/`localcomic` 保留
- [ ] 打包与安装脚本守卫测试确认 `userdata` 不在 `[Files]`/`[InstallDelete]`，且在 `[UninstallDelete]`
- [ ] 不可写安装目录下回退到 `%LOCALAPPDATA%\MyComic\userdata` 并有可见提示
