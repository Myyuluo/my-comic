# 11: Backup directory

**What to build:** `.tachibk` 备份的导入文件选择器默认打开 Content root 下的 `autobackup`，用户可以从这里直接选备份。设置里提供「导出 `.tachibk`」入口，但先置灰/提示未完成；`.fushi.zip` 仍是 App snapshot，保持现状、不放进 `autobackup`；不做定时自动备份。

**Blocked by:** 01

**Status:** resolved

- [x] `.tachibk` 导入选择器默认定位到 `autobackup`，其中的文件可直接选择
- [x] 设置里能看到「导出 `.tachibk`」入口，但处于未完成/置灰状态
- [x] `.fushi.zip` 行为不变，且不写入 `autobackup`
- [x] 没有定时自动备份任务
- [x] 有测试覆盖默认目录、入口状态与文件格式区分
