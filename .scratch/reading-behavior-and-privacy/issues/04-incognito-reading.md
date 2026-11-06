# 04: 无痕阅读开关

**What to build:** 在「设置 → 系统与关于 → 更新提醒」分组末尾新增「无痕阅读」开关，副标题「暂停记录阅读历史」，默认关闭（即默认记录 History）。开启后只暂停新增 History 记录；Reading progress/续读、Tracking 与统计保持正常；已有 History 保留，不隐藏、不清空。开关对在线漫画与本地卷都生效，切换后立即生效；作为设备本地偏好，不随 Profile/备份同步。除设置里的开关外，不新增其它无痕提示。

**Blocked by:** None（can start immediately；与 ticket 03 共用「更新提醒」设置分组，合并时注意同一文件的局部冲突）

**Status:** ready-for-agent

- [ ] 设置里「更新提醒」组末尾显示「无痕阅读」开关，副标题为「暂停记录阅读历史」，默认关闭。
- [ ] 开启后不再新增 History 记录；关闭后恢复记录。
- [ ] Reading progress/续读、Tracking 与统计不受影响。
- [ ] 已有 History 保留，不隐藏、不清空。
- [ ] 对在线漫画与本地卷都生效；切换后立即生效。
- [ ] 开关为设备本地偏好，不进入 Profile/备份。
- [ ] 除设置开关外没有额外的无痕标识或提示。
- [ ] 开关文案从字符串资源加载，17 个 locale 完整。
- [ ] 相关测试覆盖 History 写入与 Reading progress 的数据结果，`flutter analyze` 与定向测试通过。
