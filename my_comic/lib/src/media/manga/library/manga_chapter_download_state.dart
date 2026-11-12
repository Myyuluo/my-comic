import 'package:my_comic_core/my_comic_core.dart';

/// 一章在「先下载再读」语义下的状态（设计稿 2026-09-12 §5，Ticket 02 扩展 Missing）。
enum MangaChapterDownloadState {
  notDownloaded,
  queued,
  downloading,
  downloaded,
  failed,

  /// 任务表记录过这章下载完成（`done`），但当前 Content root 下磁盘判据找不到
  /// 完整章。典型来源：便携拷贝只带了程序目录 + `userdata`、切换 Content root、
  /// 用户手动移动/删除了文件。它不是「从未下载」，重下前应先让用户知道文件没了。
  missing,
}

/// 合成章节下载状态：磁盘判据优先（真正决定能不能读），其次看任务行；
/// `done` 任务 + 磁盘缺文件 = [MangaChapterDownloadState.missing]。
MangaChapterDownloadState mangaChapterDownloadState({
  required bool downloaded,
  required MangaDownloadJobRow? job,
}) {
  if (downloaded) return MangaChapterDownloadState.downloaded;
  final String? status = job?.status;
  if (status == null) return MangaChapterDownloadState.notDownloaded;
  // 全局暂停（ticket 07）不是终态：任务仍占着队列位，只是被全局按钮停住。
  // 章节列表按「排队中」展示（不提供重复下载入口），恢复由下载页统一控制。
  if (MangaDownloadJobStatus.isActive(status)) {
    return status == MangaDownloadJobStatus.running
        ? MangaChapterDownloadState.downloading
        : MangaChapterDownloadState.queued;
  }
  return switch (status) {
    MangaDownloadJobStatus.failed => MangaChapterDownloadState.failed,
    MangaDownloadJobStatus.done => MangaChapterDownloadState.missing,
    _ => MangaChapterDownloadState.notDownloaded,
  };
}
