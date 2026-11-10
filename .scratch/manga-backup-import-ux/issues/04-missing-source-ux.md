# 04: 缺失来源的名称与中文提示

**What to build:** 对确实未安装的来源，导入时保存备份里的来源名称；作品页显示「来源未安装：<名称>」而不是 `mihon.unavailable`，并说明当前只能看本机已保存的章节；章节打开/下载失败给出中文提示，引导用户自行安装扩展。不提供跳转扩展商店的按钮，不自动安装。

**Blocked by:** 03（已安装扩展的导入作品恢复可读）

**Status:** resolved

- [x] 导入时把备份 `BackupSource` 的 sourceId → 名称映射持久化到占位条目的 source metadata（可选字段）。
- [x] 来源名称未知或旧备份缺少名称时，UI 退化为「来源未安装」，不显示内部占位值。
- [x] 作品页在来源缺失时显示「来源未安装：<名称>」，不显示 `mihon.unavailable`。
- [x] 作品页说明当前只展示本机已保存的章节；刷新/阅读需要安装扩展。
- [x] 章节打开失败时显示中文提示「来源未安装，请先安装对应扩展后重试」。
- [x] 章节下载失败时显示同一类中文提示，不再直接展示英文内部错误。
- [x] 缺失来源的作品仍保留在 Library，不被隐藏或删除。
- [x] 不新增「打开扩展商店」按钮，不自动安装扩展。
- [x] 安装扩展后再次打开作品即可阅读，不需要重启或重新导入。
- [x] 页面级与导入服务测试覆盖名称持久化、缺失来源标签、中文错误提示与安装后的恢复路径。

## Answer

Implemented in `017cff03`, merged as `274fd950`. 导入时只有「备份里有、本机无 Source 行」的作品才把备份 `BackupSource` 的显示名写进占位条目——`OnlineMangaLibraryEntry` 新增可选 `sourceName` 字段（`toJson` 仅在非空时写出，旧条目/旧描述符解析为 null；空白名经共享 `trimmedOrNull` 归一为 null），已安装/已停用的来源不写（名称由 Source 表解析）。`kUnavailableMihonExtensionPackage` 迁到书架条目模型、由导入服务重新导出，作品页据此识别占位来源。作品页 hero 上方来源名不再露出 `mihon.unavailable`：有备份名显示「来源未安装：<名称>」，名称未知或旧备份退化为「来源未安装」；来源名解析确认失败后才在简介后显示 warning `FushiInlineNotice`（标题同上，正文「当前只显示本机已保存的章节；刷新和阅读需要先安装对应扩展。」），解析成功（含票 03 的数字 sourceId 回退）则显示真实来源名且不闪现缺失提示。作品仍保留在 Library，未新增「打开扩展商店」按钮、不自动安装。章节打开失败走 `OnlineMangaUnavailable.userMessage`，`sourceDisabled` 映射为「来源未安装，请先安装对应扩展后重试」；下载失败把 `'$error'` 落库的原始英文串由 `describeOnlineSourceErrorText` 的缺失来源标记归一为同一中文提示，英文原文仍留在 message/诊断。新增 `fushi/test/backup_import/mihon_backup_missing_source_name_test.dart`（4 项：名称持久化、旧备份退化、已安装来源不写占位名、旧描述符兼容）与 `fushi/test/media/manga/manga_series_missing_source_test.dart`（5 项：命名缺失来源 + 说明 + 缓存章节、旧条目退化、已安装但已停用的来源同样按缺失展示、来源恢复后显示真实名称、章节打开中文提示），并扩展 `online_manga_error_display_test.dart`（打开与下载失败的中文归一；`online_source_error_text_test.dart` 并不存在，未修改）。ticket 07 review 修正：作品页不再只按 `mihon.unavailable` 占位包判断缺失——运行时解析失败时（含已安装但停用的 Source）同样按缺失来源展示，名称优先取 Source 表（停用行仍保留名称），其次取持久化的 `sourceName`，不再回退显示原始扩展包名。
