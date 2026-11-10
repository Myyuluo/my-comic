// 「下载全部」的纯规划（review D2）：作品页与书架批量下载共用一条规则——
// 源列表新→旧，入队按旧→新；跳过已下载、已排队 / 执行中、以及锁定章。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/library/manga_download_planner.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';

OnlineMangaChapter _chapter(String key, {bool locked = false}) =>
    OnlineMangaChapter(
      key: key,
      name: key,
      number: 0,
      locked: locked,
      raw: <String, Object?>{'url': key},
    );

MangaDownloadJobRow _job(String chapterKey, String status) =>
    MangaDownloadJobRow(
      jobId: 'job-$chapterKey',
      kind: MangaDownloadJobKind.chapter,
      bookKey: 'book',
      chapterKey: chapterKey,
      runtime: 'mihon',
      title: 'Book',
      chapterTitle: chapterKey,
      status: status,
      pagesDone: 0,
      pagesTotal: 0,
      attemptCount: 0,
      autoOcr: false,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  test('按旧→新规划未下载、未排队、未锁定的章，并统计锁定跳过', () {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      // 源按新→旧返回。
      chapters: <OnlineMangaChapter>[
        _chapter('/chapter/5'),
        _chapter('/chapter/4', locked: true),
        _chapter('/chapter/3'),
        _chapter('/chapter/2'),
        _chapter('/chapter/1'),
      ],
    );

    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        planMangaChapterDownload(
          entry: entry,
          // 最新章已下载；第 3 章已在队列里。
          downloadedChapterKeys: const <String>{'/chapter/5'},
          jobsByChapterKey: <String, MangaDownloadJobRow>{
            '/chapter/3': _job('/chapter/3', MangaDownloadJobStatus.queued),
          },
        );

    expect(
      plan.pending.map((OnlineMangaChapter chapter) => chapter.key).toList(),
      <String>['/chapter/1', '/chapter/2'],
      reason: '只入队可下载的章，且按旧→新（源列表反转）顺序',
    );
    expect(plan.lockedSkipped, 1, reason: '锁定章不因入队必败而混进队列');
  });

  test('执行中的章同样跳过；没有可下载章时返回空规划', () {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[
        _chapter('/chapter/2'),
        _chapter('/chapter/1', locked: true),
      ],
    );

    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        planMangaChapterDownload(
          entry: entry,
          downloadedChapterKeys: const <String>{},
          jobsByChapterKey: <String, MangaDownloadJobRow>{
            '/chapter/2': _job('/chapter/2', MangaDownloadJobStatus.running),
          },
        );

    expect(plan.pending, isEmpty);
    expect(plan.lockedSkipped, 1);
  });

  test('批量下载只规划选中子集，仍按旧→新且只统计子集内的锁定章', () {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      // 源按新→旧返回；/6 没被选中（且锁定），不参与本次批量下载。
      chapters: <OnlineMangaChapter>[
        _chapter('/chapter/6', locked: true),
        _chapter('/chapter/5'),
        _chapter('/chapter/4', locked: true),
        _chapter('/chapter/3'),
        _chapter('/chapter/2'),
        _chapter('/chapter/1'),
      ],
    );

    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        planMangaChapterDownload(
          entry: entry,
          downloadedChapterKeys: const <String>{'/chapter/1'},
          jobsByChapterKey: <String, MangaDownloadJobRow>{
            '/chapter/5': _job('/chapter/5', MangaDownloadJobStatus.running),
          },
          chapterKeys: const <String>{
            '/chapter/5',
            '/chapter/4',
            '/chapter/3',
            '/chapter/2',
            '/chapter/1',
          },
        );

    expect(
      plan.pending.map((OnlineMangaChapter chapter) => chapter.key).toList(),
      <String>['/chapter/2', '/chapter/3'],
      reason: '只规划选中且可下载的章，顺序仍与「下载全部」一致（旧→新）',
    );
    expect(plan.lockedSkipped, 1, reason: '只统计选中子集里的锁定章；未选中的锁定章不计入');
  });

  test('全局暂停中的章不重复入队（恢复时自然开跑）', () {
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[
        _chapter('/chapter/2'),
        _chapter('/chapter/1'),
      ],
    );

    final ({List<OnlineMangaChapter> pending, int lockedSkipped}) plan =
        planMangaChapterDownload(
          entry: entry,
          downloadedChapterKeys: const <String>{},
          jobsByChapterKey: <String, MangaDownloadJobRow>{
            '/chapter/2': _job('/chapter/2', MangaDownloadJobStatus.paused),
          },
        );

    expect(
      plan.pending.map((OnlineMangaChapter chapter) => chapter.key),
      <String>['/chapter/1'],
      reason: '暂停任务已在队列里，只需规划未入队的章',
    );
  });
}
