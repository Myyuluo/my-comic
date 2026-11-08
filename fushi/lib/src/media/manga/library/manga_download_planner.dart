import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 「下载全部」的纯规划（review D2 抽出的共享规则）。
///
/// 作品页「下载全部」与书架批量下载此前各写了一遍同一段规则，两处已经需要同步
/// 维护。这里只做纯计算、不碰 IO / 队列：
///
/// - 源按**新→旧**返回，入队按**旧→新**（[entry.chapters] 反转）；
/// - 跳过已下载（调用方从磁盘判据算好）、已排队 / 执行中的任务、以及锁定章；
/// - 锁定章单独计数，让调用方决定提示（入队必败，不该进队列）。
///
/// 调用方负责实际 [MangaDownloadService.enqueueChapters]。
({List<OnlineMangaChapter> pending, int lockedSkipped})
planMangaChapterDownload({
  required OnlineMangaLibraryEntry entry,
  required Set<String> downloadedChapterKeys,
  required Map<String, MangaDownloadJobRow> jobsByChapterKey,
}) {
  int lockedSkipped = 0;
  final List<OnlineMangaChapter> pending = <OnlineMangaChapter>[];
  for (final OnlineMangaChapter chapter in entry.chapters.reversed) {
    if (downloadedChapterKeys.contains(chapter.key)) continue;
    final String? status = jobsByChapterKey[chapter.key]?.status;
    if (status == MangaDownloadJobStatus.queued ||
        status == MangaDownloadJobStatus.running ||
        // 全局暂停的任务也在队列里（ticket 07）：不重复入队，恢复时自然开跑。
        status == MangaDownloadJobStatus.paused) {
      continue;
    }
    if (chapter.locked) {
      lockedSkipped++;
      continue;
    }
    pending.add(chapter);
  }
  return (pending: pending, lockedSkipped: lockedSkipped);
}
