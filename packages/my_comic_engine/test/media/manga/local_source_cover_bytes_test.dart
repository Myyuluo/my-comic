import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_cover.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 02：只读的第一页封面字节 API。
///
/// 与 [LocalSourceCoverService.generateMissingCover] 不同，这条路径只返回
/// 缩放后的 JPEG 字节与容器 sentinel，绝不写 Content root / Local source。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_cover_bytes_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  List<int> pngBytes({
    required img.Color color,
    int width = 80,
    int height = 120,
  }) {
    final img.Image image = img.Image(width: width, height: height)
      ..clear(color);
    return img.encodePng(image);
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

  test('CBZ：取归档内第一张图片，跳过 ComicInfo.xml，输出宽 600 JPEG 且不写盘', () async {
    final File cbz = writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      'ComicInfo.xml': utf8.encode('<ComicInfo/>'),
      '10.png': pngBytes(
        color: img.ColorRgb8(0, 0, 255),
        width: 900,
        height: 1200,
      ),
      '2.png': pngBytes(
        color: img.ColorRgb8(255, 0, 0),
        width: 900,
        height: 1200,
      ),
    });
    final int sizeBefore = cbz.lengthSync();
    final int modifiedBefore = cbz.lastModifiedSync().millisecondsSinceEpoch;
    final Set<String> filesBefore = <String>{
      for (final FileSystemEntity entity in root.listSync(recursive: true))
        if (entity is File) p.relative(entity.path, from: root.path),
    };

    final LocalSourceGeneratedCover? cover =
        await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.archive(cbz.path),
        );

    expect(cover, isNotNull);
    expect(
      cover!.sentinel,
      startsWith(kLocalSourceGeneratedCoverSentinelPrefix),
      reason: 'sidecar sentinel 必须能与其他来源的 URL 区分',
    );
    expect(cover.sentinel, contains(p.canonicalize(cbz.path)));
    expect(cover.sentinel, contains('$sizeBefore'));
    expect(cover.sentinel, contains('$modifiedBefore'));
    final img.Image decoded = img.decodeJpg(cover.bytes)!;
    expect(decoded.width, 600);
    expect(decoded.height, 800);
    final img.Pixel pixel = decoded.getPixel(10, 10);
    expect(pixel.r, greaterThan(200), reason: '自然序 2.png（红）在 10.png（蓝）前');
    expect(pixel.g, lessThan(60));
    expect(pixel.b, lessThan(60));

    final Set<String> filesAfter = <String>{
      for (final FileSystemEntity entity in root.listSync(recursive: true))
        if (entity is File) p.relative(entity.path, from: root.path),
    };
    expect(filesAfter, filesBefore, reason: 'bytes API 不得写任何文件（包括 cover.jpg）');
    expect(cbz.lengthSync(), sizeBefore);
  });

  test('文件夹章节：自然排序第一张图片，跳过 ComicInfo.xml 等非图片', () async {
    final Directory chapter = Directory(p.join(root.path, 'Manga', 'Ch 1'))
      ..createSync(recursive: true);
    File(
      p.join(chapter.path, 'ComicInfo.xml'),
    ).writeAsBytesSync(utf8.encode('<ComicInfo/>'));
    File(p.join(chapter.path, '10.png')).writeAsBytesSync(
      pngBytes(color: img.ColorRgb8(0, 0, 255), width: 900, height: 1200),
    );
    File(p.join(chapter.path, '2.png')).writeAsBytesSync(
      pngBytes(color: img.ColorRgb8(255, 0, 0), width: 900, height: 1200),
    );

    final LocalSourceGeneratedCover? cover =
        await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.folder(chapter.path),
        );

    expect(cover, isNotNull);
    final img.Image decoded = img.decodeJpg(cover!.bytes)!;
    expect(decoded.width, 600);
    final img.Pixel pixel = decoded.getPixel(10, 10);
    expect(pixel.r, greaterThan(200), reason: '自然序 2.png（红）在 10.png（蓝）前');
    expect(pixel.g, lessThan(60));
    expect(pixel.b, lessThan(60));
    expect(
      File(p.join(chapter.path, 'cover.jpg')).existsSync(),
      isFalse,
      reason: 'bytes API 不得写 Content root / Local source cover.jpg',
    );
  });

  test('第一页损坏时返回 null，不偷偷改用下一页', () async {
    final Directory chapter = Directory(p.join(root.path, 'Manga', 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(chapter.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    File(
      p.join(chapter.path, '002.png'),
    ).writeAsBytesSync(pngBytes(color: img.ColorRgb8(255, 0, 0)));

    expect(
      await generateLocalSourceFirstPageCover(
        LocalSourceCoverContainer.folder(chapter.path),
      ),
      isNull,
      reason: '第一页不可解码时保留占位，封面不能随坏页漂移到第二页',
    );
  });

  test('容器路径不存在或不是合法 CBZ 时返回 null，不抛异常', () async {
    expect(
      await generateLocalSourceFirstPageCover(
        LocalSourceCoverContainer.folder(p.join(root.path, 'missing')),
      ),
      isNull,
    );
    final File broken = File(p.join(root.path, 'broken.cbz'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    expect(
      await generateLocalSourceFirstPageCover(
        LocalSourceCoverContainer.archive(broken.path),
      ),
      isNull,
    );
  });

  test('容器替换或第一页更新后 sentinel 变化，触发重新生成', () async {
    final File cbz = writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(255, 0, 0)),
    });
    final LocalSourceGeneratedCover first =
        (await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.archive(cbz.path),
        ))!;
    // 让 mtime 可区分；Windows 文件时间精度足够，但显式推进一秒最稳。
    await Future<void>.delayed(const Duration(seconds: 1));
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(color: img.ColorRgb8(0, 0, 255)),
    });

    final LocalSourceGeneratedCover second =
        (await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.archive(cbz.path),
        ))!;

    expect(second.sentinel, isNot(first.sentinel));
    final img.Pixel pixel = img.decodeJpg(second.bytes)!.getPixel(10, 10);
    expect(pixel.b, greaterThan(200), reason: '容器更新后必须生成新的第一页封面');

    final Directory chapter = Directory(p.join(root.path, 'Folder', 'Ch 1'))
      ..createSync(recursive: true);
    final File page = File(p.join(chapter.path, '001.png'))
      ..writeAsBytesSync(pngBytes(color: img.ColorRgb8(255, 0, 0)));
    final LocalSourceGeneratedCover folderFirst =
        (await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.folder(chapter.path),
        ))!;
    await Future<void>.delayed(const Duration(seconds: 1));
    page.writeAsBytesSync(pngBytes(color: img.ColorRgb8(0, 0, 255)));
    final LocalSourceGeneratedCover folderSecond =
        (await generateLocalSourceFirstPageCover(
          LocalSourceCoverContainer.folder(chapter.path),
        ))!;
    expect(folderSecond.sentinel, isNot(folderFirst.sentinel));
    expect(
      img.decodeJpg(folderSecond.bytes)!.getPixel(10, 10).b,
      greaterThan(200),
    );
  });

  test('文件夹容器被替换但第一页 size/mtime 不变时 sentinel 仍变化', () async {
    final Directory chapter = Directory(p.join(root.path, 'Replace', 'Ch 1'))
      ..createSync(recursive: true);
    final File firstPage = File(p.join(chapter.path, '001.png'))
      ..writeAsBytesSync(pngBytes(color: img.ColorRgb8(255, 0, 0)));
    File(
      p.join(chapter.path, '002.png'),
    ).writeAsBytesSync(pngBytes(color: img.ColorRgb8(0, 0, 255)));
    final FileStat original = firstPage.statSync();
    final String firstSentinel = (await localSourceFirstPageCoverSentinel(
      LocalSourceCoverContainer.folder(chapter.path),
    ))!;

    await Future<void>.delayed(const Duration(seconds: 1));
    // 整个替换容器：删目录后重建，然后**把第一页还原成相同的 size/mtime**。
    // 只看第一页 stat 的旧 sentinel 会认为「没变化」；目录 fingerprint 必须能
    // 感知这次替换。
    chapter.deleteSync(recursive: true);
    chapter.createSync(recursive: true);
    firstPage.writeAsBytesSync(pngBytes(color: img.ColorRgb8(255, 0, 0)));
    firstPage.setLastModifiedSync(original.modified);
    File(
      p.join(chapter.path, '003.png'),
    ).writeAsBytesSync(pngBytes(color: img.ColorRgb8(0, 255, 0)));
    final FileStat restored = firstPage.statSync();
    expect(restored.size, original.size);
    expect(
      restored.modified.millisecondsSinceEpoch,
      original.modified.millisecondsSinceEpoch,
      reason: '夹具必须保持第一页 size/mtime 不变，才能复现旧 sentinel 的盲区',
    );

    final String secondSentinel = (await localSourceFirstPageCoverSentinel(
      LocalSourceCoverContainer.folder(chapter.path),
    ))!;

    expect(
      secondSentinel,
      isNot(firstSentinel),
      reason: '容器替换（目录 mtime / 文件列表变化）必须让 sentinel 变化并重新生成',
    );
  });
}
