/// online 域下载任务的应答形状（纯函数，便于单测）。
///
/// 在线源的两类下载不在下载中心的磁链 / 直链表里（那张表归 data 域的 `dl`）：
///
/// - 漫画章节 / mokuro 卷：`MangaDownloadService` 的任务表（`manga_download_jobs`，
///   下载页「漫画」分区）；
/// - 视频源剧集：app 级 [InterconnectDownloadManager] 的任务（下载页「扩展源」分区，
///   与互联设备 / 媒体服务器拉取共用这个管理器，`origin` 区分）。
library;

import 'package:fushi_core/fushi_core.dart' show MangaDownloadJobRow;

/// 一条漫画下载任务。
Map<String, Object?> ctlMangaDownloadJobJson(MangaDownloadJobRow row) =>
    <String, Object?>{
      'id': row.jobId,
      'kind': row.kind,
      'bookKey': row.bookKey,
      'chapterKey': row.chapterKey,
      'runtime': row.runtime,
      'title': row.title,
      'chapter': row.chapterTitle,
      'status': row.status,
      'pagesDone': row.pagesDone,
      'pagesTotal': row.pagesTotal,
      'attempts': row.attemptCount,
      if (row.lastError != null) 'error': row.lastError,
      'createdAt': row.createdAt,
      'updatedAt': row.updatedAt,
      if (row.completedAt != null) 'completedAt': row.completedAt,
    };
