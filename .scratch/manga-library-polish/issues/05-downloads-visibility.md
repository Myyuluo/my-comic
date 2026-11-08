# 05: 下载页任务可见性（完成隐藏、取消移除、失败继续）

**What to build:** 下载页只展示可操作任务：已完成任务从列表消失但文件保留；取消下载即时删除任务行并清理半成品；失败任务保留在列表，行内操作改为「继续」并可重试。

**Blocked by:** None（can start immediately）

**Status:** resolved

- [x] 已完成任务不再出现在下载页；已下载文件与 Download library 映射保留，仍可阅读。
- [x] 已完成任务行保留在数据库中仅用于作品页「文件缺失」判定，不在下载页展示。
- [x] 取消排队中 / 下载中的任务后，任务行立即从列表消失，不保留「已取消」记录。
- [x] 取消时清理该任务的半成品 staging / 临时压缩包。
- [x] 失败任务保留在下载页，行内操作显示「继续」。
- [x] 点击「继续」重试该失败任务；成功后按已完成规则从列表消失。
- [x] 没有任务时显示现有空态。

## Answer

Implemented in `bdafd247`, merged as `e54f3f88`. 下载页只查询 queued/running/failed；done 行保留用于 Missing 判定但不展示；取消删除任务行并清理 staging/.cbz.tmp；失败行使用新增 `download_resume`（「继续」）重试。Code review 后状态判定收口为 `MangaDownloadJobStatus` helper（`d28f6ff1`，merged `68e80c69`）。
