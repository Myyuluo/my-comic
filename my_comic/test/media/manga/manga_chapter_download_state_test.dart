import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic_core/my_comic_core.dart';

import 'package:my_comic/src/media/manga/library/manga_chapter_download_state.dart';

/// Ticket 02：章节下载状态必须区分 Not downloaded / Missing / 已下载。
///
/// Missing = 任务表说这章下载完成过（done），但当前 Content root 下磁盘判据
/// 找不到文件——典型场景是便携拷贝只带了程序目录 + `userdata`，或换了 Content
/// root。它不是「从未下载」，不能被当成可静默重新入队的普通未下载。
void main() {
  MangaDownloadJobRow job(String status) => MangaDownloadJobRow(
    jobId: 'job-1',
    kind: MangaDownloadJobKind.chapter,
    bookKey: 'book-1',
    chapterKey: 'chapter-1',
    runtime: 'mihon',
    title: 'Manga',
    chapterTitle: 'Chapter 1',
    status: status,
    pagesDone: 0,
    pagesTotal: 0,
    attemptCount: 0,
    lastError: null,
    autoOcr: false,
    createdAt: 0,
    updatedAt: 0,
    completedAt: null,
  );

  test('磁盘有完整章 → downloaded（任务行状态无关）', () {
    expect(
      mangaChapterDownloadState(
        downloaded: true,
        job: job(MangaDownloadJobStatus.done),
      ),
      MangaChapterDownloadState.downloaded,
    );
    expect(
      mangaChapterDownloadState(downloaded: true, job: null),
      MangaChapterDownloadState.downloaded,
    );
  });

  test('done 任务 + 磁盘缺文件 → Missing，不是 notDownloaded', () {
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.done),
      ),
      MangaChapterDownloadState.missing,
    );
  });

  test('任务状态映射：queued / paused / running / failed，其余为 notDownloaded', () {
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.queued),
      ),
      MangaChapterDownloadState.queued,
    );
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.paused),
      ),
      MangaChapterDownloadState.queued,
      reason: '全局暂停的任务仍占队列位，章节列表按排队中展示',
    );
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.running),
      ),
      MangaChapterDownloadState.downloading,
    );
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.failed),
      ),
      MangaChapterDownloadState.failed,
    );
    expect(
      mangaChapterDownloadState(
        downloaded: false,
        job: job(MangaDownloadJobStatus.cancelled),
      ),
      MangaChapterDownloadState.notDownloaded,
    );
    expect(
      mangaChapterDownloadState(downloaded: false, job: null),
      MangaChapterDownloadState.notDownloaded,
    );
  });
}
