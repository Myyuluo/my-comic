import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 04：本地图源封面生成。
///
/// 扫描到的作品没有 `cover.jpg/jpeg/png` 时，从第一页生成宽 600 的
/// `cover.jpg`（JPEG 质量 85）：文件夹作品取自然顺序第一部章节的第一页，
/// CBZ 作品取第一个包按 `pages.json`（无 manifest 时按图片名自然序）排出的
/// 第一页；已有封面绝不覆盖，坏页跳过且不写坏图。
void main() {
  late Directory root;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_cover_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  File writePage(
    String relative, {
    required img.Color color,
    int width = 80,
    int height = 120,
  }) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    final img.Image image = img.Image(width: width, height: height)
      ..clear(color);
    file.writeAsBytesSync(img.encodePng(image));
    return file;
  }

  File writeCbz(String relative, Map<String, List<int>> entries) {
    final Archive archive = Archive();
    entries.forEach((String name, List<int> bytes) {
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    });
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return file;
  }

  List<int> pngBytes({
    required img.Color color,
    int width = 80,
    int height = 120,
  }) {
    final img.Image image = img.Image(width: width, height: height)
      ..clear(color);
    return img.encodePng(image);
  }

  Future<LocalSourceManga> scanSingle() async =>
      (await scanLocalSourceRoot(root)).single;

  void expectReddish(img.Pixel pixel, {String? reason}) {
    expect(pixel.r, greaterThan(200), reason: reason);
    expect(pixel.g, lessThan(60), reason: reason);
    expect(pixel.b, lessThan(60), reason: reason);
  }

  test('文件夹作品：自然顺序第一部章节的第一页生成 cover.jpg，宽 600 不放大到超过原宽', () async {
    writePage(
      p.join('Manga', 'Chapter 10', '001.png'),
      color: img.ColorRgb8(0, 0, 255),
      width: 900,
      height: 1200,
    );
    writePage(
      p.join('Manga', 'Chapter 2', '001.png'),
      color: img.ColorRgb8(255, 0, 0),
      width: 900,
      height: 1200,
    );

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    expect(result.coverRelativePath, 'cover.jpg');
    final File cover = File(p.join(root.path, 'Manga', 'cover.jpg'));
    expect(cover.existsSync(), isTrue);
    final img.Image decoded = img.decodeJpg(cover.readAsBytesSync())!;
    expect(decoded.width, 600);
    expect(decoded.height, 800, reason: '按原始宽高比缩放到宽 600');
    expectReddish(decoded.getPixel(10, 10));
  });

  test('CBZ 作品：取第一个包内 pages.json 排出的第一页', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      'a.png': pngBytes(color: img.ColorRgb8(0, 0, 255)),
      'b.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
      'pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'b.png'},
            <String, Object?>{'url': 'a.png'},
          ],
        }),
      ),
    });

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    final img.Image decoded = img.decodeJpg(
      File(p.join(root.path, 'Manga', 'cover.jpg')).readAsBytesSync(),
    )!;
    expectReddish(
      decoded.getPixel(10, 10),
      reason: 'pages.json 把 b.png（红）排在 a.png（蓝）前面',
    );
  });

  test('CBZ 缺 pages.json 时按图片名自然序取第一页', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '10.png': pngBytes(color: img.ColorRgb8(0, 0, 255)),
      '2.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    final img.Image decoded = img.decodeJpg(
      File(p.join(root.path, 'Manga', 'cover.jpg')).readAsBytesSync(),
    )!;
    expectReddish(decoded.getPixel(10, 10), reason: '自然序 2.png（红）在 10.png（蓝）前');
  });

  test('已有 cover.jpg/jpeg/png 时绝不覆盖、不再生成', () async {
    final Map<String, String> existingCoverByWork = <String, String>{
      'A jpg': 'cover.jpg',
      'B jpeg': 'cover.jpeg',
      'C png': 'cover.png',
      'D upper': 'Cover.PNG',
    };
    existingCoverByWork.forEach((String work, String coverName) {
      writePage(
        p.join(work, 'Ch 1', '001.png'),
        color: img.ColorRgb8(255, 0, 0),
      );
      File(p.join(root.path, work, coverName))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[7, 7, 7]);
    });

    final LocalSourceCoverService service = LocalSourceCoverService(db: db);
    for (final LocalSourceManga manga in await scanLocalSourceRoot(root)) {
      final String coverName = existingCoverByWork[manga.title]!;
      final LocalSourceCoverResult result = await service.generateMissingCover(
        manga,
      );

      expect(result.outcome, LocalSourceCoverOutcome.existing);
      expect(result.coverRelativePath, coverName);
      expect(
        File(p.join(manga.directoryPath, coverName)).readAsBytesSync(),
        <int>[7, 7, 7],
        reason: '${manga.title} 的既有封面不得被覆盖',
      );
      if (coverName.toLowerCase() != 'cover.jpg') {
        expect(
          File(p.join(manga.directoryPath, 'cover.jpg')).existsSync(),
          isFalse,
          reason: '已有其它封面时不得再写 cover.jpg',
        );
      }
    }
  });

  test('第一页损坏时跳过：不写坏图、留占位；修好后下次重试可生成', () async {
    final File brokenPage = File(p.join(root.path, 'Manga', 'Ch 1', '001.jpg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final LocalSourceCoverService service = LocalSourceCoverService(db: db);
    final LocalSourceManga manga = await scanSingle();

    final LocalSourceCoverResult broken = await service.generateMissingCover(
      manga,
    );
    expect(broken.outcome, LocalSourceCoverOutcome.unavailable);
    expect(broken.coverRelativePath, isNull);
    expect(
      File(p.join(root.path, 'Manga', 'cover.jpg')).existsSync(),
      isFalse,
      reason: '坏页不得写出坏封面',
    );

    // 用户修复图片后再次进入 / 重试：同一作品可以补齐。
    brokenPage.writeAsBytesSync(pngBytes(color: img.ColorRgb8(255, 0, 0)));
    final LocalSourceCoverResult retried = await service.generateMissingCover(
      await scanSingle(),
    );
    expect(retried.outcome, LocalSourceCoverOutcome.generated);
    expect(File(p.join(root.path, 'Manga', 'cover.jpg')).existsSync(), isTrue);
  });

  test('CBZ 第一页条目损坏时跳过，不写封面', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': <int>[1, 2, 3],
      '002.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.unavailable);
    expect(File(p.join(root.path, 'Manga', 'cover.jpg')).existsSync(), isFalse);
  });

  test('已登记 CBZ 作品的 coverPath 为空：生成后同步为 cover.jpg', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    final LocalSourceManga manga = await scanSingle();
    await LocalSourceLibrary(db: db, root: root).registerScannedManga(manga);
    final EpubBookRow before = (await db.getAllEpubBooks()).single;
    expect(before.coverPath, isNull);

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(manga);

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    expect(result.registeredCoverPathUpdated, isTrue);
    final EpubBookRow after = (await db.getAllEpubBooks()).single;
    expect(after.coverPath, 'cover.jpg');
    expect(after.extractDir, manga.directoryPath, reason: '登记行仍原地指向');
  });

  test('已登记文件夹作品的 coverPath 指向旧第一页：生成后同步为 cover.jpg', () async {
    writePage(
      p.join('Manga', 'Ch 1', '001.png'),
      color: img.ColorRgb8(255, 0, 0),
    );
    final LocalSourceManga manga = await scanSingle();
    await LocalSourceLibrary(db: db, root: root).registerScannedManga(manga);
    expect((await db.getAllEpubBooks()).single.coverPath, 'Ch 1/001.png');

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(manga);

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    expect(result.registeredCoverPathUpdated, isTrue);
    expect((await db.getAllEpubBooks()).single.coverPath, 'cover.jpg');
  });

  test('未登记作品生成封面不会写 Library 行', () async {
    writePage(
      p.join('Manga', 'Ch 1', '001.png'),
      color: img.ColorRgb8(255, 0, 0),
    );
    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    expect(result.registeredCoverPathUpdated, isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
  });

  test('第一页宽小于 600 时不放大', () async {
    writePage(
      p.join('Manga', 'Ch 1', '001.png'),
      color: img.ColorRgb8(255, 0, 0),
      width: 300,
      height: 400,
    );

    await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    final img.Image decoded = img.decodeJpg(
      File(p.join(root.path, 'Manga', 'cover.jpg')).readAsBytesSync(),
    )!;
    expect(decoded.width, 300);
    expect(decoded.height, 400);
  });

  test('作品目录直接含页图（单章）时取第一页生成', () async {
    writePage(p.join('Manga', '001.png'), color: img.ColorRgb8(255, 0, 0));
    writePage(p.join('Manga', '002.png'), color: img.ColorRgb8(0, 0, 255));

    final LocalSourceCoverResult result = await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    expect(result.outcome, LocalSourceCoverOutcome.generated);
    final img.Image decoded = img.decodeJpg(
      File(p.join(root.path, 'Manga', 'cover.jpg')).readAsBytesSync(),
    )!;
    expectReddish(decoded.getPixel(10, 10));
  });

  test('文件夹与 CBZ 混合时按整体自然序取第一部的第一页', () async {
    writePage(
      p.join('Manga', 'Ch 10', '001.png'),
      color: img.ColorRgb8(0, 0, 255),
    );
    writeCbz('Manga/Ch 2.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });

    await LocalSourceCoverService(
      db: db,
    ).generateMissingCover(await scanSingle());

    final img.Image decoded = img.decodeJpg(
      File(p.join(root.path, 'Manga', 'cover.jpg')).readAsBytesSync(),
    )!;
    expectReddish(
      decoded.getPixel(10, 10),
      reason: '自然序 Ch 2.cbz（红）在 Ch 10（蓝）前',
    );
  });

  test('只新增可见 cover.jpg：不搬页文件、不解压 CBZ、不写隐藏元数据', () async {
    writePage(
      p.join('Manga', 'Ch 1', '001.png'),
      color: img.ColorRgb8(255, 0, 0),
    );
    final File cbz = writeCbz('Cbz Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(0, 0, 255)),
    });
    final List<int> cbzBefore = cbz.readAsBytesSync();

    Map<String, List<int>> snapshot() => <String, List<int>>{
      for (final FileSystemEntity entity in root.listSync(recursive: true))
        if (entity is File)
          p.relative(entity.path, from: root.path): entity.readAsBytesSync(),
    };
    final Map<String, List<int>> before = snapshot();

    final LocalSourceCoverService service = LocalSourceCoverService(db: db);
    for (final LocalSourceManga manga in await scanLocalSourceRoot(root)) {
      await service.generateMissingCover(manga);
    }

    final Map<String, List<int>> after = snapshot();
    expect(after.keys.toSet().difference(before.keys.toSet()), <String>{
      p.join('Manga', 'cover.jpg'),
      p.join('Cbz Manga', 'cover.jpg'),
    });
    expect(before.keys.toSet().difference(after.keys.toSet()), isEmpty);
    for (final MapEntry<String, List<int>> entry in before.entries) {
      expect(after[entry.key], entry.value, reason: '${entry.key} 被改写');
    }
    expect(cbz.readAsBytesSync(), cbzBefore, reason: 'CBZ 原包不得改动');
  });
}
