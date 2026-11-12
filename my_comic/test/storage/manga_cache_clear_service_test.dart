import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/mihon/manga_page_provider.dart'
    show LocalSourceArchiveReaderSession;
import 'package:my_comic/src/media/manga/mihon/online_manga_reader_session.dart'
    show OnlineMangaReaderSession;
import 'package:my_comic/src/storage/manga_cache_clear_service.dart';

/// Ticket 11：设置 →「存储与下载」的「清除缓存」。
///
/// 服务层测试只碰显式缓存目录：Mihon 封面、在线页流、CBZ 解包、远端封面、
/// 缩略图。不得扫整个系统临时目录，也不得碰下载库、本地图源、登录态、历史 /
/// 进度 / 数据库。
void main() {
  late Directory tmp;
  late Directory cacheRoot;
  late Directory stateRoot;
  late Directory contentRoot;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('manga_cache_clear_');
    cacheRoot = Directory(p.join(tmp.path, 'cache'))..createSync();
    stateRoot = Directory(p.join(tmp.path, 'state'))..createSync();
    contentRoot = Directory(p.join(tmp.path, 'content'))..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File writeFile(String path, int bytes) {
    final File file = File(path)..createSync(recursive: true);
    file.writeAsBytesSync(List<int>.filled(bytes, 0x41));
    return file;
  }

  Directory writeDir(String path) =>
      Directory(path)..createSync(recursive: true);

  test('大小统计只扫显式缓存目录，不扫临时目录其它内容', () async {
    writeFile(
      p.join(cacheRoot.path, 'manga_stream_cache', 'book', 'c1', 'p'),
      100,
    );
    writeFile(
      p.join(cacheRoot.path, 'local_source_archive_cache', 'session-1', 'p'),
      200,
    );
    writeFile(p.join(cacheRoot.path, 'remote_cover_cache', 'c_x'), 300);
    writeFile(p.join(cacheRoot.path, 'thumbnails', 'thumb'), 400);
    writeFile(p.join(stateRoot.path, 'mihon', 'cache', 'covers', 'cover'), 50);

    // 干扰项：cache root 下的散文件、系统临时目录里的其它目录、Mihon 登录态。
    writeFile(p.join(cacheRoot.path, 'loose-file'), 999);
    writeFile(p.join(tmp.path, 'unrelated-temp-dir', 'big'), 500);
    writeFile(p.join(stateRoot.path, 'mihon', 'cookies.json'), 10);

    final MangaCacheClearService service = MangaCacheClearService(
      steps: <MangaCacheClearStep>[
        MangaCacheDirectoryClearStep(
          id: 'mihon_covers',
          label: 'Mihon covers',
          roots: <Directory>[
            Directory(p.join(stateRoot.path, 'mihon', 'cache', 'covers')),
          ],
        ),
        MangaCacheSessionPruneStep(
          id: 'stream',
          label: 'Online page cache',
          root: Directory(p.join(cacheRoot.path, 'manga_stream_cache')),
          pruneInactive: OnlineMangaReaderSession.pruneStaleStreamCaches,
        ),
        MangaCacheSessionPruneStep(
          id: 'archive',
          label: 'CBZ page cache',
          root: Directory(p.join(cacheRoot.path, 'local_source_archive_cache')),
          pruneInactive: LocalSourceArchiveReaderSession
              .pruneStaleLocalSourceArchiveCaches,
        ),
        MangaCacheDirectoryClearStep(
          id: 'remote_covers',
          label: 'Remote covers',
          roots: <Directory>[
            Directory(p.join(cacheRoot.path, 'remote_cover_cache')),
          ],
        ),
        MangaCacheDirectoryClearStep(
          id: 'thumbnails',
          label: 'Thumbnails',
          roots: <Directory>[Directory(p.join(cacheRoot.path, 'thumbnails'))],
        ),
      ],
    );

    expect(await service.measureTotalBytes(), 1050);
  });

  test('清理只删显式缓存，保留下载库 / 本地图源 / 登录态 / 数据库', () async {
    // 缓存内容。
    final File mihonCover = writeFile(
      p.join(stateRoot.path, 'mihon', 'cache', 'covers', 'cover'),
      50,
    );
    final File streamPage = writeFile(
      p.join(cacheRoot.path, 'manga_stream_cache', 'book', 'c1', 'p'),
      100,
    );
    final File archivePage = writeFile(
      p.join(cacheRoot.path, 'local_source_archive_cache', 'session-1', 'p'),
      200,
    );
    final File remoteCover = writeFile(
      p.join(cacheRoot.path, 'remote_cover_cache', 'c_x'),
      300,
    );
    final File thumbnail = writeFile(
      p.join(cacheRoot.path, 'thumbnails', 'thumb'),
      400,
    );

    // 必须保留的用户数据。
    final File download = writeFile(
      p.join(contentRoot.path, 'downloads', 'Source', 'Series', 'ch1.cbz'),
      111,
    );
    final File localCover = writeFile(
      p.join(contentRoot.path, 'local', 'Series', 'cover.jpg'),
      222,
    );
    final File localPage = writeFile(
      p.join(contentRoot.path, 'local', 'Series', 'ch1', '001.jpg'),
      333,
    );
    final File database = writeFile(
      p.join(stateRoot.path, 'mycomic.sqlite'),
      444,
    );
    final File cookies = writeFile(
      p.join(stateRoot.path, 'mihon', 'cookies.json'),
      555,
    );
    final File extensionData = writeFile(
      p.join(stateRoot.path, 'mihon', 'extensions', 'installed.json'),
      666,
    );

    int managerEmptyCalls = 0;
    final _RecordingImageCache imageCache = _RecordingImageCache();

    final MangaCacheClearService service = MangaCacheClearService(
      steps: <MangaCacheClearStep>[
        MangaCacheDirectoryClearStep(
          id: 'mihon_covers',
          label: 'Mihon covers',
          roots: <Directory>[
            Directory(p.join(stateRoot.path, 'mihon', 'cache', 'covers')),
          ],
        ),
        MangaCacheSessionPruneStep(
          id: 'stream',
          label: 'Online page cache',
          root: Directory(p.join(cacheRoot.path, 'manga_stream_cache')),
          pruneInactive: OnlineMangaReaderSession.pruneStaleStreamCaches,
        ),
        MangaCacheSessionPruneStep(
          id: 'archive',
          label: 'CBZ page cache',
          root: Directory(p.join(cacheRoot.path, 'local_source_archive_cache')),
          pruneInactive: LocalSourceArchiveReaderSession
              .pruneStaleLocalSourceArchiveCaches,
        ),
        MangaCacheDirectoryClearStep(
          id: 'remote_covers',
          label: 'Remote covers',
          roots: <Directory>[
            Directory(p.join(cacheRoot.path, 'remote_cover_cache')),
          ],
        ),
        MangaCacheDirectoryClearStep(
          id: 'thumbnails',
          label: 'Thumbnails',
          roots: <Directory>[Directory(p.join(cacheRoot.path, 'thumbnails'))],
        ),
        MangaCacheManagerClearStep(
          id: 'image_manager',
          label: 'Image cache',
          measureManagerBytes: () async => 700,
          emptyManager: () async => managerEmptyCalls++,
        ),
        MangaMemoryImageCacheClearStep(
          id: 'memory_images',
          label: 'In-memory images',
          imageCache: imageCache,
        ),
      ],
    );

    final MangaCacheClearReport report = await service.run();

    expect(report.hasFailures, isFalse);
    expect(report.freedBytes, 1050 + 700);
    expect(managerEmptyCalls, 1);
    expect(imageCache.clears, 1);
    expect(imageCache.liveClears, 1);

    for (final File cacheFile in <File>[
      mihonCover,
      streamPage,
      archivePage,
      remoteCover,
      thumbnail,
    ]) {
      expect(cacheFile.existsSync(), isFalse, reason: cacheFile.path);
    }
    // 缓存根目录本身必须留着，阅读 / 封面缓存后续直接写回同一个目录。
    for (final String path in <String>[
      p.join(stateRoot.path, 'mihon', 'cache', 'covers'),
      p.join(cacheRoot.path, 'manga_stream_cache'),
      p.join(cacheRoot.path, 'local_source_archive_cache'),
      p.join(cacheRoot.path, 'remote_cover_cache'),
      p.join(cacheRoot.path, 'thumbnails'),
    ]) {
      expect(Directory(path).existsSync(), isTrue, reason: path);
    }

    for (final File kept in <File>[
      download,
      localCover,
      localPage,
      database,
      cookies,
      extensionData,
    ]) {
      expect(kept.existsSync(), isTrue, reason: kept.path);
      expect(kept.lengthSync(), greaterThan(0));
    }
  });

  test('在线页流 / CBZ 解包缓存只清不在活跃会话中的目录', () async {
    final Directory streamRoot = Directory(
      p.join(cacheRoot.path, 'manga_stream_cache'),
    )..createSync(recursive: true);
    final OnlineMangaReaderSession streamSession =
        await OnlineMangaReaderSession.open(
          cacheRoot: streamRoot,
          bookKey: 'book-key',
          chapterKey: 'chapter-key',
          pageIdentities: const <String>['page-0'],
          fetchPage: (int index) async => throw StateError('not used'),
        );
    addTearDown(streamSession.close);
    final Directory staleStream = writeDir(
      p.join(streamRoot.path, 'stale-book', 'stale-chapter'),
    );
    writeFile(p.join(staleStream.path, 'page'), 10);

    final Directory archiveRoot = Directory(
      p.join(cacheRoot.path, 'local_source_archive_cache'),
    )..createSync(recursive: true);
    final File emptyZip = File(p.join(tmp.path, 'empty.cbz'))
      ..writeAsBytesSync(<int>[
        0x50, 0x4b, 0x05, 0x06, // End of central directory signature.
        ...List<int>.filled(18, 0),
      ]);
    final LocalSourceArchiveReaderSession archiveSession =
        await LocalSourceArchiveReaderSession.open(
          archivePath: emptyZip.path,
          cacheRoot: archiveRoot,
          relativePaths: const <String>['001.jpg'],
        );
    addTearDown(archiveSession.close);
    final Directory staleArchive = writeDir(
      p.join(archiveRoot.path, 'session-stale'),
    );
    writeFile(p.join(staleArchive.path, 'page'), 20);

    final MangaCacheClearService service = MangaCacheClearService(
      steps: <MangaCacheClearStep>[
        MangaCacheSessionPruneStep(
          id: 'stream',
          label: 'Online page cache',
          root: streamRoot,
          pruneInactive: OnlineMangaReaderSession.pruneStaleStreamCaches,
        ),
        MangaCacheSessionPruneStep(
          id: 'archive',
          label: 'CBZ page cache',
          root: archiveRoot,
          pruneInactive: LocalSourceArchiveReaderSession
              .pruneStaleLocalSourceArchiveCaches,
        ),
      ],
    );

    final MangaCacheClearReport report = await service.run();

    expect(report.hasFailures, isFalse);
    expect(report.freedBytes, 30);
    expect(staleStream.existsSync(), isFalse);
    expect(staleArchive.existsSync(), isFalse);
    expect(
      streamSession.directory.existsSync(),
      isTrue,
      reason: '活跃阅读会话的页缓存必须保留',
    );
    expect(
      archiveSession.directory.existsSync(),
      isTrue,
      reason: '活跃阅读会话的 CBZ 解包目录必须保留',
    );
  });

  test('图片管理器磁盘缓存计入副标题 / 确认框显示的占用', () async {
    int emptied = 0;
    final MangaCacheManagerClearStep step = MangaCacheManagerClearStep(
      id: 'image_manager',
      label: 'Image cache',
      measureManagerBytes: () async => 700,
      emptyManager: () async => emptied++,
    );

    expect(await step.measureBytes(), 700, reason: '副标题 / 确认框必须算上管理器磁盘缓存');
    final MangaCacheClearService service = MangaCacheClearService(
      steps: <MangaCacheClearStep>[
        _RecordingStep(id: 'covers', label: 'Covers', freed: 0, onClear: () {}),
        step,
      ],
    );
    expect(await service.measureTotalBytes(), 700);

    final MangaCacheClearStepResult result = await step.clear();
    expect(result.freedBytes, 700);
    expect(emptied, 1);
  });

  test('单文件删除失败后继续清理其余项，并报告部分成功与释放量', () async {
    final Directory root = Directory(
      p.join(cacheRoot.path, 'remote_cover_cache'),
    )..createSync(recursive: true);
    final File first = writeFile(p.join(root.path, 'a'), 10);
    final File locked = writeFile(p.join(root.path, 'b'), 20);
    final File last = writeFile(p.join(root.path, 'c'), 30);

    int secondStepCalls = 0;
    final MangaCacheClearService service = MangaCacheClearService(
      steps: <MangaCacheClearStep>[
        MangaCacheDirectoryClearStep(
          id: 'remote_covers',
          label: 'Remote covers',
          roots: <Directory>[root],
          deleteEntity: (FileSystemEntity entity) async {
            if (entity.path == locked.path) {
              throw const FileSystemException('file is locked');
            }
            if (await entity.exists()) await entity.delete(recursive: true);
          },
        ),
        _RecordingStep(
          id: 'after',
          label: 'After',
          freed: 5,
          onClear: () => secondStepCalls++,
        ),
      ],
    );

    final MangaCacheClearReport report = await service.run();

    expect(first.existsSync(), isFalse);
    expect(last.existsSync(), isFalse);
    expect(locked.existsSync(), isTrue, reason: '删不掉的文件保留，留给下次');
    expect(secondStepCalls, 1, reason: '前一步局部失败不得中断后续步骤');
    expect(report.steps.first.failedEntries, 1);
    expect(report.steps.first.freedBytes, 40);
    expect(report.freedBytes, 45);
    expect(report.hasFailures, isTrue);
  });
}

class _RecordingStep extends MangaCacheClearStep {
  _RecordingStep({
    required this.id,
    required this.label,
    required this.freed,
    required this.onClear,
  });

  @override
  final String id;

  @override
  final String label;

  final int freed;
  final void Function() onClear;

  @override
  Future<int> measureBytes() async => freed;

  @override
  Future<MangaCacheClearStepResult> clear() async {
    onClear();
    return MangaCacheClearStepResult(id: id, freedBytes: freed);
  }
}

class _RecordingImageCache extends ImageCache {
  int clears = 0;
  int liveClears = 0;

  @override
  void clear() {
    clears++;
    super.clear();
  }

  @override
  void clearLiveImages() {
    liveClears++;
    super.clearLiveImages();
  }
}
