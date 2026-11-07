import 'dart:convert';
import 'dart:io';

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
    // 票 05 的保留名/超长/冲突不在本票处理；这里只钉基础行为存在。
    expect(sanitizeDownloadLibrarySegment('CON'), 'CON');
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
}
