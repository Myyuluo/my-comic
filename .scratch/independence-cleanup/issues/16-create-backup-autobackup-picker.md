# 16: 创建备份保存对话框默认打开 autobackup

**What to build:** 点击「创建备份」页底部的「创建」后，原生保存对话框默认打开 `<Content root>/autobackup`，与备份导入的初始目录一致。

**Blocked by:** None（post-review regression）

**Status:** resolved

## Root cause

`create_backup_page.dart` 已经传了 `initialDirectory: appPaths.autobackupRoot.path`，但走的是 `FilePicker.platform.saveFile`。它在 Windows 上的实现使用旧版 `GetSaveFileNameW`；Windows 7+ 在对话框出现过一次后会优先使用“上次的文件夹”，忽略 `lpstrInitialDir`。所以初始目录只在第一次生效。

## Fix

- `.tachibk` 保存对话框改用 `file_selector` 的 `getSaveLocation`（Windows `IFileSaveDialog` + `SetFolder`），可靠设置初始目录。
- 保留 `CreateBackupSavePathPicker` 测试注入；默认文件名与 `.tachibk` 过滤不变。
- 只改创建备份这一处；其他保存对话框不动。

## Verification

- `flutter test --no-pub test/backup_import/create_backup_page_test.dart`：16 条全部通过，包含「save dialog defaults to the Backup directory」。
- `flutter analyze --no-pub`：0 errors（142 条既有 warning/info）。
- 重新构建后点「创建」，保存对话框默认打开 `C:\Users\49642\Documents\MyComic\autobackup`。
