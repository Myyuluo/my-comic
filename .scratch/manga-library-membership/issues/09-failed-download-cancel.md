# 09: 失败下载取消

**What to build:** 下载页的失败任务同时提供「重试」与「取消」。取消删除任务行、`.staging` 与 `.cbz.tmp`（以及可能存在的映射容器），不弹二次确认，完成后 toast；其他任务不受影响。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 失败下载行同时显示「重试」与「取消」两个动作。
- [x] 取消删除任务行与 `.staging/<jobId>`、`.cbz.tmp`，并清理可能存在的映射容器。
- [x] 取消不弹二次确认，完成后显示 toast。
- [x] 取消不影响队列中的其他任务或已完成章节。
- [x] 重试仍保持现有语义。
- [x] ADR 0017 的记录同步更新。
- [x] 页面级与服务测试覆盖失败行动作、文件清理、toast 与其他任务不受影响。

## Answer

Implemented in `29a04863`, merged as `23f4d3a1`.

失败下载行现在同时显示「重试」与「取消」。服务层新增失败任务取消路径：删除任务行，并清理该任务的半成品——`.staging/<jobId>`、按章节标题匹配的残留 `{chapter}.cbz.tmp`（含汉化组与 `(2)` 后缀变体），以及可能存在的映射容器；只处理失败行，其他任务与已完成章节不受影响。页面取消不弹二次确认，完成后显示成功 toast。共享 `DownloadTaskCard` 的行尾操作由单个 `quickAction` 改为 `quickActions` 列表，以同时容纳重试与取消两个按钮。ADR 0017 同步记录失败行新语义。重试沿用原有复位重跑语义。

服务测试覆盖删除任务行、staging、临时包、映射容器与其他任务不受影响；页面测试覆盖失败行动作、toast 与其他任务不受影响。ticket 测试套件（`manga_download_service_test.dart`、`downloads_page_test.dart`、`test/media/downloads/`、`i18n_keys_sorted_guard_test.dart`）共 78 项全部通过。
