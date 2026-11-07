import 'package:fushi_core/fushi_core.dart';

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
  switch (job?.status) {
    case MangaDownloadJobStatus.queued:
      return MangaChapterDownloadState.queued;
    case MangaDownloadJobStatus.running:
      return MangaChapterDownloadState.downloading;
    case MangaDownloadJobStatus.failed:
      return MangaChapterDownloadState.failed;
    case MangaDownloadJobStatus.done:
      return MangaChapterDownloadState.missing;
    default:
      return MangaChapterDownloadState.notDownloaded;
  }
}
