import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 06：`local/{manga}/{chapter}/` 目录扫描。
///
/// 扫描是「导入本地漫画」的唯一入口：第一层目录是作品，含页图的直接子目录是
/// 章节，manga 目录直接有页图时整本算单章；`cover.jpg` 只作封面不算页。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_scan_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File writeFile(
    String relative, {
    List<int> bytes = const <int>[1, 2, 3],
    String? text,
  }) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    if (text != null) {
      file.writeAsStringSync(text);
    } else {
      file.writeAsBytesSync(bytes);
    }
    return file;
  }

  test('第一层目录是作品；含页图的直接子目录是章节（自然序）', () async {
    writeFile(p.join('Alpha', 'Chapter 10', '2.jpg'));
    writeFile(p.join('Alpha', 'Chapter 10', '10.jpg'));
    writeFile(p.join('Alpha', 'Chapter 2', '1.png'));
    writeFile(p.join('Alpha', 'Chapter 1', 'notes.txt'));
    writeFile(p.join('Alpha', 'cover.jpg'));
    writeFile(p.join('Beta', '01.jpg'));
    writeFile(p.join('Beta', '02.jpg'));
    writeFile('.hidden/Chapter/1.jpg');
    writeFile('loose.jpg');

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);

    expect(mangas.map((LocalSourceManga m) => m.title), <String>[
      'Alpha',
      'Beta',
    ]);

    final LocalSourceManga alpha = mangas.first;
    expect(alpha.relativePath, 'Alpha');
    expect(alpha.coverRelativePath, 'cover.jpg');
    expect(alpha.chapters.map((LocalSourceChapter c) => c.name), <String>[
      'Chapter 2',
      'Chapter 10',
    ]);
    expect(
      alpha.chapters.map((LocalSourceChapter c) => c.relativePath),
      <String>['Chapter 2', 'Chapter 10'],
    );
    expect(
      alpha.chapters.first.pages.map(
        (LocalSourcePage page) => page.relativePath,
      ),
      <String>['1.png'],
    );
    expect(alpha.pageCount, 3);

    final LocalSourceManga beta = mangas.last;
    expect(beta.coverRelativePath, isNull);
    expect(beta.chapters, hasLength(1));
    final LocalSourceChapter single = beta.chapters.single;
    expect(single.relativePath, '');
    expect(single.key, isNotEmpty);
    expect(
      single.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['01.jpg', '02.jpg'],
    );
  });

  test('章节内 pages.json 的页序优先；缺页/坏 JSON 回退到图片扫描', () async {
    writeFile(p.join('Manga', 'Ch 1', 'a.jpg'));
    writeFile(p.join('Manga', 'Ch 1', 'b.jpg'));
    writeFile(
      p.join('Manga', 'Ch 1', 'pages.json'),
      text: jsonEncode(<String, Object?>{
        'pages': <Object?>[
          <String, Object?>{'url': 'b.jpg', 'width': 10, 'height': 20},
          <String, Object?>{'url': 'a.jpg', 'width': 30, 'height': 40},
        ],
      }),
    );
    writeFile(p.join('Manga', 'Ch 2', 'a.jpg'));
    writeFile(p.join('Manga', 'Ch 2', 'b.jpg'));
    writeFile(p.join('Manga', 'Ch 2', 'pages.json'), text: '{not json}');
    writeFile(p.join('Manga', 'Ch 3', 'a.jpg'));
    writeFile(p.join('Manga', 'Ch 3', 'b.jpg'));
    writeFile(
      p.join('Manga', 'Ch 3', 'pages.json'),
      text: jsonEncode(<String, Object?>{
        'pages': <Object?>[
          <String, Object?>{'url': 'missing.jpg'},
        ],
      }),
    );

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);
    final List<LocalSourceChapter> chapters = mangas.single.chapters;

    expect(
      chapters[0].pages.map((LocalSourcePage page) => page.relativePath),
      <String>['b.jpg', 'a.jpg'],
    );
    expect(chapters[0].pages[0].width, 10);
    expect(chapters[0].pages[0].height, 20);
    expect(
      chapters[1].pages.map((LocalSourcePage page) => page.relativePath),
      <String>['a.jpg', 'b.jpg'],
    );
    expect(
      chapters[2].pages.map((LocalSourcePage page) => page.relativePath),
      <String>['a.jpg', 'b.jpg'],
    );
  });

  test('没有页图的第一层目录不算作品；cover 文件不算单章页图', () async {
    writeFile(p.join('Empty', 'cover.jpg'));
    writeFile(p.join('OnlyChapters', 'Ch 1', '001.jpg'));

    final List<LocalSourceManga> mangas = await scanLocalSourceRoot(root);

    expect(mangas.map((LocalSourceManga m) => m.title), <String>[
      'OnlyChapters',
    ]);
    expect(mangas.single.chapters, hasLength(1));
  });
}
