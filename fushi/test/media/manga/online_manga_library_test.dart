import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/media/manga/download/download_library_index.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/media/manga/mihon/mihon_models.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

/// 身份串的分隔符是 NUL。测试里也用 `String.fromCharCode(0)` 而不是源码字面量：
/// 裸 NUL 会让 git 把 .dart 判成 binary，diff/merge 会静默丢改动。
final String _nul = String.fromCharCode(0);

void main() {
  // 封面经收口落盘后要驱逐 PaintingBinding.imageCache：没有 binding 会在写完之后抛，
  // 被 add 的 on Object 吞掉，表现为「文件在、coverPath 却是 null」的假红。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FushiDatabase database;
  late OnlineMangaLibraryService service;

  OnlineMangaLibraryEntry entryFor({
    List<OnlineMangaChapter> chapters = const <OnlineMangaChapter>[],
    int? currentChapterIndex,
  }) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: 'org.example.fixture',
        sourceId: '9223372036854775807',
        series: const OnlineMangaSeries(
          key: '/series/fixture',
          title: 'Fixture series',
          author: 'Fixture author',
          coverUrl: 'https://example.test/cover',
          raw: <String, Object?>{'url': '/series/fixture'},
        ),
        chapters: chapters,
        currentChapterIndex: currentChapterIndex,
      );

  const List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
    OnlineMangaChapter(
      key: '/chapter/2',
      name: 'Chapter 2',
      number: 2,
      uploadedAt: 2,
      raw: <String, Object?>{'url': '/chapter/2'},
    ),
    OnlineMangaChapter(
      key: '/chapter/1',
      name: 'Chapter 1',
      number: 1,
      uploadedAt: 1,
      raw: <String, Object?>{'url': '/chapter/1'},
    ),
  ];

  late _FixtureAdapter adapter;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi-online-manga-');
    // 2026-09-12 起在线条目直接落 `<fushi_books>/<bookKey>`；测试里把书根钉到临时目录。
    EpubStorage.debugBaseDirectoryOverride = root.path;
    database = FushiDatabase.forTesting(NativeDatabase.memory());
    adapter = _FixtureAdapter();
    service = OnlineMangaLibraryService(
      database: database,
      rootDirectory: root,
      downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
      adapter: adapter,
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('订阅只属于书架：membership=false 的条目拒绝写订阅位', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
      (await database.getEpubBook(row.bookKey))!.sourceMetadata,
    )!;
    await (database.update(database.epubBooks)
          ..where((t) => t.bookKey.equals(row.bookKey)))
        .write(const EpubBooksCompanion(inLibrary: Value<bool>(false)));

    await expectLater(
      service.setSubscription(
        bookKey: row.bookKey,
        entry: entry,
        subscribed: true,
        autoDownload: true,
      ),
      throwsStateError,
      reason: '非书架作品不能订阅 / 自动追更',
    );
  });

  test('入库写出漫画身份与描述符，不创建目录、不请求封面', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));

    expect(row.bookKey, startsWith('mihon-'));
    expect(row.format, 'manga');
    expect(row.coverPath, isNull, reason: '封面属于 Cache；入库不再写 cover.*');
    expect(adapter.coverCalls, 0, reason: '入库/浏览不得请求封面');
    expect(
      Directory(row.extractDir).existsSync(),
      isFalse,
      reason: 'Download library 只在真正开始章节下载时物化',
    );

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(parsed.runtime, OnlineMangaRuntimeKind.mihon);
    expect(parsed.sourceId, '9223372036854775807');
    expect(parsed.chapters, hasLength(2));
    expect(OnlineMangaLibraryService.initialChapterIndex(parsed), 1,
        reason: '源按新→旧返回，新读者从列表末尾（最旧那话）开始');

    final EpubBookRow again = await service.add(entryFor(chapters: chapters));
    expect(again.bookKey, row.bookKey);
    expect(await database.getAllEpubBooks(), hasLength(1));
  });

  test('已有 cover.* 不因再次入库 / 刷新被删除或清空', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final File existingCover = File(p.join(row.extractDir, 'cover.jpg'));
    await existingCover.parent.create(recursive: true);
    await existingCover.writeAsBytes(<int>[0xFF, 0xD8, 0xFF]);
    await (database.update(database.epubBooks)
          ..where((t) => t.bookKey.equals(row.bookKey)))
        .write(const EpubBooksCompanion(
          coverPath: Value<String?>('cover.jpg'),
        ));

    final EpubBookRow again = await service.add(entryFor(chapters: chapters));

    expect(again.coverPath, 'cover.jpg', reason: '刷新不改写已有封面路径');
    expect(existingCover.existsSync(), isTrue, reason: '已有封面文件不得被删除');
    expect(adapter.coverCalls, 0, reason: '刷新也不抓取封面');
  });

  test('打开在线源作品页 ensureNonLibrary 只写库：不建目录、不请求封面', () async {
    final EpubBookRow row = await service.ensureNonLibrary(
      entryFor(chapters: chapters),
    );

    expect(row.inLibrary, isFalse);
    expect(row.coverPath, isNull);
    expect(adapter.coverCalls, 0, reason: '浏览作品页不得抓取封面');
    expect(
      Directory(p.join(root.path, 'downloads')).existsSync(),
      isFalse,
      reason: '浏览作品页不得创建 downloads/{source}/{manga}',
    );
  });

  OnlineMangaLibraryEntry entryVariant({
    required String sourceId,
    required String seriesKey,
    required String title,
    String extensionPackage = 'org.example.fixture',
  }) =>
      OnlineMangaLibraryEntry(
        runtime: OnlineMangaRuntimeKind.mihon,
        extensionPackage: extensionPackage,
        sourceId: sourceId,
        series: OnlineMangaSeries(
          key: seriesKey,
          title: title,
          raw: <String, Object?>{'url': seriesKey},
        ),
        chapters: chapters,
      );

  OnlineMangaLibraryService serviceWith(
    OnlineMangaRuntimeAdapter runtimeAdapter,
  ) => OnlineMangaLibraryService(
    database: database,
    rootDirectory: root,
    downloadsRootDirectory: Directory(p.join(root.path, 'downloads')),
    adapter: runtimeAdapter,
  );

  _LanguageFixtureAdapter languageAdapter({
    String label = 'Fixture',
    String? language,
  }) => _LanguageFixtureAdapter()
    ..sourceLabelText = label
    ..sourceLanguageText = language;

  test('占位来源条目：按 (sourceId, series key) 命中，不从已安装来源重复入库',
      () async {
    final OnlineMangaLibraryEntry placeholder = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      // 导入时扩展未安装：身份保留真实数字 sourceId，扩展包是占位值。
      extensionPackage: 'mihon.unavailable',
      sourceId: '524579092615598717',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: chapters,
    );
    final EpubBookRow existing = await service.add(placeholder);

    // 安装扩展后从来源浏览到同一部作品：扩展包变为真实值，sourceId、key 不变。
    final OnlineMangaLibraryEntry browsed = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '524579092615598717',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: chapters,
    );

    final EpubBookRow? found = await service.find(browsed);
    expect(found?.bookKey, existing.bookKey,
        reason: '数字 sourceId + series key 相同就是同一部作品');
    expect(await database.getAllEpubBooks(), hasLength(1));
    expect(found!.uid, existing.uid, reason: '命中已有行，不新建身份/进度载体');

    await service.add(browsed);
    expect(await database.getAllEpubBooks(), hasLength(1),
        reason: 'add 也不能为同一部作品建第二行');
    final OnlineMangaLibraryEntry kept =
        OnlineMangaLibraryEntry.tryParse(
          (await database.getEpubBook(existing.bookKey))!.sourceMetadata,
        )!;
    expect(kept.extensionPackage, 'mihon.unavailable',
        reason: '运行时回退不改写存量条目的扩展包身份');
  });

  test('两个同名 Source 的下载落在不同目录，第二个带短源 ID 后缀', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    final EpubBookRow second = await service.add(
      entryVariant(
        sourceId: '2002',
        seriesKey: '/series/second',
        title: 'Fixture series',
      ),
    );

    expect(
      first.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series'),
    );
    expect(second.extractDir, isNot(first.extractDir));
    expect(
      p.dirname(second.extractDir),
      matches(RegExp(r'[/\\]Fixture \[[0-9a-f]{8}\]$')),
      reason: '同名 Source 用短源 ID 后缀区分，仍然可读',
    );
    expect(p.basename(second.extractDir), 'Fixture series');
    expect(
      Directory(second.extractDir).existsSync(),
      isFalse,
      reason: '入库只解析路径，不创建目录',
    );
  });

  /// 在漫画目录里写一章带稳定身份的 `pages.json`：模拟「作品已移出书架但
  /// 下载文件仍在磁盘上」。目录归属由 pages.json 证明，不依赖 epub_books 行。
  Future<void> writeSourceManifest(
    String mangaDir, {
    required String sourceId,
    required String seriesKey,
    String mangaTitle = 'Fixture series',
    String chapterDirName = 'Chapter 1',
    String chapterKey = '/chapter/1',
    String chapterName = 'Chapter 1',
    String extensionPackage = 'org.example.fixture',
    bool writePage = false,
  }) async {
    final Directory chapterDir = downloadChapterDirectory(
      mangaDir,
      chapterDirName,
    );
    await chapterDir.create(recursive: true);
    if (writePage) {
      await File(p.join(chapterDir.path, '001.jpg')).writeAsString('page');
    }
    await writePagesManifestAtomically(
      chapterDir,
      MangaPagesManifest(
        sourceRuntime: 'mihon',
        sourceId: sourceId,
        sourceName: 'Fixture',
        extensionPackage: extensionPackage,
        mangaKey: seriesKey,
        mangaTitle: mangaTitle,
        chapterKey: chapterKey,
        chapterName: chapterName,
        payload: const MokuroPayload(
          images: <MokuroImage>[
            MokuroImage(
              url: '001.jpg',
              size: MokuroSize(100, 150),
              blocks: <MokuroBlock>[],
            ),
          ],
        ),
        downloadedAt: DateTime.utc(2026, 11, 7),
      ),
    );
  }

  test('pages.json 证明同一作品时复用已有漫画文件夹（改过名也不生成 (2)）', () async {
    final EpubBookRow original = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    final Directory renamed = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Old folder name'),
    );
    // 入库不再建目录；这里模拟「用户/旧版本已下载过」的磁盘状态。
    await Directory(original.extractDir).create(recursive: true);
    await renamed.parent.create(recursive: true);
    await Directory(original.extractDir).rename(renamed.path);
    await writeSourceManifest(
      renamed.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );
    // 旧行为（移出书架删除行）会把它当成「磁盘上已占用的同名目录」→ (2)。
    await database.deleteEpubBook(original.bookKey);

    final EpubBookRow readded = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(readded.extractDir, renamed.path);
    expect(
      Directory(
        p.join(root.path, 'downloads', 'Fixture', 'Fixture series (2)'),
      ).existsSync(),
      isFalse,
      reason: 'pages.json 已经证明该文件夹就是这部作品，不应再生成重复目录',
    );
    expect(
      File(p.join(renamed.path, 'Chapter 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '复用不得删除或移动已有章节文件',
    );
  });

  /// 手工制作一个 CBZ 章节：包根平铺 `001.jpg` + `pages.json`。
  Future<File> writeArchiveManifest({
    required String mangaDir,
    required String fileName,
    required String sourceId,
    required String seriesKey,
    String chapterKey = '/chapter/1',
    String chapterName = 'Chapter 1',
    String extensionPackage = 'org.example.fixture',
  }) async {
    final MangaPagesManifest manifest = MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: sourceId,
      sourceName: 'Fixture',
      extensionPackage: extensionPackage,
      mangaKey: seriesKey,
      mangaTitle: 'Fixture series',
      chapterKey: chapterKey,
      chapterName: chapterName,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    );
    final Archive archive = Archive();
    final List<int> page = utf8.encode('page');
    archive.addFile(ArchiveFile('001.jpg', page.length, page));
    final List<int> manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    archive.addFile(
      ArchiveFile(kDownloadPagesFileName, manifestBytes.length, manifestBytes),
    );
    await Directory(mangaDir).create(recursive: true);
    final File file = downloadChapterArchiveFile(mangaDir, fileName);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  test('CBZ 章节内的 pages.json 也参与身份复用与映射', () async {
    final Directory existing = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Old folder name'),
    );
    final File archive = await writeArchiveManifest(
      mangaDir: existing.path,
      fileName: 'Chapter 1.cbz',
      sourceId: '1001',
      seriesKey: '/series/first',
    );

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(
      row.extractDir,
      existing.path,
      reason: 'CBZ 包内 pages.json 足以证明文件夹属于这部作品',
    );
    expect(archive.existsSync(), isTrue);
    final MangaChapterDirRow? mapping = await database.getMangaChapterDir(
      row.bookKey,
      '/chapter/1',
    );
    expect(mapping?.folderName, 'Chapter 1.cbz');
    expect(mapping?.containerKindEnum, MangaChapterContainerKind.archive);
    expect(
      await DownloadLibraryIndex(
        database,
      ).isChapterDownloaded(bookKey: row.bookKey, chapterKey: '/chapter/1'),
      isTrue,
    );
  });

  test('多个文件夹都匹配同一身份：不猜，保持冲突后缀且不改动已有目录', () async {
    final Directory first = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series'),
    );
    final Directory second = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series (2)'),
    );
    await writeSourceManifest(
      first.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );
    await writeSourceManifest(
      second.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );
    final File sentinelFirst = File(p.join(first.path, 'keep.txt'));
    final File sentinelSecond = File(p.join(second.path, 'keep.txt'));
    await sentinelFirst.writeAsString('first');
    await sentinelSecond.writeAsString('second');

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(
      row.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series (3)'),
      reason: '两个目录都能证明同一身份时不得猜其中一个，按冲突规则另建目录',
    );
    expect(await sentinelFirst.readAsString(), 'first');
    expect(await sentinelSecond.readAsString(), 'second');
    expect(
      await database.getMangaChapterDir(row.bookKey, '/chapter/1'),
      isNull,
      reason: '没有选定目录，不得把任何候选章的映射写进新条目',
    );
  });

  test('扩展包只做 tie-breaker：多匹配时选真实包一致的目录', () async {
    final Directory placeholder = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Placeholder copy'),
    );
    final Directory real = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Real copy'),
    );
    await writeSourceManifest(
      placeholder.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      extensionPackage: 'mihon.unavailable',
      writePage: true,
    );
    await writeSourceManifest(
      real.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(
      row.extractDir,
      real.path,
      reason: '两个目录核心身份相同时，扩展包 tie-breaker 选中真实包命中的那个',
    );
  });

  test('条目是占位扩展包时，真实包 manifest 仍视为同一身份', () async {
    final Directory existing = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Old folder name'),
    );
    await writeSourceManifest(
      existing.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
        extensionPackage: 'mihon.unavailable',
      ),
    );

    expect(
      row.extractDir,
      existing.path,
      reason: 'mihon.unavailable 与真实包在数字 sourceId + seriesKey 下是同一身份',
    );
  });

  test('没有 manifest 的现有漫画目录仍按 (2) 安全规则，不覆盖', () async {
    final Directory existing = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series'),
    );
    final Directory chapter = Directory(p.join(existing.path, 'Chapter 1'));
    await chapter.create(recursive: true);
    final File sentinel = File(p.join(chapter.path, '001.jpg'));
    await sentinel.writeAsString('keep me');

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(
      row.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series (2)'),
      reason: '没有 pages.json 无法证明归属，保持原有 (2) 安全规则',
    );
    expect(await sentinel.readAsString(), 'keep me');
    expect(
      await database.getMangaChapterDir(row.bookKey, '/chapter/1'),
      isNull,
      reason: '无法证明归属的章不得进下载索引',
    );
  });

  test('复用文件夹后立即重建章节映射：已下载章节马上可查', () async {
    final EpubBookRow original = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    final Directory reused = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Old folder name'),
    );
    await Directory(original.extractDir).create(recursive: true);
    await reused.parent.create(recursive: true);
    await Directory(original.extractDir).rename(reused.path);
    // 两章都已落盘。
    await writeSourceManifest(
      reused.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      chapterDirName: 'Chapter 2',
      chapterKey: '/chapter/2',
      chapterName: 'Chapter 2',
      writePage: true,
    );
    await writeSourceManifest(
      reused.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      chapterDirName: 'Chapter 1',
      chapterKey: '/chapter/1',
      chapterName: 'Chapter 1',
      writePage: true,
    );
    await database.deleteEpubBook(original.bookKey);

    final EpubBookRow readded = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    final MangaChapterDirRow? first = await database.getMangaChapterDir(
      readded.bookKey,
      '/chapter/1',
    );
    final MangaChapterDirRow? second = await database.getMangaChapterDir(
      readded.bookKey,
      '/chapter/2',
    );
    expect(first?.folderName, 'Chapter 1');
    expect(second?.folderName, 'Chapter 2');

    final DownloadLibraryIndex index = DownloadLibraryIndex(database);
    expect(
      await index.downloadedChapterKeys(readded.bookKey, <String>[
        '/chapter/1',
        '/chapter/2',
      ]),
      <String>{'/chapter/1', '/chapter/2'},
      reason: '复用并 re-link 后详情页必须立即显示已下载，而不是等手动重建索引',
    );
  });

  test('源已移出书架但 downloads/<source> 仍在：同名新源仍加短源 ID 后缀', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    await writeSourceManifest(
      first.extractDir,
      sourceId: '1001',
      seriesKey: '/series/first',
    );
    // 「移出书架」：只删记录，文件保留。
    await database.deleteEpubBook(first.bookKey);
    expect(await database.getAllEpubBooks(), isEmpty);

    final EpubBookRow second = await service.add(
      entryVariant(
        sourceId: '2002',
        seriesKey: '/series/second',
        title: 'Fixture series',
      ),
    );

    expect(
      p.dirname(second.extractDir),
      matches(RegExp(r'[/\\]Fixture \[[0-9a-f]{8}\]$')),
      reason: '磁盘上的 Fixture 目录已由 pages.json 证明属于 Source 1001',
    );
    expect(
      Directory(first.extractDir).existsSync(),
      isTrue,
      reason: '新源不得占用/覆盖旧源的目录',
    );
  });

  test('同一 Source 移出书架后再加新作品：仍复用它在磁盘上的目录', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    await writeSourceManifest(
      first.extractDir,
      sourceId: '1001',
      seriesKey: '/series/first',
    );
    await database.deleteEpubBook(first.bookKey);

    final EpubBookRow again = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/another',
        title: 'Another series',
      ),
    );

    expect(
      p.dirname(again.extractDir),
      p.join(root.path, 'downloads', 'Fixture'),
      reason: '同一 Source 的 pages.json 身份命中，应继续用同一个源目录',
    );
  });

  test('不同 Source 的同名 Manga 不互相覆盖', () async {
    adapter.sourceLabelText = 'Alpha';
    final EpubBookRow alpha = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/same',
        title: 'Same title',
      ),
    );
    adapter.sourceLabelText = 'Beta';
    final EpubBookRow beta = await service.add(
      entryVariant(
        sourceId: '2',
        seriesKey: '/series/same',
        title: 'Same title',
      ),
    );

    expect(
      alpha.extractDir,
      p.join(root.path, 'downloads', 'Alpha', 'Same title'),
    );
    expect(
      beta.extractDir,
      p.join(root.path, 'downloads', 'Beta', 'Same title'),
    );
    expect(Directory(alpha.extractDir).existsSync(), isFalse);
    expect(Directory(beta.extractDir).existsSync(), isFalse);
  });

  test('同一 Source 下同名不同作品共用同一漫画目录，不生成 (2)', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/a',
        title: 'Same title',
      ),
    );
    final EpubBookRow second = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/b',
        title: 'Same title',
      ),
    );

    expect(
      first.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Same title'),
    );
    expect(
      second.extractDir,
      first.extractDir,
      reason: '同一 Source 下标题完全相同的不同作品共用目录，与 Mihon 一致',
    );
    expect(
      Directory(
        p.join(root.path, 'downloads', 'Fixture', 'Same title (2)'),
      ).existsSync(),
      isFalse,
      reason: '不同身份不因同名新建 (2) 目录',
    );
    expect(
      Directory(first.extractDir).existsSync(),
      isFalse,
      reason: '入库仍然只解析路径，不创建目录',
    );
  });

  test('清库后同名不同作品按磁盘 manifest 标题复用同一目录', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/a',
        title: 'Same title',
      ),
    );
    await Directory(first.extractDir).create(recursive: true);
    await writeSourceManifest(
      first.extractDir,
      sourceId: '1',
      seriesKey: '/series/a',
      mangaTitle: 'Same title',
      writePage: true,
    );
    await database.deleteEpubBook(first.bookKey);

    final EpubBookRow second = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/b',
        title: 'Same title',
      ),
    );

    expect(
      second.extractDir,
      first.extractDir,
      reason: 'manifest 标题证明这是同名作品，清库重开后仍然共享目录',
    );
    expect(
      await database.getMangaChapterDir(second.bookKey, '/chapter/1'),
      isNull,
      reason: '共享目录里另一部作品的章节不得写进本作品的映射',
    );
    expect(
      File(
        p.join(first.extractDir, 'Chapter 1', '001.jpg'),
      ).existsSync(),
      isTrue,
      reason: '共享不得删除另一部作品已下载的章',
    );
  });

  test('净化后同名但标题不同的作品仍按 (2) 安全规则分目录', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/slash',
        title: 'Same/title',
      ),
    );
    await Directory(first.extractDir).create(recursive: true);
    await writeSourceManifest(
      first.extractDir,
      sourceId: '1',
      seriesKey: '/series/slash',
      mangaTitle: 'Same/title',
      writePage: true,
    );

    final EpubBookRow second = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/colon',
        title: 'Same:title',
      ),
    );

    expect(
      first.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Same_title'),
    );
    expect(
      second.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Same_title (2)'),
      reason: '标题不同（只是净化后同名）不共享目录，保持原有冲突后缀',
    );
  });

  test('大小写不敏感冲突：同名 Manga 与同名 Source 都加后缀', () async {
    final EpubBookRow upper = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/a',
        title: 'Series',
      ),
    );
    final EpubBookRow lower = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/b',
        title: 'series',
      ),
    );
    expect(
      upper.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Series'),
    );
    expect(
      lower.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'series (2)'),
      reason: 'Windows 文件系统大小写不敏感，Series 与 series 不能共存',
    );

    adapter.sourceLabelText = 'fixture';
    final EpubBookRow otherSource = await service.add(
      entryVariant(
        sourceId: '2',
        seriesKey: '/series/c',
        title: 'Other',
      ),
    );
    expect(
      p.dirname(otherSource.extractDir),
      matches(RegExp(r'[/\\]fixture \[[0-9a-f]{8}\]$')),
      reason: 'Source 显示名只有大小写不同也算同名冲突',
    );
  });

  test('磁盘上已有未入库的非空 manga 目录：不覆盖，改用 (2)', () async {
    final Directory existing = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Same title'),
    );
    await existing.create(recursive: true);
    final File sentinel = File(p.join(existing.path, 'keep.txt'));
    await sentinel.writeAsString('do not touch');

    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/a',
        title: 'Same title',
      ),
    );

    expect(await sentinel.readAsString(), 'do not touch');
    expect(
      row.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Same title (2)'),
    );
  });

  test('保留名与结尾空格/点：source 与 manga 目录名都被净化', () async {
    adapter.sourceLabelText = 'CON';
    final EpubBookRow row = await service.add(
      entryVariant(
        sourceId: '1',
        seriesKey: '/series/con',
        title: 'NUL. ',
      ),
    );
    expect(
      row.extractDir,
      p.join(root.path, 'downloads', '_CON', '_NUL'),
    );
  });

  test('新下载的源目录名为「源名 (LANG)」：语言大写、保留子标签', () async {
    final OnlineMangaLibraryService langService = serviceWith(
      languageAdapter(label: '六漫画', language: 'zh-Hans'),
    );
    final EpubBookRow row = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );

    expect(
      p.dirname(row.extractDir),
      p.join(root.path, 'downloads', '六漫画 (ZH-HANS)'),
    );
    expect(Directory(row.extractDir).existsSync(), isFalse);
  });

  test('语言为空 / all / multi 视为无语言：源目录不写后缀', () async {
    final _LanguageFixtureAdapter langAdapter = languageAdapter();
    final OnlineMangaLibraryService langService = serviceWith(langAdapter);
    const List<(String, String)> cases = <(String, String)>[
      ('Empty Language', ''),
      ('All Language', 'all'),
      ('Multi Language', 'multi'),
    ];
    for (final (String label, String language) in cases) {
      langAdapter
        ..sourceLabelText = label
        ..sourceLanguageText = language;
      final EpubBookRow row = await langService.add(
        entryVariant(
          sourceId: 'id-$label',
          seriesKey: '/series/$label',
          title: 'Series $label',
        ),
      );
      expect(
        p.dirname(row.extractDir),
        p.join(root.path, 'downloads', label),
        reason: '语言 "$language" 不应产生 (ALL) 之类的后缀',
      );
    }
  });

  test('语言后缀与源名一起走现有 Windows 净化规则', () async {
    final OnlineMangaLibraryService langService = serviceWith(
      languageAdapter(label: 'Bad:Source', language: 'zh-Hans'),
    );
    final EpubBookRow row = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/bad',
        title: 'Fixture series',
      ),
    );

    expect(
      p.dirname(row.extractDir),
      p.join(root.path, 'downloads', 'Bad_Source (ZH-HANS)'),
    );
  });

  test('同名同语言的两个 Source：短哈希后缀仍追加在 (LANG) 之后', () async {
    final OnlineMangaLibraryService langService = serviceWith(
      languageAdapter(language: 'en'),
    );
    final EpubBookRow first = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    final EpubBookRow second = await langService.add(
      entryVariant(
        sourceId: '2002',
        seriesKey: '/series/second',
        title: 'Fixture series',
      ),
    );

    expect(
      p.dirname(first.extractDir),
      p.join(root.path, 'downloads', 'Fixture (EN)'),
    );
    expect(
      p.dirname(second.extractDir),
      matches(RegExp(r'[/\\]Fixture \(EN\) \[[0-9a-f]{8}\]$')),
    );
  });

  test('同名不同语言的 Source：靠 (LANG) 区分，无需哈希后缀', () async {
    final _LanguageFixtureAdapter langAdapter = languageAdapter(language: 'en');
    final OnlineMangaLibraryService langService = serviceWith(langAdapter);
    final EpubBookRow en = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/en',
        title: 'EN series',
      ),
    );
    langAdapter.sourceLanguageText = 'zh-Hans';
    final EpubBookRow zh = await langService.add(
      entryVariant(
        sourceId: '2002',
        seriesKey: '/series/zh',
        title: 'ZH series',
      ),
    );

    expect(
      p.dirname(en.extractDir),
      p.join(root.path, 'downloads', 'Fixture (EN)'),
    );
    expect(
      p.dirname(zh.extractDir),
      p.join(root.path, 'downloads', 'Fixture (ZH-HANS)'),
    );
  });

  test('已有源目录不重命名：同一 Source 在语言出现后仍复用旧目录', () async {
    final EpubBookRow first = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'First series',
      ),
    );
    expect(
      p.dirname(first.extractDir),
      p.join(root.path, 'downloads', 'Fixture'),
    );

    final OnlineMangaLibraryService langService = serviceWith(
      languageAdapter(language: 'en'),
    );
    final EpubBookRow second = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/second',
        title: 'Second series',
      ),
    );

    expect(
      p.dirname(second.extractDir),
      p.join(root.path, 'downloads', 'Fixture'),
      reason: '目录名不是身份：已存在的源目录不因命名规则变化而重命名',
    );
  });

  test('源语言后来变化：已建立的 (LANG) 目录不被重命名', () async {
    final _LanguageFixtureAdapter langAdapter = languageAdapter(language: 'en');
    final OnlineMangaLibraryService langService = serviceWith(langAdapter);
    final EpubBookRow first = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'First series',
      ),
    );
    expect(
      p.dirname(first.extractDir),
      p.join(root.path, 'downloads', 'Fixture (EN)'),
    );

    langAdapter.sourceLanguageText = 'ja';
    final EpubBookRow second = await langService.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/second',
        title: 'Second series',
      ),
    );

    expect(
      p.dirname(second.extractDir),
      p.join(root.path, 'downloads', 'Fixture (EN)'),
    );
  });

  test('封面不再属于 Download library：入库不抓取、不落 cover.* 文件', () async {
    // 即使源能返回坏字节，也不该走到封面抓取/落盘（BUG-2496 的旧路径已移除）。
    adapter.coverBytes = utf8.encode('<html><body>403 Forbidden</body></html>');

    final EpubBookRow row = await service.add(entryFor(chapters: chapters));

    expect(row.coverPath, isNull);
    expect(adapter.coverCalls, 0, reason: '入库不得请求封面');
    expect(
      Directory(row.extractDir).existsSync(),
      isFalse,
      reason: '没有目录就不该有任何 cover.* 文件',
    );
    expect(row.format, 'manga', reason: '封面缺失不能挡住「追这部作品」');
  });

  // 合集（collection）功能已随 my-comic v1 移除：互联在线漫画不再收养主合集。

  test('BUG-3443：重新收下经互联来的漫画撤销此前写的对端键删除墓碑，'
      '不碰无关墓碑', () async {
    final OnlineMangaLibraryEntry entry = InterconnectMangaCatalog.entryFor(
      const RemoteBookInfo(
        title: 'Remote manga',
        bookKey: 'host-manga-key',
        hasContent: false,
        hasMangaChapters: true,
        format: 'manga',
      ),
    );
    // 上一次「从所有设备删除」写的是对端键（本机 interconnect- 键对端认不出），
    // 还没推出去就又收下了：留着它，下一轮会把 host 上的书删掉。
    await database.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue, 'host-manga-key', 100);
    await database.writeSyncDeletionTombstone(
        SyncTombstoneKind.book.dbValue, 'unrelated', 100);

    await service.add(entry);

    expect(
      <String>{
        for (final SyncDeletionTombstoneRow r
            in await database.getSyncDeletionTombstonesOfType(
                SyncTombstoneKind.book.dbValue))
          r.itemKey,
      },
      <String>{'unrelated'},
    );
  });

  test('刷出空章节列表不得覆盖书架：抛失败、库里旧描述符原样保留', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final OnlineMangaLibraryEntry stored =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(stored.chapters, hasLength(2));

    // Mihon 的 chapterListParse 撞 Cloudflare 拦截页时**返回空列表而不抛**。
    await expectLater(
      service.refresh(
        bookKey: row.bookKey,
        existing: stored,
        series: stored.series,
        chapters: const <OnlineMangaChapter>[],
      ),
      throwsA(isA<OnlineMangaUnavailable>()),
    );

    final EpubBookRow? after = await database.getEpubBook(row.bookKey);
    final OnlineMangaLibraryEntry kept =
        OnlineMangaLibraryEntry.tryParse(after!.sourceMetadata)!;
    expect(kept.chapters, hasLength(2),
        reason: '一次没抛异常的失败刷新不得把书架里的章节清空');
    expect(after.chapterCount, 2);
  });

  test('刷新本来就空的条目仍照常落库（守卫只挡「有变没有」）', () async {
    final EpubBookRow row = await service.add(entryFor());
    final OnlineMangaLibraryEntry stored =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    expect(stored.chapters, isEmpty);

    final OnlineMangaLibraryEntry? updated = await service.refresh(
      bookKey: row.bookKey,
      existing: stored,
      series: stored.series,
      chapters: chapters,
    );
    expect(updated?.chapters, hasLength(2));
  });

  test('bookKey 与 v88 的推导逐字节一致（存量书架条目不能变孤儿）', () async {
    // v88 的公式（fushi/lib/src/media/manga/mihon/mihon_library.dart 原文）：
    //   sha256(packageName NUL sourceId NUL manga.url)[0:32]，前缀 'mihon-'
    // 这里独立重算一遍，而不是调被测代码——两侧同源取值的比较恒真。
    final String identity = <String>[
      'org.example.fixture',
      '9223372036854775807',
      '/series/fixture',
    ].join(_nul);
    final String expected =
        'mihon-${sha256.convert(utf8.encode(identity)).toString().substring(0, 32)}';

    expect(
      OnlineMangaLibraryService.bookKeyOf(entryFor()),
      expected,
      reason: 'bookKey 既是 epub_books 主键也是磁盘目录名；改一个字符就等于把'
          '所有已入库的在线漫画变成找不到的孤儿',
    );
  });

  test('v1 描述符（hibiki-mihon）仍能解析——存量条目零改动继续可用', () {
    final String legacy = jsonEncode(<String, Object?>{
      'type': 'hibiki-mihon',
      'version': 1,
      'extensionPackage': 'org.example.fixture',
      'sourceId': '9223372036854775807',
      'manga': <String, Object?>{
        'url': '/series/fixture',
        'title': 'Fixture series',
        'author': 'Fixture author',
        'thumbnail_url': 'https://example.test/cover',
      },
      'chapters': <Map<String, Object?>>[
        <String, Object?>{
          'url': '/chapter/2',
          'name': 'Chapter 2',
          'chapter_number': 2,
          'date_upload': 2,
        },
        <String, Object?>{
          'url': '/chapter/1',
          'name': 'Chapter 1',
          'chapter_number': 1,
          'date_upload': 1,
        },
      ],
      'currentChapterIndex': 1,
    });

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(legacy)!;
    expect(parsed.runtime, OnlineMangaRuntimeKind.mihon);
    expect(parsed.series.key, '/series/fixture');
    expect(parsed.series.coverUrl, 'https://example.test/cover');
    expect(parsed.chapters.map((OnlineMangaChapter c) => c.key),
        <String>['/chapter/2', '/chapter/1']);
    expect(parsed.currentChapter?.name, 'Chapter 1');
    expect(
      parsed.chapters.first.raw['url'],
      '/chapter/2',
      reason: 'raw 必须原样保留，否则回灌 getPages 时拿不到源认识的 payload',
    );
  });

  test('无 key 的章节被丢弃，不会挤进同一个空 chapterKey 主键', () {
    final String payload = jsonEncode(<String, Object?>{
      'type': 'hibiki-online-manga',
      'version': 2,
      'runtime': 'mihon',
      'extensionPackage': 'org.example.fixture',
      'sourceId': '1',
      'series': <String, Object?>{'key': '/s', 'title': 'S', 'raw': <String, Object?>{}},
      'chapters': <Map<String, Object?>>[
        <String, Object?>{'key': '', 'name': 'broken', 'raw': <String, Object?>{}},
        <String, Object?>{'key': '/c/1', 'name': 'ok', 'raw': <String, Object?>{}},
      ],
    });
    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(payload)!;
    expect(parsed.chapters, hasLength(1));
    expect(parsed.chapters.single.key, '/c/1');
  });

  test('选章不再清零 reader_positions（换章不丢上一章进度）', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    await ReaderPositionRepository(database).save(
      bookUid: row.uid,
      sectionIndex: 7,
      normCharOffset: 0,
      charOffset: 0,
    );

    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    final OnlineMangaLibraryEntry selected = await service.selectChapter(
      bookKey: row.bookKey,
      entry: parsed,
      chapterIndex: 0,
    );
    expect(selected.currentChapter?.name, 'Chapter 2');

    final ReaderPosition? position =
        await ReaderPositionRepository(database).findByBookUid(row.uid);
    expect(
      position?.sectionIndex,
      7,
      reason: 'v88 前 selectChapter 会把这一行清零，于是换章即永久丢掉上一章'
          '的位置；每章进度归 manga_chapter_states 之后，选章不该再破坏它',
    );
  });

  test('刷新按 chapterKey 重定位当前章，而不是沿用下标', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));
    final OnlineMangaLibraryEntry parsed =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    // 当前停在最旧那话（下标 1）。
    final OnlineMangaLibraryEntry selected = await service.selectChapter(
      bookKey: row.bookKey,
      entry: parsed,
      chapterIndex: 1,
    );

    // 源更新：最前面插了一话新的，于是原来那话的下标从 1 变成 2。
    const OnlineMangaChapter fresh = OnlineMangaChapter(
      key: '/chapter/3',
      name: 'Chapter 3',
      number: 3,
      uploadedAt: 3,
      raw: <String, Object?>{'url': '/chapter/3'},
    );
    final OnlineMangaLibraryEntry? refreshed = await service.refresh(
      bookKey: row.bookKey,
      existing: selected,
      series: selected.series,
      chapters: <OnlineMangaChapter>[fresh, ...chapters],
    );

    expect(refreshed!.currentChapterIndex, 2);
    expect(
      refreshed.currentChapter?.name,
      'Chapter 1',
      reason: '刷新后必须还停在同一话上；沿用旧下标会把用户挪到别的章',
    );
  });

  test('新条目指向 Download library 路径，目录只在下载侧物化时才创建', () async {
    final EpubBookRow row = await service.add(entryFor(chapters: chapters));

    expect(
      row.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series'),
    );
    expect(
      Directory(p.join(root.path, 'downloads', 'Fixture')).existsSync(),
      isFalse,
      reason: '浏览/入库不创建 source 层',
    );
    expect(
      Directory(p.join(row.extractDir, 'chapters')).existsSync(),
      isFalse,
      reason: '新布局章节是 manga 目录的直接子目录，不再有 chapters/ 中转层',
    );
    expect(
      File(p.join(row.extractDir, 'manga.json')).existsSync(),
      isFalse,
      reason: '章节身份在各自 pages.json，不再写书根占位',
    );
    // 下载 worker 是唯一的物化入口：开始下载时才建目录。
    expect(await service.ensureBookDirectory(row), row,
        reason: '已在标准位置：不改 extractDir');
    expect(Directory(row.extractDir).existsSync(), isTrue,
        reason: '下载侧 ensureBookDirectory 必须建出目录');
  });

  test('漫画改名不自动重命名或重指向已建立的下载目录', () async {
    final EpubBookRow added = await service.add(entryFor(chapters: chapters));
    final String originalDir = added.extractDir;
    final OnlineMangaLibraryEntry renamed = OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: entryFor().sourceId,
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Renamed series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: chapters,
    );
    await database.updateEpubBookMihonState(
      added.bookKey,
      sourceMetadata: renamed.encode(),
      chapterCount: chapters.length,
      chaptersJson: '[]',
    );

    final EpubBookRow ensured = await service.ensureBookDirectory(
      (await database.getEpubBook(added.bookKey))!,
    );

    expect(ensured.extractDir, originalDir,
        reason: '目录名不是身份，改名不重命名/重指向目录');
    expect(Directory(originalDir).existsSync(), isTrue);
  });

  test('ensureBookDirectory 复用磁盘 manifest 证明的旧文件夹并立即 re-link', () async {
    final EpubBookRow added = await service.add(
      entryVariant(
        sourceId: '1001',
        seriesKey: '/series/first',
        title: 'Fixture series',
      ),
    );
    // 用户之前下载过，文件夹可能已改过名。
    final Directory reused = Directory(
      p.join(root.path, 'downloads', 'Fixture', 'Legacy folder'),
    );
    await Directory(added.extractDir).create(recursive: true);
    await reused.parent.create(recursive: true);
    await Directory(added.extractDir).rename(reused.path);
    await writeSourceManifest(
      reused.path,
      sourceId: '1001',
      seriesKey: '/series/first',
      writePage: true,
    );
    // 旧行还指向 Download library 之外的旧布局。
    final Directory legacy = Directory(
      p.join(root.path, 'library', added.bookKey),
    );
    await legacy.create(recursive: true);
    await database.updateEpubBookContentPaths(
      added.bookKey,
      extractDir: legacy.path,
    );

    final EpubBookRow ensured = await service.ensureBookDirectory(
      (await database.getEpubBook(added.bookKey))!,
    );

    expect(
      ensured.extractDir,
      reused.path,
      reason: '旧行重指向时优先复用 manifest 证明的已有文件夹',
    );
    expect(
      await database.getMangaChapterDir(added.bookKey, '/chapter/1'),
      isNotNull,
      reason: '复用后立即 re-link，不能等用户手动重建索引',
    );
  });

  test('ensureBookDirectory 把旧行重指向 Download library，不搬旧目录（fresh start）',
      () async {
    final EpubBookRow added = await service.add(entryFor(chapters: chapters));
    // 造一条旧行：目录住在 <runtimeRoot>/library/<bookKey>。
    final Directory legacy = Directory(
      p.join(root.path, 'library', added.bookKey),
    );
    await legacy.parent.create(recursive: true);
    await Directory(added.extractDir).create(recursive: true);
    await Directory(added.extractDir).rename(legacy.path);
    File(p.join(legacy.path, 'note.txt')).writeAsStringSync('keep me');
    await database.updateEpubBookContentPaths(
      added.bookKey,
      extractDir: legacy.path,
    );

    final EpubBookRow ensured = await service.ensureBookDirectory(
      (await database.getEpubBook(added.bookKey))!,
    );

    expect(
      ensured.extractDir,
      p.join(root.path, 'downloads', 'Fixture', 'Fixture series'),
    );
    expect(ensured.uid, added.uid, reason: '身份不变，进度零迁移');
    expect(
      legacy.existsSync(),
      isTrue,
      reason: 'fresh-start：不自动迁移旧目录，旧文件留给用户自己处理',
    );
    expect(
      (await database.getEpubBook(added.bookKey))!.extractDir,
      ensured.extractDir,
      reason: '行必须真的改了 extractDir',
    );
  });

  group('resumeChapterIndex', () {
    test('一次没读过 → 回退到最旧那话', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          const <String, MangaChapterStateRow>{},
        ),
        1,
      );
    });

    test('最近读过且没读完 → 落回那一话', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/1': _state(chapterKey: '/chapter/1', updatedAt: 10),
          },
        ),
        1,
      );
    });

    test('最近那话已读完 → 前进到更新的一话（列表新→旧，所以下标 -1）', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/1':
                _state(chapterKey: '/chapter/1', updatedAt: 10, readAt: 11),
          },
        ),
        0,
      );
    });

    test('最新一话也读完了 → 停在原地，不越界', () {
      final OnlineMangaLibraryEntry entry = entryFor(chapters: chapters);
      expect(
        OnlineMangaLibraryService.resumeChapterIndex(
          entry,
          <String, MangaChapterStateRow>{
            '/chapter/2':
                _state(chapterKey: '/chapter/2', updatedAt: 20, readAt: 21),
          },
        ),
        0,
      );
    });
  });

  group('运行时归一化', () {
    test('Mihon：url 即身份，raw 能被 MihonChapter.fromJson 吃回来', () {
      const MihonChapter native = MihonChapter(
        url: '/chapter/9',
        name: 'Chapter 9',
        uploadedAt: 99,
        number: 9,
        scanlator: 'Fixture scans',
      );
      final OnlineMangaChapter normalized =
          MihonLibraryAdapter.chapterOf(native);
      expect(normalized.key, '/chapter/9');
      expect(normalized.scanlator, 'Fixture scans');
      expect(normalized.number, 9);
      expect(MihonChapter.fromJson(normalized.raw).url, '/chapter/9');
    });

    test('Mihon：详情增量不带 url 时，身份回退到已知 key（BUG-1767 同族）', () {
      const MihonManga delta = MihonManga(url: '', title: 'Delta only');
      final OnlineMangaSeries series = MihonLibraryAdapter.seriesOf(delta);
      // seriesOf 的 fallback 就是 manga.url 本身；这里验证的是「raw 里一定补得出
      // 一个 url」，否则回灌 MihonManga.fromJson 会造出无身份的对象。
      expect(series.raw.containsKey('url'), isTrue);
    });

    test('旧 Aidoku 条目：适配器一律回报本平台不可用，不发任何网络请求', () async {
      const LegacyAidokuLibraryAdapter adapter = LegacyAidokuLibraryAdapter();
      expect(adapter.kind, OnlineMangaRuntimeKind.aidoku);
      expect(adapter.isSupportedOnThisPlatform, isFalse);
      await expectLater(
        adapter.fetchChapterPage(
          const HttpMangaPageRef(
            index: 0,
            url: 'https://cdn.example/p.jpg',
            referer: 'https://cdn.example',
          ),
        ),
        throwsA(
          isA<OnlineMangaUnavailable>().having(
            (OnlineMangaUnavailable e) => e.reason,
            'reason',
            OnlineMangaUnavailableReason.platformUnsupported,
          ),
        ),
      );
    });
  });
}

MangaChapterStateRow _state({
  required String chapterKey,
  required int updatedAt,
  int? readAt,
  int lastPage = 3,
}) =>
    MangaChapterStateRow(
      bookUid: 'uid',
      chapterKey: chapterKey,
      lastPage: lastPage,
      lastFraction: -1,
      readAt: readAt,
      updatedAt: updatedAt,
    );

/// 只做「取封面」这一件事的适配器。
///
/// 服务层的契约（身份、落盘、去重、刷新重定位）与具体运行时无关，用真
/// MihonManager 反而要先把扩展登记进库才能走到 fetchCover。
class _FixtureAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  /// Source 显示名；同名 Source / 大小写冲突用例会改它。
  String sourceLabelText = 'Fixture';

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async =>
      sourceLabelText;

  @override
  Future<OnlineMangaRefreshResult> refresh(OnlineMangaLibraryEntry entry) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) =>
      throw UnimplementedError();

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw UnimplementedError();

  /// 封面被请求的次数；入库/浏览路径必须保持 0（封面属于 Cache）。
  int coverCalls = 0;

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async {
    coverCalls++;
    return coverBytes;
  }

  /// 默认是完整 1×1 PNG；用例可换成坏字节，验证即使源可返回坏封面也不会被抓取。
  List<int> coverBytes = kTransparentImage;
}

/// 有语言能力的假适配器：验证下载源目录名 `源名 (LANG)`。
///
/// 普通 [_FixtureAdapter] 故意**不**实现 [OnlineMangaSourceLanguageProvider]，
/// 用于证明没有语言能力的运行时（互联、旧 Aidoku）只写裸源名。
class _LanguageFixtureAdapter extends _FixtureAdapter
    implements OnlineMangaSourceLanguageProvider {
  /// 源语言原值；null = 源没有声明语言。
  String? sourceLanguageText;

  @override
  String? sourceLanguage(OnlineMangaLibraryEntry entry) => sourceLanguageText;
}
