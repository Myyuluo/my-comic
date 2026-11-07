import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

/// 只为把一条在线条目入库；本测试不跑 worker，页表 / 取页永远不会被调。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
          OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async =>
      const <OnlineMangaPageRef>[];

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async =>
      Uint8List(0);

  @override
  Future<List<int>> fetchCover(
          OnlineMangaLibraryEntry entry, String url) async =>
      <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

const OnlineMangaChapter _chapter = OnlineMangaChapter(
  key: '/chapter/1',
  name: 'Chapter 1',
  number: 1,
  raw: <String, Object?>{'url': '/chapter/1'},
);

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[_chapter],
    );

const String legacyMokuroBookKey = 'mokuro:Series';

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;
  late MangaDownloadService downloads;
  late String bookKey;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-manga-cascade-');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeAdapter(),
    );
    downloads = MangaDownloadService(
      database: db,
      serviceFor: (OnlineMangaRuntimeKind runtime) => library,
      saveAsCbz: () => false,
    );
    bookKey = (await library.add(_entry())).bookKey;
    // 一条该书的章节任务 + 一条与书无关的 mokuro 卷任务；服务不 start，行停在 queued。
    await downloads.enqueueChapter(
      entry: _entry(),
      chapter: _chapter,
      autoOcr: false,
    );
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: 'legacy-mokuro-01',
        kind: MangaDownloadJobKind.mokuroVolume,
        bookKey: legacyMokuroBookKey,
        chapterKey: 'Series 01',
        runtime: 'mokuro_moe',
        title: 'Series · Series 01',
        chapterTitle: 'Series 01',
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(0),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    expect(await db.listMangaDownloadJobs(), hasLength(2));
  });

  tearDown(() async {
    downloads.dispose();
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<Set<String>> bookKeysLeft() async => (await db.listMangaDownloadJobs())
      .map((MangaDownloadJobRow r) => r.bookKey)
      .toSet();

  test('deleteEpubBook 级联删该书的章节任务，旧 mokuro 任务不受影响', () async {
    await db.deleteEpubBook(bookKey, tombstone: true);
    expect(await db.getEpubBook(bookKey), isNull);
    expect(await bookKeysLeft(), <String>{legacyMokuroBookKey});
  });

  test('deleteMangaDownloadJobsForBook 直接调也删干净', () async {
    expect(await db.deleteMangaDownloadJobsForBook(bookKey), 1);
    expect(await bookKeysLeft(), <String>{legacyMokuroBookKey});
    expect(await db.getEpubBook(bookKey), isNotNull, reason: '只删任务行，不动书');
  });
}
