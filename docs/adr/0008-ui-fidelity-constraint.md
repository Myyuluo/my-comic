---
status: accepted
---

# UI 必须与 Fushi v3.0.0 使用同一套设计和审美

用户明确要求 my-comic 的 UI 与 Fushi v3.0.0 使用同一套设计和审美。可以隐藏或移除非漫画入口，但不得替换、重写、简化 Fushi 的原版 shell、组件、主题或布局；任何 UI 改动必须先获得用户明确许可，并以 Fushi v3.0.0 的截图/组件为对照。

ticket 11 用简化版 `home_shell.dart` 替换原版 `home_page.dart`，违反了此约束；恢复工作由 ticket 16 跟踪。

manga-backup-import-ux 的导入完成 / 创建备份结果弹窗重排、导入作品封面远程回退，以及作品页的缺失来源标签与提示（「来源未安装：<名称>」与本地章节说明），是用户在 2026-11-10 逐项明确批准的 UI 改动。实现只复用 Fushi v3.0.0 的弹窗、卡片、notice、hero icon 与 spacing tokens，封面沿用现有图片缓存与占位组件，不引入新的视觉语言；Fushi 的 shell、组件、主题与布局均未替换或简化。

## Amendment 2026-11-10（manga-library-membership）

用户在 manga-library-membership spec 中逐项批准了以下 UI 改动。实现只复用 Fushi v3.0.0 的既有设置行、对话框、开关、警告、进度框、toast、SnackBar 与 spacing tokens，不引入新的视觉语言：

- **移出书架文案**：单部与批量确认文案明确「只移出书架；阅读进度、已读标记、已下载章节与 History 会保留」；「同时删除本地文件」与「同时删除统计数据」仍按破坏性选项说明。
- **清理数据库 UI**：设置页动作更名为「清理数据库」；确认框按 Source 多选并显示数量，默认开启「保留有阅读记录的作品」，关闭时显示已读/进度会丢失的警告，并显示将删除的作品与 History 数量；执行时复用现有进度框与结果 toast。
- **加入书架提示**：非书架 Manga 下载完成后显示非模态的「加入书架？」提示（SnackBar），同一轮打开的页面最多提示一次；不遮挡阅读、不自动加入，用户点击后才执行加入。
