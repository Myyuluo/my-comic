# 19: 移除内置 Mokuro.moe Source

**What to build:** 应用不再内置任何 Source。Mokuro.moe 从在线源和发现 › 浏览来源中消失；在线源为空时显示现有的 `mihon_source_empty` 提示，不加按钮。Mokuro 的目录页 / 对话框 / 磁贴 / 客户端 / 下载器 / 下载任务分支、设置里的在线目录 URL、偏好键和同步键全部移除。应用启动时清理旧的 mokuro 下载任务行；已下载的漫画保留可读；mokuro.moe OCR sidecar 与本地 `.mokuro` 导入 / OCR / 文件关联保持不变。完成后用户在任何入口都看不到 Mokuro.moe，旧的 Mokuro 下载任务不会重试。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 在线源不再显示 Mokuro.moe 行或开关；扩展提供的 Source 仍正常显示。
- [ ] 发现 › 浏览来源不再显示 Mokuro.moe 磁贴；OPDS 与扩展源入口保留。
- [ ] 在线源为空时显示现有 `mihon_source_empty` 提示，没有动作按钮。
- [ ] 设置里不再有在线目录 URL；Mokuro 偏好键与同步键不再存在。
- [ ] 下载服务不再有 Mokuro 任务分支；启动时清理旧的 mokuro 下载任务行，已下载漫画保留可读。
- [ ] mokuro.moe OCR sidecar 与本地 `.mokuro` 导入 / OCR / 文件关联不变。
- [ ] Mokuro 专属测试已删除或更新；构建与测试通过。
