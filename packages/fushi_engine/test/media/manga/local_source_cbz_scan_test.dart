import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 07：`local/{manga}/{chapter}.cbz` 目录扫描。
///
/// CBZ 与章节目录同级：包根 `pages.json` 优先，缺失/损坏/引用缺页时回退到
/// 包内图片自然序扫描；没有图片的包不算章节。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_cbz_scan_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

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

  List<int> pngBytes({int width = 80, int height = 120}) =>
      img.encodePng(img.Image(width: width, height: height));

  test('CBZ 文件是章节：名称去掉扩展名，页表来自包内图片自然序', () async {
    writeCbz('Manga/Ch 10.cbz', <String, List<int>>{
      '10.png': pngBytes(),
      '2.png': pngBytes(),
    });
    writeCbz('Manga/Ch 2.cbz', <String, List<int>>{'001.png': pngBytes()});

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);

    expect(mangas, hasLength(1));
    final LocalSourceManga manga = mangas.single;
    expect(manga.title, 'Manga');
    expect(manga.chapters.map((LocalSourceChapter c) => c.name), <String>[
      'Ch 2',
      'Ch 10',
    ]);
    expect(manga.chapters.map((LocalSourceChapter c) => c.key), <String>[
      'Ch 2.cbz',
      'Ch 10.cbz',
    ]);
    expect(
      manga.chapters.map((LocalSourceChapter c) => c.relativePath),
      <String>['Ch 2.cbz', 'Ch 10.cbz'],
    );

    final LocalSourceChapter ch10 = manga.chapters.last;
    expect(ch10.isArchive, isTrue);
    expect(ch10.archiveFile?.path, p.join(root.path, 'Manga', 'Ch 10.cbz'));
    expect(
      ch10.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['2.png', '10.png'],
    );
    expect(
      ch10.pages.every((LocalSourcePage page) => page.file == null),
      isTrue,
    );
    expect(manga.pageCount, 3);
  });

  test('包根 pages.json 决定页序与声明宽高；子目录里的 pages.json 不生效', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      'a.png': pngBytes(),
      'b.png': pngBytes(),
      'pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'b.png', 'width': 10, 'height': 20},
            <String, Object?>{'url': 'a.png'},
          ],
        }),
      ),
    });
    writeCbz('Manga/Ch 2.cbz', <String, List<int>>{
      'vol1/a.png': pngBytes(),
      'vol1/b.png': pngBytes(),
      // 包根没有 pages.json：子目录里的同名文件不参与解析。
      'vol1/pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'vol1/b.png'},
            <String, Object?>{'url': 'vol1/a.png'},
          ],
        }),
      ),
    });

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);
    final List<LocalSourceChapter> chapters = mangas.single.chapters;

    expect(
      chapters[0].pages.map((LocalSourcePage page) => page.relativePath),
      <String>['b.png', 'a.png'],
    );
    expect(chapters[0].pages[0].width, 10);
    expect(chapters[0].pages[0].height, 20);
    expect(chapters[0].pages[1].width, isNull);
    expect(
      chapters[1].pages.map((LocalSourcePage page) => page.relativePath),
      <String>['vol1/a.png', 'vol1/b.png'],
    );
  });

  test('缺失/损坏/引用缺页的 pages.json 回退到图片扫描', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      'a.png': pngBytes(),
      'b.png': pngBytes(),
      'pages.json': utf8.encode('{not json}'),
    });
    writeCbz('Manga/Ch 2.cbz', <String, List<int>>{
      'a.png': pngBytes(),
      'b.png': pngBytes(),
      'pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'missing.png'},
          ],
        }),
      ),
    });
    writeCbz('Manga/Ch 3.cbz', <String, List<int>>{
      'a.png': pngBytes(),
      'b.png': pngBytes(),
    });

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);

    for (final LocalSourceChapter chapter in mangas.single.chapters) {
      expect(
        chapter.pages.map((LocalSourcePage page) => page.relativePath),
        <String>['a.png', 'b.png'],
        reason: '${chapter.name} 应回退到图片自然序扫描',
      );
    }
  });

  test('文件夹章节与 CBZ 章节混合时按名称自然序', () async {
    final File page = File(p.join(root.path, 'Manga', 'Ch 2', '001.png'));
    page.parent.createSync(recursive: true);
    page.writeAsBytesSync(pngBytes());
    writeCbz('Manga/Ch 10.cbz', <String, List<int>>{'001.png': pngBytes()});

    final List<LocalSourceChapter> chapters = (await scanLocalSourceRoot(
      root,
    )).single.chapters;

    expect(chapters.map((LocalSourceChapter chapter) => chapter.name), <String>[
      'Ch 2',
      'Ch 10',
    ]);
    expect(chapters[0].isArchive, isFalse);
    expect(chapters[1].isArchive, isTrue);
  });

  test('没有图片的 CBZ 不算章节；manga 目录直接含图片时整目录算单章', () async {
    writeCbz('Empty Cbz/Ch 1.cbz', <String, List<int>>{
      'notes.txt': utf8.encode('not an image'),
    });
    writeCbz('Single/Vol 1.cbz', <String, List<int>>{'001.png': pngBytes()});
    final File rootPage = File(p.join(root.path, 'Single', '001.png'));
    rootPage.parent.createSync(recursive: true);
    rootPage.writeAsBytesSync(pngBytes());

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);

    expect(mangas.map((LocalSourceManga manga) => manga.title), <String>[
      'Single',
    ]);
    final LocalSourceChapter single = mangas.single.chapters.single;
    expect(single.relativePath, '');
    expect(single.isArchive, isFalse);
    expect(
      single.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['001.png'],
    );
  });
}
