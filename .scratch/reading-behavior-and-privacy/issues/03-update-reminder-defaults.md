# 03: 更新提醒默认关闭、24 小时、一次性重置

**What to build:** 「漫画新章提醒」默认改为关闭，后台检查间隔从 6 小时改为 24 小时。升级后对已有安装执行一次偏好重置，把已保存的该开关值覆盖为关闭；之后用户在设置里的开关选择正常保存。 「漫画扩展更新提醒」的默认值与行为不变；后台探测仍刷新书架里所有在线漫画（不按订阅筛选），设置文案不变。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 未设置过「漫画新章提醒」时，该开关默认显示为关闭。
- [x] 漫画章节的后台检查最小间隔为 24 小时。
- [x] 升级后一次性把已存的「漫画新章提醒」值重置为关闭。
- [x] 重置之后用户再切换开关，选择能正常持久化。
- [x] 「漫画扩展更新提醒」的默认值与行为保持不变。
- [x] 后台探测仍刷新书架里所有在线漫画，设置文案不变。
- [x] 关闭提醒时后台探测不运行、不产生更新中心条目/通知、不触发后台新章自动下载。
- [x] 手动刷新作品页不依赖这个开关。
- [x] 相关测试已新增/更新，`flutter analyze` 与定向测试通过。

## Comments

- Implemented and merged into `integration/reading-behavior-and-privacy` at merge commit `1893f8ee` (dual-axis review fixes included).
- 一次性重置同时覆盖 live 偏好与每个 Profile 快照；重置 helper 已与工具栏样式迁移共用。
