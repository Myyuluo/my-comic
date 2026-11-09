# 13: 清理数据库（Mihon 对齐）

**What to build:** 把「清除数据库」改为 Mihon 风格的「清理数据库」：列出有非书架记录的 Source 及数量，可多选；默认开启「保留有阅读记录的作品」；关闭时警告已读/进度会丢失。执行时删除所选 Source 的 membership=false Manga 行及其章节/进度/已读/下载索引；开关开启时保留有已读或阅读进度的非书架作品；只删除被清理作品的 History；保留书架作品/History、设置、源、扩展与磁盘文件。显示进度与结果，无需重启。

**Blocked by:** 01（Library membership 基础）、10（导入非书架行与 History 修复）

**Status:** ready-for-agent

- [ ] 设置项显示为「清理数据库」。
- [ ] 确认界面列出有非书架记录的 Source 及数量，可多选。
- [ ] 默认开启「保留有阅读记录的作品」；关闭时显示明确警告。
- [ ] 删除所选 Source 的 membership=false Manga 行及其章节/进度/已读/下载索引。
- [ ] 开关开启时保留有已读或阅读进度的非书架作品。
- [ ] 只删除被清理作品对应的 History，保留书架作品 History。
- [ ] 保留书架作品、设置、源、扩展、磁盘下载文件与 Local source 文件。
- [ ] 确认框显示将删除的作品/History 数量；执行时显示进度，完成后 toast 结果。
- [ ] 不需要重启。
- [ ] 页面级与服务测试覆盖 Source 选择、开关、删除/保留范围、History 范围与保留项。
