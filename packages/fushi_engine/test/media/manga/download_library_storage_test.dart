import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Download library 的磁盘布局与 `pages.json`（storage-layout 票 04）。
///
/// 布局：`downloads/{source}/{manga}/{chapter}/001.jpg… + pages.json`。
/// 这里只测纯路径派生 + manifest 读写与完整性判据（真实临时目录）。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('download_library_storage_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  MokuroPayload payloadOf(List<String> urls) => MokuroPayload(
        images: <MokuroImage>[
          for (final String url in urls)
            MokuroImage(
              url: url,
              size: const MokuroSize(100, 150),
              blocks: const <MokuroBlock>[],
            ),
        ],
      );

  MangaPagesManifest manifestOf(MokuroPayload payload) => MangaPagesManifest(
        sourceRuntime: 'mihon',
        sourceId: '42',
        sourceName: 'Example Source',
        extensionPackage: 'org.example.source',
        mangaKey: '/series/fixture',
        mangaTitle: 'Fixture series',
        chapterKey: '/chapter/1',
        chapterName: 'Chapter 1',
        chapterNumber: 1,
        scanlator: 'Group',
        chapterUrl: 'https://example.invalid/chapter/1',
        payload: payload,
        downloadedAt: DateTime.utc(2026, 11, 7, 12, 0, 0),
      );

  test('pages.json round-trips stable identity and flat page paths', () async {
    final Directory chapterDir = downloadChapterDirectory(
      downloadMangaDirectory(
        downloadsRoot: root.path,
        sourceName: 'Example Source',
        mangaTitle: 'Fixture series',
      ).path,
      'Chapter 1',
    );
    await chapterDir.create(recursive: true);
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    await File(p.join(chapterDir.path, '002.jpg')).writeAsBytes(<int>[2]);

    final MokuroPayload payload = payloadOf(<String>['001.jpg', '002.jpg']);
    await writePagesManifestAtomically(chapterDir, manifestOf(payload));

    // 页图平铺、无 images/ 前缀。
    expect(File(p.join(chapterDir.path, '001.jpg')).existsSync(), isTrue);
    expect(Directory(p.join(chapterDir.path, 'images')).existsSync(), isFalse);

    final MangaPagesManifest? read = await readPagesManifest(chapterDir);
    expect(read, isNotNull);
    expect(read!.sourceRuntime, 'mihon');
    expect(read.sourceId, '42');
    expect(read.sourceName, 'Example Source');
    expect(read.extensionPackage, 'org.example.source');
    expect(read.mangaKey, '/series/fixture');
    expect(read.mangaTitle, 'Fixture series');
    expect(read.chapterKey, '/chapter/1');
    expect(read.chapterName, 'Chapter 1');
    expect(read.chapterNumber, 1);
    expect(read.scanlator, 'Group');
    expect(read.chapterUrl, 'https://example.invalid/chapter/1');
    expect(read.downloadedAt, DateTime.utc(2026, 11, 7, 12, 0, 0));
    expect(read.payload.images.map((MokuroImage image) => image.url), <String>[
      '001.jpg',
      '002.jpg',
    ]);

    final Map<String, Object?> json =
        jsonDecode(await downloadPagesManifestFile(chapterDir).readAsString())
            as Map<String, Object?>;
    expect(json['version'], 1);
    expect(json['downloadedAt'], '2026-11-07T12:00:00.000Z');
    expect((json['source']! as Map<String, Object?>)['runtime'], 'mihon');
    expect((json['pages']! as List<Object?>), hasLength(2));
  });

  test('基础净化：非法字符替换、结尾空格/点去掉、空串回落', () {
    expect(
      downloadMangaDirectory(
        downloadsRoot: root.path,
        sourceName: 'Bad:Source/Name',
        mangaTitle: 'Series? *Title*.  ',
      ).path,
      p.join(root.path, 'Bad_Source_Name', 'Series_ _Title_'),
    );
    expect(sanitizeDownloadLibrarySegment('   '), '_');
    expect(sanitizeDownloadLibrarySegment('...'), '_');
  });

  test('Windows 保留名加前缀，尾随空格/点清理后仍合法', () {
    expect(sanitizeDownloadLibrarySegment('CON'), '_CON');
    expect(sanitizeDownloadLibrarySegment('nul.txt'), '_nul.txt');
    expect(sanitizeDownloadLibrarySegment('COM1'), '_COM1');
    expect(sanitizeDownloadLibrarySegment('LPT9'), '_LPT9');
    expect(sanitizeDownloadLibrarySegment('CONSOLE'), 'CONSOLE');
    expect(sanitizeDownloadLibrarySegment('CON (1)'), 'CON (1)');
    expect(sanitizeDownloadLibrarySegment('Series. . '), 'Series');
    expect(sanitizeDownloadLibrarySegment('Series .'), 'Series');
    // 点号开头的目录会被扫描/重建忽略（与 .staging 同规则），用户内容不能躲进去。
    expect(sanitizeDownloadLibrarySegment('.hidden'), '_.hidden');
    expect(sanitizeDownloadLibrarySegment('.staging'), '_.staging');
  });

  test('超长段截断 + 短哈希：确定、不超上限、不同全名不碰撞', () {
    final String longA = 'A' * 300;
    final String longB = '${'A' * 299}B';
    final String a = sanitizeDownloadLibrarySegment(longA);
    final String b = sanitizeDownloadLibrarySegment(longB);

    expect(a.length, lessThanOrEqualTo(kDownloadLibraryMaxSegmentLength));
    expect(a, matches(RegExp(r'~[0-9a-f]{8}$')));
    expect(b, matches(RegExp(r'~[0-9a-f]{8}$')));
    expect(a, isNot(b), reason: '共享超长前缀也必须得到不同目录名');
    expect(
      sanitizeDownloadLibrarySegment(longA),
      a,
      reason: '同一输入必须每次得到同一名字',
    );
  });

  test('路径预算：深层 root + 超长 source/manga/chapter 仍不超过上限', () {
    final String deepRoot = p.join(root.path, 'a' * 40, 'b' * 40);
    final Directory mangaDir = downloadMangaDirectory(
      downloadsRoot: deepRoot,
      sourceName: 'S' * 300,
      mangaTitle: 'M' * 300,
    );
    expect(
      mangaDir.path.length,
      lessThanOrEqualTo(
        kDownloadLibraryMaxPathLength - kDownloadLibraryStagingPathReserve,
      ),
      reason: 'manga 目录要给 .staging/<jobId>/<page> 留出路径预算',
    );
    expect(p.basename(mangaDir.parent.path), startsWith('S'));
    expect(p.basename(mangaDir.path), startsWith('M'));

    final String chapterName = downloadChapterFolderName(
      mangaDirPath: mangaDir.path,
      raw: 'C' * 300,
    );
    final String chapterPath = downloadChapterDirectory(
      mangaDir.path,
      chapterName,
    ).path;
    expect(
      chapterPath.length,
      lessThanOrEqualTo(kDownloadLibraryMaxPathLength),
    );
    expect(p.basename(chapterPath), startsWith('C'));
    final String jobId = 'f' * 32; // MangaDownloadService 的 jobId 长度
    expect(
      p.join(
        mangaDir.path,
        kDownloadStagingDirName,
        jobId,
        '${downloadPageFileName(0, '.jpg')}.tmp',
      ).length,
      lessThanOrEqualTo(kDownloadLibraryMaxPathLength),
    );
  });

  test('同名候选使用确定后缀：base → base [扫译组] → base [扫译组] (2)', () async {
    final Set<String> taken = <String>{'chapter 1'};
    Future<bool> isTaken(String candidate) async =>
        taken.contains(candidate.toLowerCase());

    expect(
      await uniqueDownloadLibraryFolderName(
        base: 'Chapter 1',
        qualifier: 'Group B',
        isTaken: isTaken,
      ),
      'Chapter 1 [Group B]',
    );

    taken.add('chapter 1 [group b]');
    expect(
      await uniqueDownloadLibraryFolderName(
        base: 'Chapter 1',
        qualifier: 'Group B',
        isTaken: isTaken,
      ),
      'Chapter 1 [Group B] (2)',
    );

    taken.add('chapter 1 (2)');
    expect(
      await uniqueDownloadLibraryFolderName(
        base: 'Chapter 1',
        isTaken: isTaken,
      ),
      'Chapter 1 (3)',
      reason: '没有扫译组时直接从 (2) 起编号，并跳过已占用的大小写变体',
    );
  });

  test('staging 是 manga 目录下的点号目录', () {
    final String mangaDir = p.join(root.path, 'src', 'manga');
    expect(
      downloadStagingDirectory(mangaDir, 'job-1').path,
      p.join(mangaDir, '.staging', 'job-1'),
    );
    expect(kDownloadStagingDirName.startsWith('.'), isTrue);
  });

  test('完整性判据拒绝缺 manifest / 空页表 / 缺页 / 越界 url', () async {
    final Directory chapterDir = Directory(p.join(root.path, 'c'));
    await chapterDir.create(recursive: true);

    // ① 只有页图，没有 pages.json（staging 半成品）。
    await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
    expect(await isDownloadLibraryChapterComplete(chapterDir), isFalse);

    // ② pages.json 存在但页表为空。
    await writePagesManifestAtomically(
      chapterDir,
      manifestOf(payloadOf(const <String>[])),
    );
    expect(await isDownloadLibraryChapterComplete(chapterDir), isFalse);

    // ③ pages.json 说两页、磁盘只有一页。
    await writePagesManifestAtomically(
      chapterDir,
      manifestOf(payloadOf(<String>['001.jpg', '002.jpg'])),
    );
    expect(await isDownloadLibraryChapterComplete(chapterDir), isFalse);

    // ④ url 越界（即便文件真的在章目录外）。
    await File(p.join(root.path, 'outside.jpg')).writeAsBytes(<int>[1]);
    await writePagesManifestAtomically(
      chapterDir,
      manifestOf(payloadOf(<String>['../outside.jpg'])),
    );
    expect(await isDownloadLibraryChapterComplete(chapterDir), isFalse);

    // ⑤ 全部页都在 → 完整。
    await writePagesManifestAtomically(
      chapterDir,
      manifestOf(payloadOf(<String>['001.jpg'])),
    );
    expect(await isDownloadLibraryChapterComplete(chapterDir), isTrue);
    final MokuroPayload? payload = await readDownloadLibraryChapterPayload(
      chapterDir,
    );
    expect(payload?.images.single.url, '001.jpg');
  });

  test('坏 JSON 视同未下载，不抛', () async {
    final Directory chapterDir = Directory(p.join(root.path, 'broken'));
    await chapterDir.create(recursive: true);
    await downloadPagesManifestFile(chapterDir).writeAsString('{not json');
    expect(await readPagesManifest(chapterDir), isNull);
    expect(await isDownloadLibraryChapterComplete(chapterDir), isFalse);
  });

  // ── CBZ 容器（票 06） ────────────────────────────────────────────────

  /// 写一个 CBZ：包根平铺页图 + `pages.json`。[writePages] / [writeManifest]
  /// 控制是否写入对应条目（模拟半成品包）。
  Future<File> writeArchive({
    required String fileName,
    required MangaPagesManifest manifest,
    bool writePages = true,
    bool writeManifest = true,
    String rawManifest = '',
  }) async {
    final Archive archive = Archive();
    if (writePages) {
      for (final MokuroImage image in manifest.payload.images) {
        final List<int> bytes = utf8.encode('page:${image.url}');
        archive.addFile(ArchiveFile(image.url, bytes.length, bytes));
      }
    }
    if (writeManifest) {
      final List<int> bytes = utf8.encode(
        rawManifest.isEmpty ? jsonEncode(manifest.toJson()) : rawManifest,
      );
      archive.addFile(
        ArchiveFile(kDownloadPagesFileName, bytes.length, bytes),
      );
    }
    final File file = File(p.join(root.path, fileName));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  test('压缩包路径与扩展名判据', () {
    expect(kDownloadArchiveExtension, '.cbz');
    expect(
      downloadChapterArchiveFile(root.path, 'Chapter 1.cbz').path,
      p.join(root.path, 'Chapter 1.cbz'),
    );
    expect(isDownloadChapterArchiveName('Chapter 1.cbz'), isTrue);
    expect(isDownloadChapterArchiveName('Chapter 1.CBZ'), isTrue);
    expect(isDownloadChapterArchiveName('Chapter 1'), isFalse);
    expect(
      downloadChapterArchiveName('Chapter 1'),
      'Chapter 1.cbz',
      reason: '容器名统一带 .cbz，数据库只存单段名字',
    );
  });

  test('压缩包包根 pages.json 可读，完整性判据接受齐页、拒绝缺页/坏包/空页表', () async {
    final MokuroPayload payload = payloadOf(<String>['001.jpg', '002.jpg']);
    final MangaPagesManifest manifest = manifestOf(payload);

    final File complete = await writeArchive(
      fileName: 'Chapter 1.cbz',
      manifest: manifest,
    );
    final MangaPagesManifest? read = await readDownloadLibraryArchiveManifest(
      complete,
    );
    expect(read, isNotNull);
    expect(read!.chapterKey, '/chapter/1');
    expect(read.sourceId, '42');
    expect(await isDownloadLibraryArchiveComplete(complete), isTrue);
    final MokuroPayload? archivePayload = await readDownloadLibraryArchivePayload(
      complete,
    );
    expect(
      archivePayload?.images.map((MokuroImage image) => image.url),
      <String>['001.jpg', '002.jpg'],
    );

    // 半成品：pages.json 存在，页图不在包里。
    final File missingPage = await writeArchive(
      fileName: 'Chapter 2.cbz',
      manifest: manifest,
      writePages: false,
    );
    expect(await readDownloadLibraryArchiveManifest(missingPage), isNotNull);
    expect(await isDownloadLibraryArchiveComplete(missingPage), isFalse);

    // 没有 pages.json 的包不算已下载（与文件夹章节同一口径）。
    final File noManifest = await writeArchive(
      fileName: 'Chapter 3.cbz',
      manifest: manifest,
      writeManifest: false,
    );
    expect(await readDownloadLibraryArchiveManifest(noManifest), isNull);
    expect(await isDownloadLibraryArchiveComplete(noManifest), isFalse);

    // 坏 JSON / 空页表。
    final File broken = await writeArchive(
      fileName: 'Chapter 4.cbz',
      manifest: manifest,
      rawManifest: '{not json',
    );
    expect(await readDownloadLibraryArchiveManifest(broken), isNull);
    final File emptyPages = await writeArchive(
      fileName: 'Chapter 5.cbz',
      manifest: manifestOf(payloadOf(const <String>[])),
    );
    expect(await isDownloadLibraryArchiveComplete(emptyPages), isFalse);

    // url 穿越 / 不存在。
    final File traversal = await writeArchive(
      fileName: 'Chapter 6.cbz',
      manifest: manifestOf(payloadOf(<String>['../outside.jpg'])),
    );
    expect(await isDownloadLibraryArchiveComplete(traversal), isFalse);

    // 根本不是 ZIP。
    final File notZip = File(p.join(root.path, 'Chapter 7.cbz'));
    await notZip.writeAsString('not a zip');
    expect(await readDownloadLibraryArchiveManifest(notZip), isNull);
    expect(await isDownloadLibraryArchiveComplete(notZip), isFalse);
    expect(
      await readDownloadLibraryArchiveManifest(
        File(p.join(root.path, 'missing.cbz')),
      ),
      isNull,
    );
  });
}
