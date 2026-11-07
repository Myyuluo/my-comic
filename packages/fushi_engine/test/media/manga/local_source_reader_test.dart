import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_reader.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 06：Local source 章节读取**原地**发生——登记之后新增/替换的页图在
/// 下一次打开时就能读到，不会复制进受管书库。
void main() {
  late Directory root;
  late Directory managedRoot;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_read_root_');
    managedRoot = await Directory.systemTemp.createTemp(
      'local_source_read_managed_',
    );
    EpubStorage.debugBaseDirectoryOverride = managedRoot.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    for (final Directory dir in <Directory>[root, managedRoot]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  File writePng(String relative, {int width = 80, int height = 120}) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(
      img.encodePng(img.Image(width: width, height: height)),
    );
    return file;
  }

  Future<String> importAndGetKey() async {
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.importFromRoot();
    return (await db.getAllEpubBooks()).single.bookKey;
  }

  test('按章节目录原地解析页表：顺序、真实文件、宽高来自图片本身', () async {
    writePng(p.join('Manga', 'Ch 1', '10.png'), width: 100, height: 150);
    writePng(p.join('Manga', 'Ch 1', '2.png'), width: 200, height: 300);
    writePng(p.join('Manga', 'Ch 2', '001.png'));
    final String bookKey = await importAndGetKey();

    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
        );

    expect(resolved, isNotNull);
    expect(resolved!.chapter.name, 'Ch 1');
    expect(resolved.chapter.relativePath, 'Ch 1');
    expect(resolved.chapterDirectory.path, p.join(root.path, 'Manga', 'Ch 1'));
    expect(
      resolved.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['2.png', '10.png'],
    );
    for (final LocalSourcePage page in resolved.pages) {
      expect(page.file.existsSync(), isTrue);
      expect(p.isWithin(root.path, page.file.path), isTrue);
    }
    expect(
      resolved.payload.images.map((MokuroImage image) => image.url),
      <String>['2.png', '10.png'],
    );
    expect(resolved.payload.images.first.size.width, 200);
    expect(resolved.payload.images.first.size.height, 300);
    expect(managedRoot.listSync(), isEmpty, reason: '读取不得复制文件');
  });

  test('pages.json 的页序与声明宽高在读取时生效', () async {
    writePng(p.join('Manga', 'Ch 1', 'a.png'));
    writePng(p.join('Manga', 'Ch 1', 'b.png'));
    File(p.join(root.path, 'Manga', 'Ch 1', 'pages.json')).writeAsStringSync(
      jsonEncode(<String, Object?>{
        'pages': <Object?>[
          <String, Object?>{'url': 'b.png', 'width': 333, 'height': 444},
          <String, Object?>{'url': 'a.png'},
        ],
      }),
    );
    final String bookKey = await importAndGetKey();

    final LocalSourceResolvedChapter resolved =
        (await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
        ))!;

    expect(resolved.payload.images.first.url, 'b.png');
    expect(resolved.payload.images.first.size.width, 333);
    expect(resolved.payload.images.first.size.height, 444);
    expect(resolved.payload.images.last.url, 'a.png');
  });

  test('登记后新增的页图无需重新导入即可读取（原地读取）', () async {
    writePng(p.join('Manga', 'Ch 1', '001.png'));
    final String bookKey = await importAndGetKey();

    writePng(p.join('Manga', 'Ch 1', '002.png'));
    final LocalSourceResolvedChapter resolved =
        (await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
        ))!;

    expect(
      resolved.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['001.png', '002.png'],
    );
  });

  test('单章作品（manga 目录直接含页图）可读取，cover 不算页', () async {
    writePng(p.join('Single', 'cover.jpg'));
    writePng(p.join('Single', '001.png'));
    writePng(p.join('Single', '002.png'));
    final String bookKey = await importAndGetKey();

    final LocalSourceResolvedChapter resolved =
        (await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
        ))!;

    expect(resolved.chapter.relativePath, '');
    expect(resolved.chapterDirectory.path, p.join(root.path, 'Single'));
    expect(
      resolved.payload.images.map((MokuroImage image) => image.url),
      <String>['001.png', '002.png'],
    );
  });

  test('章节下标越界 / 非 Local source 条目返回 null', () async {
    writePng(p.join('Manga', 'Ch 1', '001.png'));
    final String bookKey = await importAndGetKey();

    expect(
      await LocalSourceReader.resolveChapter(
        db: db,
        bookKey: bookKey,
        chapterIndex: 5,
      ),
      isNull,
    );
    expect(
      await LocalSourceReader.resolveChapter(
        db: db,
        bookKey: 'missing-book',
        chapterIndex: 0,
      ),
      isNull,
    );
  });
}
