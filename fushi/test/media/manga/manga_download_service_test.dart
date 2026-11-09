import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';

import 'package:fushi/src/platform/mobile/android_download_keep_alive.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 假运行时：页表固定三页，取图返回真实 PNG 字节（尺寸随页序变，好核 manga.json）。
///
/// [OnlineMangaPageRef] 是密封类，假适配器借用数据形状最简单的
/// [InterconnectMangaPageRef] 当页引用——下载服务只看 `index`，不看里面是谁的。
class _FakeAdapter
    implements OnlineMangaRuntimeAdapter, OnlineMangaSourceLanguageProvider {
  static const int pageCount = 3;

  /// 每页被取了几次（续跑 / 幂等断言用）。
  final Map<int, int> fetchCounts = <int, int>{};

  /// 某页要失败几次（按调用顺序递减）。
  final Map<int, int> failuresLeft = <int, int>{};

  /// 非空时取页先卡在这里（取消用）。
  Completer<void>? gate;

  static Uint8List pngOf(int index) => Uint8List.fromList(
        img.encodePng(img.Image(width: 100 + index, height: 150 + index)),
      );

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// Source 显示名（路径净化测试会改它）。
  String sourceLabelText = 'Fake';

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      sourceLabelText;

  /// 源语言原值；null = 源没有声明语言（目录只写源名）。
  String? sourceLanguageText;

  @override
  String? sourceLanguage(OnlineMangaLibraryEntry entry) => sourceLanguageText;

  @override
  Future<OnlineMangaRefreshResult> refresh(
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async =>
      <OnlineMangaPageRef>[
        for (int i = 0; i < pageCount; i++)
          InterconnectMangaPageRef(index: i, bookKey: 'fake', remoteIndex: i),
      ];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async {
    fetchCounts[page.index] = (fetchCounts[page.index] ?? 0) + 1;
    final Completer<void>? pending = gate;
    if (pending != null) await pending.future;
    final int left = failuresLeft[page.index] ?? 0;
    if (left > 0) {
      failuresLeft[page.index] = left - 1;
      throw StateError('boom page ${page.index}');
    }
    return pngOf(page.index);
  }

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

/// 记录 update / stop 顺序的假保活（BUG-2714）。
class _RecordingKeepAlive implements DownloadKeepAlive {
  final List<String> events = <String>[];
  final List<int?> percents = <int?>[];

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {
    events.add('update:$title');
    percents.add(percent);
  }

  @override
  Future<void> stop() async {
    events.add('stop');
  }
}

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: _chapters,
    );

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FakeAdapter adapter;
  late OnlineMangaLibraryService library;
  late List<Duration> waits;
  late String bookKey;
  late String bookDir;

  MangaDownloadService build({
    DownloadKeepAlive? keepAlive,
    bool Function()? saveAsCbz,
  }) =>
      MangaDownloadService(
        database: db,
        serviceFor: (OnlineMangaRuntimeKind runtime) => library,
        keepAlive: keepAlive,
        saveAsCbz: saveAsCbz ?? () => false,
        wait: (Duration duration) async {
          waits.add(duration);
        },
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-manga-download-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FakeAdapter();
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
    waits = <Duration>[];
    final EpubBookRow row = await library.add(_entry());
    bookKey = row.bookKey;
    bookDir = row.extractDir;
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<MangaDownloadJobRow> jobOf(String chapterKey) async =>
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: chapterKey,
      ))!;

  test('start 清理旧的 mokuro 卷任务行，章节任务保留', () async {
    final MangaDownloadService downloads = build();
    addTearDown(downloads.dispose);
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'legacy-mokuro-01',
        kind: MangaDownloadJobKind.mokuroVolume,
        bookKey: 'mokuro:Series',
        chapterKey: 'Series 01',
        runtime: 'mokuro_moe',
        title: 'Series · Series 01',
        chapterTitle: 'Series 01',
        status: const Value<String>(MangaDownloadJobStatus.done),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'chapter-01',
        kind: MangaDownloadJobKind.chapter,
        bookKey: bookKey,
        chapterKey: 'ch-1',
        runtime: 'mihon',
        title: 'Fixture',
        chapterTitle: 'ch-1',
        status: const Value<String>(MangaDownloadJobStatus.done),
        pagesDone: const Value<int>(1),
        pagesTotal: const Value<int>(1),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 2,
        updatedAt: 2,
      ),
    );

    await downloads.start();

    expect(await db.listMangaDownloadJobs(), hasLength(1));
    expect((await db.listMangaDownloadJobs()).single.jobId, 'chapter-01');
  });

  test('入队 → worker 跑完：页图平铺 + pages.json、映射落库、行 done', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow queued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(queued.status, MangaDownloadJobStatus.queued);
    expect(queued.runtime, 'mihon');
    expect(queued.chapterTitle, 'Chapter 1');

    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.pagesDone, 3);
    expect(done.pagesTotal, 3);
    expect(done.completedAt, isNotNull);
    expect(done.lastError, isNull);

    // Download library：downloads/{source}/{manga}/{chapter}/001.png…
    expect(bookDir, p.join(root.path, 'downloads', 'Fake', 'Fixture series'));
    final Directory chapterDir = downloadChapterDirectory(bookDir, 'Chapter 1');
    for (int i = 1; i <= 3; i++) {
      final File page = File(
        p.join(chapterDir.path, downloadPageFileName(i - 1, '.png')),
      );
      expect(page.existsSync(), isTrue, reason: 'page $i 必须平铺落盘');
      expect(File('${page.path}.tmp').existsSync(), isFalse);
    }
    expect(
      Directory(p.join(chapterDir.path, 'images')).existsSync(),
      isFalse,
      reason: '新布局页图平铺，不再有 images/ 前缀',
    );
    expect(
      Directory(p.join(bookDir, '.staging')).existsSync(),
      isFalse,
      reason: '完成后 staging 应已 rename 走',
    );

    final MangaPagesManifest? manifest = await readPagesManifest(chapterDir);
    expect(manifest, isNotNull);
    expect(manifest!.sourceRuntime, 'mihon');
    expect(manifest.sourceId, '1');
    expect(manifest.sourceName, 'Fake');
    expect(manifest.extensionPackage, 'org.example.fixture');
    expect(manifest.mangaKey, '/series/fixture');
    expect(manifest.mangaTitle, 'Fixture series');
    expect(manifest.chapterKey, '/chapter/1');
    expect(manifest.chapterName, 'Chapter 1');
    expect(manifest.chapterNumber, 1);
    expect(manifest.chapterUrl, '/chapter/1');
    expect(
      manifest.payload.images.map((MokuroImage image) => image.url).toList(),
      <String>['001.png', '002.png', '003.png'],
    );
    expect(manifest.payload.images[0].size.width, 100);
    expect(manifest.payload.images[0].size.height, 150);
    expect(manifest.payload.images[2].size.width, 102);
    expect(manifest.payload.images[2].size.height, 152);

    // 数据库映射：bookKey + chapterKey → 实际目录名 + 容器类型。
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1');
    expect(mapping?.containerKindEnum, MangaChapterContainerKind.folder);
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isTrue,
    );
    expect(waits, isEmpty);
    downloads.dispose();
  });

  test('下载中只有 .staging 有内容：正式章目录与索引要等整章 rename 后才出现', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
    expect(staging.existsSync(), isTrue, reason: '下载中的页只在 staging 里');
    final Directory chapterDir = downloadChapterDirectory(bookDir, 'Chapter 1');
    expect(chapterDir.existsSync(), isFalse, reason: '半成品不得出现在正式位置');
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isFalse,
      reason: '半成品不进已下载索引',
    );

    adapter.gate!.complete();
    await downloads.whenIdle;
    expect(staging.existsSync(), isFalse);
    expect(chapterDir.existsSync(), isTrue);
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
    downloads.dispose();
  });

  test('目标章目录已存在时不覆盖：内容进确定后缀，映射指向实际目录', () async {
    final Directory existing = downloadChapterDirectory(bookDir, 'Chapter 1');
    await existing.create(recursive: true);
    final File sentinel = File(p.join(existing.path, 'keep.txt'));
    await sentinel.writeAsString('do not touch');

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(await sentinel.readAsString(), 'do not touch');
    expect(existing.listSync(), hasLength(1), reason: '已有目录内容不得被覆盖');
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1 (2)');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1 (2)').existsSync(),
      isTrue,
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
    downloads.dispose();
  });

  test('CBZ 开启：写成 {chapter}.cbz，包根页图 + pages.json，映射为 archive', () async {
    final MangaDownloadService downloads = build(saveAsCbz: () => true);
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final File archiveFile = downloadChapterArchiveFile(
      bookDir,
      'Chapter 1.cbz',
    );
    expect(archiveFile.existsSync(), isTrue, reason: '载体是单文件 CBZ');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '开启 CBZ 时不再产生章节目录',
    );
    expect(
      File('${archiveFile.path}.tmp').existsSync(),
      isFalse,
      reason: '临时包必须在完成后改名，不能留在漫画目录里',
    );
    expect(
      Directory(p.join(bookDir, '.staging')).existsSync(),
      isFalse,
      reason: '整章落进压缩包后 staging 应清理',
    );

    final MangaPagesManifest? manifest =
        await readDownloadLibraryArchiveManifest(archiveFile);
    expect(manifest, isNotNull);
    expect(manifest!.sourceName, 'Fake');
    expect(manifest.chapterKey, '/chapter/1');
    expect(
      manifest.payload.images.map((MokuroImage image) => image.url).toList(),
      <String>['001.png', '002.png', '003.png'],
      reason: '包根是平铺、零填充的页图',
    );
    expect(await isDownloadLibraryArchiveComplete(archiveFile), isTrue);

    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1.cbz');
    expect(mapping?.containerKindEnum, MangaChapterContainerKind.archive);

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isTrue,
    );
    final MangaChapterContainer? container = await index.resolveChapter(
      bookKey: bookKey,
      chapterKey: '/chapter/1',
    );
    expect(container?.kind, MangaChapterContainerKind.archive);
    expect(container?.archiveFile?.path, archiveFile.path);

    // 删除压缩包章节 = 删对应文件并清映射。
    await index.deleteChapter(bookKey: bookKey, chapterKey: '/chapter/1');
    expect(archiveFile.existsSync(), isFalse);
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    downloads.dispose();
  });

  test('已有完整文件夹章节原样采纳：开启 CBZ 也不转换、不重下', () async {
    final MangaDownloadService folderService = build(saveAsCbz: () => false);
    await folderService.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await folderService.start();
    await folderService.whenIdle;
    folderService.dispose();

    final Directory folder = downloadChapterDirectory(bookDir, 'Chapter 1');
    expect(folder.existsSync(), isTrue);
    // 模拟「磁盘上有完整文件夹章节、索引还没关联」的既有内容。
    await db.deleteMangaChapterDir(bookKey, '/chapter/1');
    final Map<int, int> fetchedBefore = Map<int, int>.of(adapter.fetchCounts);

    final MangaDownloadService cbzService = build(saveAsCbz: () => true);
    await cbzService.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await cbzService.start();
    await cbzService.whenIdle;

    expect(folder.existsSync(), isTrue, reason: '既有文件夹章节保持原样');
    expect(
      File(p.join(bookDir, 'Chapter 1.cbz')).existsSync(),
      isFalse,
      reason: '开关不触发批量转换',
    );
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1');
    expect(mapping?.containerKindEnum, MangaChapterContainerKind.folder);
    expect(
      adapter.fetchCounts,
      fetchedBefore,
      reason: '认领完整目录，不再访问源站',
    );
    cbzService.dispose();
  });

  test('占位扩展包 manifest 仍被认领：数字 sourceId + series key 相同，不重下', () async {
    final MangaDownloadService folderService = build(saveAsCbz: () => false);
    addTearDown(folderService.dispose);
    await folderService.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await folderService.start();
    await folderService.whenIdle;

    // 模拟导入占位身份写出的 pages.json（真实包条目仍应认领同一章）。
    final Directory folder = downloadChapterDirectory(bookDir, 'Chapter 1');
    final File manifestFile = downloadPagesManifestFile(folder);
    final Map<String, Object?> json =
        (jsonDecode(await manifestFile.readAsString()) as Map)
            .cast<String, Object?>();
    final Map<String, Object?> source =
        (json['source'] as Map).cast<String, Object?>();
    source['extensionPackage'] = 'mihon.unavailable';
    json['source'] = source;
    await manifestFile.writeAsString(jsonEncode(json));
    await db.deleteMangaChapterDir(bookKey, '/chapter/1');
    final Map<int, int> fetchedBefore = Map<int, int>.of(adapter.fetchCounts);

    final MangaDownloadService again = build(saveAsCbz: () => false);
    addTearDown(again.dispose);
    await again.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await again.start();
    await again.whenIdle;

    expect(
      adapter.fetchCounts,
      fetchedBefore,
      reason: 'mihon.unavailable 与真实包是同一身份，完整容器应直接认领',
    );
    expect(
      (await db.getMangaChapterDir(bookKey, '/chapter/1'))?.folderName,
      'Chapter 1',
    );
  });

  test('格式在任务开始运行时确定：运行中的任务保持，排队任务读真正开始时的值', () async {
    bool saveAsCbz = true;
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build(saveAsCbz: () => saveAsCbz);
    // chapters 顺序是 Chapter 2、Chapter 1；worker 按入队顺序领取。
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // 第一个任务已经在跑（格式已捕获），此时关闭开关。
    saveAsCbz = false;
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(
      File(p.join(bookDir, 'Chapter 2.cbz')).existsSync(),
      isTrue,
      reason: '运行中的任务保持它开始时的 CBZ 格式',
    );
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isTrue,
      reason: '排队任务在真正开始时读到关闭 → 文件夹',
    );
    expect(
      File(p.join(bookDir, 'Chapter 1.cbz')).existsSync(),
      isFalse,
    );
    downloads.dispose();
  });

  test('同名 .cbz 已存在（属于别的章）：不覆盖，改用确定后缀', () async {
    final File existing = File(p.join(bookDir, 'Chapter 1.cbz'));
    await existing.writeAsString('do not touch');

    final MangaDownloadService downloads = build(saveAsCbz: () => true);
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(await existing.readAsString(), 'do not touch', reason: '已有 .cbz 不得被覆盖');
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1 (2).cbz');
    expect(mapping?.containerKindEnum, MangaChapterContainerKind.archive);
    expect(
      File(p.join(bookDir, 'Chapter 1 (2).cbz')).existsSync(),
      isTrue,
    );
    expect(
      await DownloadLibraryIndex(
        db,
      ).isChapterDownloaded(bookKey: bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
    downloads.dispose();
  });

  test('取消 CBZ 下载：清理 staging 与临时包，不出现可见的半成品 .cbz', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build(saveAsCbz: () => true);
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
    expect(staging.existsSync(), isTrue, reason: '下载中的页只在 staging 里');

    await downloads.cancel(job.jobId);
    expect(
      await db.getMangaDownloadJob(job.jobId),
      isNull,
      reason: '取消立即删除任务行（下载页即时移除），不必等 worker 收尾',
    );
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(staging.existsSync(), isFalse, reason: '取消要删 staging');
    final List<String> leftovers = Directory(bookDir)
        .listSync()
        .map((FileSystemEntity entity) => p.basename(entity.path))
        .where((String name) => name.toLowerCase().endsWith('.cbz') ||
            name.toLowerCase().endsWith('.cbz.tmp'))
        .toList();
    expect(leftovers, isEmpty, reason: '取消不得留下可见或临时的 .cbz 文件');
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    downloads.dispose();
  });

  test('source / manga / chapter 目录段经过基础净化', () async {
    adapter.sourceLabelText = 'Bad:Source';
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter: 1?',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    );
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry(
      runtime: _entry().runtime,
      extensionPackage: _entry().extensionPackage,
      // 独立 Source：setUp 里已入库的 'Fake' 源目录按「同源复用」不会改名。
      sourceId: '2',
      series: const OnlineMangaSeries(
        key: '/series/bad-names',
        title: 'Fixture: Series?',
        raw: <String, Object?>{'url': '/series/bad-names'},
      ),
      chapters: const <OnlineMangaChapter>[chapter],
    );
    // 入库就会按净化后的 source / manga 建目录；下载章节名同样要净化。
    final EpubBookRow badRow = await library.add(entry);
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: entry,
      chapter: chapter,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(
      badRow.extractDir,
      p.join(root.path, 'downloads', 'Bad_Source', 'Fixture_ Series_'),
    );
    expect(
      downloadChapterDirectory(badRow.extractDir, 'Chapter_ 1_').existsSync(),
      isTrue,
      reason: '目录名按 Windows 非法字符净化',
    );
    final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
      badRow.bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter_ 1_');
    downloads.dispose();
  });

  OnlineMangaLibraryEntry entryWith({
    String sourceId = '1',
    String seriesKey = '/series/fixture',
    String title = 'Fixture series',
    required List<OnlineMangaChapter> chapters,
  }) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: sourceId,
        series: OnlineMangaSeries(
          key: seriesKey,
          title: title,
          raw: <String, Object?>{'url': seriesKey},
        ),
        chapters: chapters,
      );

  test('源有语言：新下载落在「源名 (LANG)」，pages.json 仍写裸源名', () async {
    adapter.sourceLanguageText = 'zh-Hans';
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    );
    // 独立 Source：setUp 里已用无语言状态建过 'Fake' 目录，同源会复用旧目录。
    final OnlineMangaLibraryEntry entry = entryWith(
      sourceId: '2',
      seriesKey: '/series/lang',
      title: 'Lang series',
      chapters: const <OnlineMangaChapter>[chapter],
    );
    final EpubBookRow row = await library.add(entry);
    expect(
      row.extractDir,
      p.join(root.path, 'downloads', 'Fake (ZH-HANS)', 'Lang series'),
    );

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: entry,
      chapter: chapter,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaPagesManifest? manifest = await readPagesManifest(
      downloadChapterDirectory(row.extractDir, 'Chapter 1'),
    );
    expect(manifest, isNotNull);
    expect(
      manifest!.sourceName,
      'Fake',
      reason: 'pages.json 只写裸源名，语言只体现在目录名',
    );
    downloads.dispose();
  });

  test('同章不同扫译组：第二个落 [扫译组] 后缀目录，两个都能打开', () async {
    const OnlineMangaChapter groupA = OnlineMangaChapter(
      key: '/chapter/a',
      name: 'Chapter 1',
      number: 1,
      scanlator: 'Group A',
      raw: <String, Object?>{'url': '/chapter/a'},
    );
    const OnlineMangaChapter groupB = OnlineMangaChapter(
      key: '/chapter/b',
      name: 'Chapter 1',
      number: 1,
      scanlator: 'Group B',
      raw: <String, Object?>{'url': '/chapter/b'},
    );
    final OnlineMangaLibraryEntry entry = entryWith(
      chapters: const <OnlineMangaChapter>[groupA, groupB],
    );
    final EpubBookRow row = await library.add(entry);
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: entry,
      chapter: groupA,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: entry,
      chapter: groupB,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaChapterDirRow? a = await db.getMangaChapterDir(
      row.bookKey,
      groupA.key,
    );
    final MangaChapterDirRow? b = await db.getMangaChapterDir(
      row.bookKey,
      groupB.key,
    );
    expect(a?.folderName, 'Chapter 1');
    expect(
      b?.folderName,
      'Chapter 1 [Group B]',
      reason: '同名章用扫译组后缀区分，不能覆盖第一组',
    );
    for (final (String key, String folder) in <(String, String)>[
      (groupA.key, a!.folderName),
      (groupB.key, b!.folderName),
    ]) {
      final Directory dir = downloadChapterDirectory(
        row.extractDir,
        folder,
      );
      final MangaPagesManifest? manifest = await readPagesManifest(dir);
      expect(manifest?.chapterKey, key, reason: '目录内容必须属于对应章节');
      expect(manifest?.payload.images, isNotEmpty);
      expect(
        await DownloadLibraryIndex(db).isChapterDownloaded(
          bookKey: row.bookKey,
          chapterKey: key,
        ),
        isTrue,
      );
    }
    downloads.dispose();
  });

  test('重复章节名且无扫译组：确定 (2) 后缀', () async {
    const OnlineMangaChapter first = OnlineMangaChapter(
      key: '/chapter/a',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/a'},
    );
    const OnlineMangaChapter second = OnlineMangaChapter(
      key: '/chapter/b',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/b'},
    );
    final OnlineMangaLibraryEntry entry = entryWith(
      chapters: const <OnlineMangaChapter>[first, second],
    );
    final EpubBookRow row = await library.add(entry);
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapters(
      entry: entry,
      chapters: const <OnlineMangaChapter>[first, second],
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(
      (await db.getMangaChapterDir(row.bookKey, first.key))?.folderName,
      'Chapter 1',
    );
    expect(
      (await db.getMangaChapterDir(row.bookKey, second.key))?.folderName,
      'Chapter 1 (2)',
    );
    downloads.dispose();
  });

  test('已有章目录属于另一章（大小写不同）：不认领、不覆盖，改用 (2)', () async {
    const OnlineMangaChapter other = OnlineMangaChapter(
      key: '/chapter/other',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/other'},
    );
    final MangaPagesManifest foreign = MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Fixture series',
      chapterKey: other.key,
      chapterName: other.name,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.png',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    );
    final Directory foreignDir = downloadChapterDirectory(
      bookDir,
      'chapter 1',
    );
    await foreignDir.create(recursive: true);
    await File(
      p.join(foreignDir.path, '001.png'),
    ).writeAsBytes(_FakeAdapter.pngOf(0));
    await writePagesManifestAtomically(foreignDir, foreign);
    final List<int> before = await File(
      p.join(foreignDir.path, '001.png'),
    ).readAsBytes();

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(
      (await db.getMangaChapterDir(bookKey, '/chapter/1'))?.folderName,
      'Chapter 1 (2)',
      reason: '大小写不同且属于另一章：不得认领为本章内容',
    );
    expect(
      (await readPagesManifest(foreignDir))?.chapterKey,
      other.key,
      reason: '已有目录的 pages.json 不得被改写',
    );
    expect(
      await File(p.join(foreignDir.path, '001.png')).readAsBytes(),
      before,
      reason: '已有页图不得被覆盖',
    );
    expect(
      await DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isTrue,
    );
    downloads.dispose();
  });

  test('不同 Source 的同名 Manga 下载互不覆盖', () async {
    adapter.sourceLabelText = 'Shared';
    const OnlineMangaChapter chapter = OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    );
    final OnlineMangaLibraryEntry firstEntry = entryWith(
      sourceId: '9',
      seriesKey: '/series/same',
      title: 'Same title',
      chapters: const <OnlineMangaChapter>[chapter],
    );
    final OnlineMangaLibraryEntry secondEntry = entryWith(
      sourceId: '10',
      seriesKey: '/series/same',
      title: 'Same title',
      chapters: const <OnlineMangaChapter>[chapter],
    );
    final EpubBookRow firstRow = await library.add(firstEntry);
    final EpubBookRow secondRow = await library.add(secondEntry);
    expect(firstRow.extractDir, isNot(secondRow.extractDir));

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: firstEntry,
      chapter: chapter,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: secondEntry,
      chapter: chapter,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    for (final (EpubBookRow row, String sourceId) in <(EpubBookRow, String)>[
      (firstRow, '9'),
      (secondRow, '10'),
    ]) {
      final MangaChapterDirRow? mapping = await db.getMangaChapterDir(
        row.bookKey,
        chapter.key,
      );
      expect(mapping, isNotNull);
      final Directory dir = downloadChapterDirectory(
        row.extractDir,
        mapping!.folderName,
      );
      final MangaPagesManifest? manifest = await readPagesManifest(dir);
      expect(manifest?.sourceId, sourceId);
      expect(
        await index.isChapterDownloaded(
          bookKey: row.bookKey,
          chapterKey: chapter.key,
        ),
        isTrue,
      );
    }
    expect(
      firstRow.extractDir,
      isNot(secondRow.extractDir),
      reason: '同名 Source + 同名 Manga 必须落在不同目录',
    );
    downloads.dispose();
  });

  test('保留名与超长章节名：净化、路径受限、下载仍完成', () async {
    adapter.sourceLabelText = 'CON';
    const OnlineMangaChapter reserved = OnlineMangaChapter(
      key: '/chapter/con',
      name: 'CON',
      number: 1,
      raw: <String, Object?>{'url': '/chapter/con'},
    );
    final OnlineMangaLibraryEntry reservedEntry = entryWith(
      sourceId: '77',
      seriesKey: '/series/con',
      title: 'NUL. ',
      chapters: const <OnlineMangaChapter>[reserved],
    );
    final EpubBookRow reservedRow = await library.add(reservedEntry);

    final String longName = 'L' * 300;
    final OnlineMangaChapter longChapter = OnlineMangaChapter(
      key: '/chapter/long',
      name: longName,
      number: 1,
      raw: const <String, Object?>{'url': '/chapter/long'},
    );
    final OnlineMangaLibraryEntry longEntry = entryWith(
      sourceId: '78',
      seriesKey: '/series/long',
      title: 'M' * 300,
      chapters: <OnlineMangaChapter>[longChapter],
    );
    final EpubBookRow longRow = await library.add(longEntry);

    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: reservedEntry,
      chapter: reserved,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: longEntry,
      chapter: longChapter,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    expect(
      (await db.getMangaChapterDir(reservedRow.bookKey, reserved.key))
          ?.folderName,
      '_CON',
    );
    expect(p.basename(reservedRow.extractDir), '_NUL');
    expect(p.basename(p.dirname(reservedRow.extractDir)), '_CON');

    final MangaChapterDirRow? longMapping = await db.getMangaChapterDir(
      longRow.bookKey,
      longChapter.key,
    );
    expect(longMapping, isNotNull);
    expect(
      longRow.extractDir.length,
      lessThanOrEqualTo(
        kDownloadLibraryMaxPathLength - kDownloadLibraryStagingPathReserve,
      ),
    );
    final String longChapterPath = downloadChapterDirectory(
      longRow.extractDir,
      longMapping!.folderName,
    ).path;
    expect(
      longChapterPath.length,
      lessThanOrEqualTo(kDownloadLibraryMaxPathLength),
    );
    expect(
      await readPagesManifest(Directory(longChapterPath)),
      isNotNull,
      reason: '超长名称也要能正常下载完成',
    );
    expect(
      await DownloadLibraryIndex(db).isChapterDownloaded(
        bookKey: longRow.bookKey,
        chapterKey: longChapter.key,
      ),
      isTrue,
    );
    downloads.dispose();
  });

  test('单页连续失败 3 次 → failed + last_error，退避表被按序调用', () async {
    adapter.failuresLeft[1] = 99;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow failed = await jobOf('/chapter/1');
    expect(failed.status, MangaDownloadJobStatus.failed);
    expect(failed.attemptCount, kMangaDownloadMaxAttempts);
    expect(failed.lastError, contains('boom page 1'));
    expect(waits, <Duration>[
      kMangaDownloadRetryBackoff[0],
      kMangaDownloadRetryBackoff[1],
    ]);
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isFalse,
      reason: '失败的半成品不得被当成已下载',
    );
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '正式章目录只在整章完成后才出现',
    );
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    // 半成品留在 .staging，供重试续跑。
    final Directory staging = downloadStagingDirectory(bookDir, failed.jobId);
    expect(staging.existsSync(), isTrue);
    expect(
      File(p.join(staging.path, downloadPageFileName(0, '.png'))).existsSync(),
      isTrue,
    );
    // 其余页只取一次：续跑认磁盘上已落地的页，不重下。
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[2], 1);
    expect(adapter.fetchCounts[1], kMangaDownloadMaxAttempts);
    downloads.dispose();
  });

  test('第 2 次成功 → done，退避只等了一次，已落地的页不重取', () async {
    adapter.failuresLeft[1] = 1;
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;

    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.attemptCount, 1);
    expect(done.lastError, isNull, reason: '成功后清掉上一次的错误');
    expect(waits, <Duration>[kMangaDownloadRetryBackoff[0]]);
    expect(adapter.fetchCounts[0], 1);
    expect(adapter.fetchCounts[1], 2);
    expect(adapter.fetchCounts[2], 1);
    downloads.dispose();
  });

  test('failed 后 retry → 重置 queued 并跑成 done', () async {
    adapter.failuresLeft[0] = 99;
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.failed);

    adapter.failuresLeft.clear();
    await downloads.retry(job.jobId);
    await downloads.whenIdle;
    final MangaDownloadJobRow done = await jobOf('/chapter/1');
    expect(done.status, MangaDownloadJobStatus.done);
    expect(done.lastError, isNull);
    downloads.dispose();
  });

  test('取消 running 的任务 → 删除任务行，半成品目录被删', () async {
    adapter.gate = Completer<void>();
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.start();
    // 等 worker 真的进到取页（第一页已被请求）。
    while ((adapter.fetchCounts[0] ?? 0) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.running);
    final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
    expect(staging.existsSync(), isTrue, reason: '页图先写 staging');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
      reason: '完成前正式章目录不存在',
    );
    final DownloadLibraryIndex index = DownloadLibraryIndex(db);
    expect(
      await index.isChapterDownloaded(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
      ),
      isFalse,
    );

    await downloads.cancel(job.jobId);
    expect(
      await db.getMangaDownloadJob(job.jobId),
      isNull,
      reason: '取消立即删除任务行（下载页即时移除），不必等 worker 收尾',
    );
    adapter.gate!.complete();
    await downloads.whenIdle;

    expect(staging.existsSync(), isFalse, reason: '取消要删半成品 staging');
    expect(
      downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
      isFalse,
    );
    expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
    downloads.dispose();
  });

  test('queued 的任务取消 → 删除任务行；再 enqueue 同章 → 重新排队', () async {
    final MangaDownloadService downloads = build();
    final MangaDownloadJobRow job = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: false,
    );
    await downloads.cancel(job.jobId);
    expect(
      await db.getMangaDownloadJob(job.jobId),
      isNull,
      reason: '取消直接删除任务行，不保留已取消记录',
    );
    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.first,
      autoOcr: true,
    );
    expect(again.jobId, job.jobId, reason: 'job_id 由身份三元组派生，稳定');
    expect(again.status, MangaDownloadJobStatus.queued);
    downloads.dispose();
  });

  group('取消失败任务（ticket 09）', () {
    Future<void> insertFailedJob({
      required String jobId,
      required String chapterKey,
      required String chapterTitle,
      required int createdAt,
    }) =>
        db.upsertMangaDownloadJob(
          MangaDownloadJobsCompanion.insert(
            jobId: jobId,
            kind: MangaDownloadJobKind.chapter,
            bookKey: bookKey,
            chapterKey: chapterKey,
            runtime: 'mihon',
            title: 'Fixture series',
            chapterTitle: chapterTitle,
            status: const Value<String>(MangaDownloadJobStatus.failed),
            pagesDone: const Value<int>(1),
            pagesTotal: const Value<int>(3),
            attemptCount: const Value<int>(3),
            autoOcr: const Value<bool>(false),
            createdAt: createdAt,
            updatedAt: createdAt,
          ),
        );

    test('删除任务行、staging、临时包与映射容器，其他任务不受影响', () async {
      final MangaDownloadService downloads = build(saveAsCbz: () => true);
      addTearDown(downloads.dispose);
      await insertFailedJob(
        jobId: 'failed-1',
        chapterKey: '/chapter/1',
        chapterTitle: 'Chapter 1',
        createdAt: 1,
      );
      await insertFailedJob(
        jobId: 'failed-2',
        chapterKey: '/chapter/2',
        chapterTitle: 'Chapter 2',
        createdAt: 2,
      );

      final Directory staging = downloadStagingDirectory(bookDir, 'failed-1');
      await staging.create(recursive: true);
      await File(
        p.join(staging.path, downloadPageFileName(0, '.png')),
      ).writeAsBytes(_FakeAdapter.pngOf(0));
      final File temp = File(p.join(bookDir, 'Chapter 1.cbz.tmp'));
      await temp.writeAsString('partial archive');
      final Directory mapped = downloadChapterDirectory(bookDir, 'Chapter 1');
      await mapped.create(recursive: true);
      await db.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: '/chapter/1',
        folderName: 'Chapter 1',
        updatedAt: 1,
      );

      final Directory otherStaging = downloadStagingDirectory(
        bookDir,
        'failed-2',
      );
      await otherStaging.create(recursive: true);

      expect(await downloads.discardFailed('failed-1'), isTrue);

      expect(await db.getMangaDownloadJob('failed-1'), isNull);
      expect(staging.existsSync(), isFalse, reason: '删除 .staging/<jobId>');
      expect(temp.existsSync(), isFalse, reason: '删除失败的 .cbz.tmp');
      expect(mapped.existsSync(), isFalse, reason: '删除可能存在的映射容器');
      expect(
        await db.getMangaChapterDir(bookKey, '/chapter/1'),
        isNull,
        reason: '映射行一并清理',
      );
      expect(
        await db.getMangaDownloadJob('failed-2'),
        isNotNull,
        reason: '其他任务不受影响',
      );
      expect(
        otherStaging.existsSync(),
        isTrue,
        reason: '其他任务的 staging 不被清理',
      );
      expect(
        await downloads.discardFailed('failed-1'),
        isFalse,
        reason: '已删除的任务幂等 no-op',
      );
    });

    test('非失败任务不被取消失败路径删除', () async {
      final MangaDownloadService downloads = build();
      addTearDown(downloads.dispose);
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
      await staging.create(recursive: true);

      expect(await downloads.discardFailed(job.jobId), isFalse);

      expect(await db.getMangaDownloadJob(job.jobId), isNotNull);
      expect(staging.existsSync(), isTrue);
    });
  });

  test('重启：running 行复位成 queued 续跑', () async {
    final MangaDownloadService first = build();
    final MangaDownloadJobRow job = await first.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    // 模拟上一个进程死在 running：直接改状态，不起 worker。
    await db.updateMangaDownloadJobStatus(
      job.jobId,
      status: MangaDownloadJobStatus.running,
      updatedAt: 1,
    );
    first.dispose();

    final MangaDownloadService second = build();
    await second.start();
    await second.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    second.dispose();
  });

  test('同章重复入队幂等：done 且目录在 → 不重下、不重取', () async {
    final MangaDownloadService downloads = build();
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(await db.listMangaDownloadJobs(), hasLength(1));
    await downloads.start();
    await downloads.whenIdle;
    expect(adapter.fetchCounts, <int, int>{0: 1, 1: 1, 2: 1});

    final MangaDownloadJobRow again = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(again.status, MangaDownloadJobStatus.done);
    await downloads.whenIdle;
    expect(
        adapter.fetchCounts,
        <int, int>{
          0: 1,
          1: 1,
          2: 1,
        },
        reason: '已下载的章不该再打源');

    // 目录被删 → 判据失效 → 重新排队（worker 在跑，行可能已被立刻领走）。
    await DownloadLibraryIndex(
      db,
    ).deleteChapter(bookKey: bookKey, chapterKey: '/chapter/1');
    final MangaDownloadJobRow requeued = await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapters.last,
      autoOcr: false,
    );
    expect(
      requeued.status,
      anyOf(MangaDownloadJobStatus.queued, MangaDownloadJobStatus.running),
    );
    await downloads.whenIdle;
    expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.done);
    expect(
        adapter.fetchCounts,
        <int, int>{
          0: 2,
          1: 2,
          2: 2,
        },
        reason: '目录没了就得真的重下');
    downloads.dispose();
  });

  group('全局暂停 / 继续（ticket 07）', () {
    Future<void> insertFailedChapter2() => db.upsertMangaDownloadJob(
          MangaDownloadJobsCompanion.insert(
            jobId: mangaDownloadJobId(
              kind: MangaDownloadJobKind.chapter,
              bookKey: bookKey,
              chapterKey: '/chapter/2',
            ),
            kind: MangaDownloadJobKind.chapter,
            bookKey: bookKey,
            chapterKey: '/chapter/2',
            runtime: 'mihon',
            title: 'Fixture series',
            chapterTitle: 'Chapter 2',
            status: const Value<String>(MangaDownloadJobStatus.failed),
            pagesDone: const Value<int>(0),
            pagesTotal: const Value<int>(0),
            attemptCount: const Value<int>(3),
            lastError: const Value<String>('boom'),
            autoOcr: const Value<bool>(false),
            createdAt: 1,
            updatedAt: 1,
          ),
        );

    test('pauseAll：暂停排队中/下载中的任务并保留 staging，失败任务保持失败', () async {
      await insertFailedChapter2();
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.running,
        reason: '前置：任务确实在跑',
      );

      await downloads.pauseAll();
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.paused,
        reason: '排队中/下载中的任务立即变为暂停（全局按钮据此切换文案）',
      );
      expect(
        (await jobOf('/chapter/2')).status,
        MangaDownloadJobStatus.failed,
        reason: '全部暂停不动失败任务',
      );

      adapter.gate!.complete();
      await downloads.whenIdle;
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.paused,
        reason: '运行中的任务收到暂停信号后停在暂停态，不得落成 done',
      );
      final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
      expect(staging.existsSync(), isTrue, reason: '暂停必须保留 staging 供续传');
      expect(
        downloadChapterDirectory(bookDir, 'Chapter 1').existsSync(),
        isFalse,
        reason: '暂停不得把半成品落成正式章节',
      );
      expect(await db.getMangaChapterDir(bookKey, '/chapter/1'), isNull);
      downloads.dispose();
    });

    test('resumeAll：暂停任务续传（已落地页不重取）并重试失败任务', () async {
      await insertFailedChapter2();
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await downloads.pauseAll();
      adapter.gate!.complete();
      await downloads.whenIdle;
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      expect(
        downloadStagingDirectory(bookDir, job.jobId).existsSync(),
        isTrue,
        reason: '前置：暂停保留了 staging',
      );
      // 两个章共用同一个假 adapter 的页索引计数；清空后，恢复时若暂停的章
      // 重新取页，计数会是每页 2 次（重试的失败章也各取 1 次）。
      adapter.fetchCounts.clear();

      await downloads.resumeAll();
      await downloads.whenIdle;

      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.done,
        reason: '暂停任务恢复为排队并完成',
      );
      expect(
        (await jobOf('/chapter/2')).status,
        MangaDownloadJobStatus.done,
        reason: '全部继续会重试所有失败任务',
      );
      expect(
        adapter.fetchCounts,
        <int, int>{0: 1, 1: 1, 2: 1},
        reason: '暂停章复用 staging 页级续传，已落地的页不重复下载（只有被重试的'
            '失败章重新取页）',
      );
      expect(waits, isEmpty);
      downloads.dispose();
    });

    test('暂停状态在服务重启后保留，不会自动开始', () async {
      final MangaDownloadService first = build();
      await first.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await first.pauseAll();
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.paused,
      );
      first.dispose();

      final MangaDownloadService restarted = build();
      await restarted.start();
      await restarted.whenIdle;

      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.paused,
        reason: '重启后暂停任务仍暂停',
      );
      expect(adapter.fetchCounts, isEmpty, reason: '暂停任务不会在启动时自动开跑');
      restarted.dispose();
    });

    test('暂停期间新入队的章节以暂停入队，不自动开始', () async {
      final MangaDownloadService downloads = build();
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.pauseAll();

      final MangaDownloadJobRow enqueuedWhilePaused = await downloads
          .enqueueChapter(
            entry: _entry(),
            chapter: _chapters.first,
            autoOcr: false,
          );
      expect(
        enqueuedWhilePaused.status,
        MangaDownloadJobStatus.paused,
        reason: '暂停期间新任务直接以暂停入队',
      );

      await downloads.start();
      await downloads.whenIdle;
      expect(adapter.fetchCounts, isEmpty, reason: '暂停任务不会自动开始');
      expect((await jobOf('/chapter/1')).status, MangaDownloadJobStatus.paused);
      expect((await jobOf('/chapter/2')).status, MangaDownloadJobStatus.paused);
      downloads.dispose();
    });

    test('暂停后立刻全部继续：迟到的暂停收尾不覆盖已恢复的排队状态', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      // worker 还卡在取页时先暂停、再立刻继续（行被改回 queued）。
      await downloads.pauseAll();
      await downloads.resumeAll();
      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.queued,
      );

      adapter.gate!.complete();
      await downloads.whenIdle;

      expect(
        (await jobOf('/chapter/1')).status,
        MangaDownloadJobStatus.done,
        reason: '恢复后的排队不能被迟到的暂停收尾按回 paused',
      );
      downloads.dispose();
    });

    test('取消暂停中的任务：删除任务行并清理 staging', () async {
      adapter.gate = Completer<void>();
      final MangaDownloadService downloads = build();
      final MangaDownloadJobRow job = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await downloads.pauseAll();
      adapter.gate!.complete();
      await downloads.whenIdle;
      final Directory staging = downloadStagingDirectory(bookDir, job.jobId);
      expect(staging.existsSync(), isTrue, reason: '前置：暂停保留了 staging');

      await downloads.cancel(job.jobId);

      expect(await db.getMangaDownloadJob(job.jobId), isNull);
      expect(staging.existsSync(), isFalse, reason: '取消暂停任务仍要清理半成品');
      downloads.dispose();
    });

    test('暂停期间重新入队已暂停的章节：保持暂停且不丢进度', () async {
      final MangaDownloadService downloads = build();
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await db.updateMangaDownloadJobProgress(
        mangaDownloadJobId(
          kind: MangaDownloadJobKind.chapter,
          bookKey: bookKey,
          chapterKey: '/chapter/1',
        ),
        pagesDone: 1,
        pagesTotal: 3,
        updatedAt: 2,
      );
      await downloads.pauseAll();

      final MangaDownloadJobRow again = await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      expect(again.status, MangaDownloadJobStatus.paused);
      expect(
        again.pagesDone,
        1,
        reason: '入队幂等：暂停中的任务不重置进度',
      );
      downloads.dispose();
    });
  });

  group('下载保活（BUG-2714）', () {
    test('worker 开跑即保活、报页进度；两章连跑中间不撤，排空后撤一次', () async {
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapters(
        entry: _entry(),
        chapters: _chapters,
        autoOcr: false,
      );
      expect(keepAlive.events, isEmpty, reason: '未 start 不该挂保活');

      await downloads.start();
      await downloads.whenIdle;

      expect(keepAlive.events.first, 'update:Fixture series');
      expect(keepAlive.events.last, 'stop');
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '队列没排空之前不能撤（后台里撤了就再也拉不起前台服务）',
      );
      expect(keepAlive.percents, contains(100));
      downloads.dispose();
      expect(
        keepAlive.events.where((String e) => e == 'stop'),
        hasLength(1),
        reason: '已撤过，dispose 不重复 stop',
      );
    });

    test('跑到一半 dispose → 撤保活', () async {
      adapter.gate = Completer<void>();
      final _RecordingKeepAlive keepAlive = _RecordingKeepAlive();
      final MangaDownloadService downloads = build(keepAlive: keepAlive);
      await downloads.enqueueChapter(
        entry: _entry(),
        chapter: _chapters.last,
        autoOcr: false,
      );
      await downloads.start();
      while ((adapter.fetchCounts[0] ?? 0) == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(keepAlive.events, isNot(contains('stop')));

      downloads.dispose();
      expect(keepAlive.events.last, 'stop');
      adapter.gate!.complete();
      await downloads.whenIdle;
      expect(keepAlive.events.where((String e) => e == 'stop'), hasLength(1));
    });
  });
}
