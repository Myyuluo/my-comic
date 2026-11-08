import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
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

  Future<String> importAndGetKey() async {
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    final LocalSourceManga manga = (await scanLocalSourceRoot(root)).single;
    await library.registerScannedManga(manga);
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
      expect(page.file, isNotNull, reason: '文件夹章节的页有独立文件');
      expect(page.file!.existsSync(), isTrue);
      expect(p.isWithin(root.path, page.file!.path), isTrue);
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

  test('CBZ 章节原地解析：页表来自包内条目，宽高来自真实图片', () async {
    final File cbz = writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '10.png': pngBytes(width: 100, height: 150),
      '2.png': pngBytes(width: 200, height: 300),
    });
    final String bookKey = await importAndGetKey();

    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
        );

    expect(resolved, isNotNull);
    expect(resolved!.isArchive, isTrue);
    expect(resolved.archiveFile?.path, p.join(root.path, 'Manga', 'Ch 1.cbz'));
    expect(resolved.chapter.name, 'Ch 1');
    expect(resolved.chapter.relativePath, 'Ch 1.cbz');
    expect(
      resolved.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['2.png', '10.png'],
    );
    expect(
      resolved.pages.every((LocalSourcePage page) => page.file == null),
      isTrue,
    );
    expect(
      resolved.payload.images.map((MokuroImage image) => image.url),
      <String>['2.png', '10.png'],
    );
    expect(resolved.payload.images.first.size.width, 200);
    expect(resolved.payload.images.first.size.height, 300);
    expect(cbz.existsSync(), isTrue, reason: '读取不得删改原包');
    expect(managedRoot.listSync(), isEmpty, reason: '读取不得复制文件');
  });

  test('CBZ 包根 pages.json 的页序与声明宽高在阅读时生效', () async {
    writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      'a.png': pngBytes(),
      'b.png': pngBytes(),
      'pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'b.png', 'width': 333, 'height': 444},
            <String, Object?>{'url': 'a.png'},
          ],
        }),
      ),
    });
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

  test('CBZ 阅读内容：包根 pages.json 的页序与声明宽高优先', () async {
    final File cbz = writeCbz('Ch 1.cbz', <String, List<int>>{
      'a.png': pngBytes(width: 80, height: 120),
      'b.png': pngBytes(width: 90, height: 130),
      'pages.json': utf8.encode(
        jsonEncode(<String, Object?>{
          'pages': <Object?>[
            <String, Object?>{'url': 'b.png', 'width': 333, 'height': 444},
            <String, Object?>{'url': 'a.png', 'width': 55, 'height': 66},
          ],
        }),
      ),
    });

    final LocalSourceArchiveChapterContent? content =
        await LocalSourceReader.readArchiveContent(cbz.path);

    expect(content, isNotNull);
    expect(
      content!.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['b.png', 'a.png'],
    );
    expect(
      content.payload.images.map((MokuroImage image) => image.url),
      <String>['b.png', 'a.png'],
    );
    expect(content.payload.images.first.size.width, 333);
    expect(content.payload.images.first.size.height, 444);
    expect(content.payload.images.last.size.width, 55);
    expect(cbz.existsSync(), isTrue, reason: '读取不得删改原包');
    expect(managedRoot.listSync(), isEmpty, reason: '读取不得复制文件');
  });

  test('CBZ 阅读内容：pages.json 缺失或损坏时按图片条目自然序回退', () async {
    final File cbz = writeCbz('Ch 1.cbz', <String, List<int>>{
      '10.png': pngBytes(width: 100, height: 150),
      '2.png': pngBytes(width: 200, height: 300),
      'pages.json': utf8.encode('{not json'),
    });

    final LocalSourceArchiveChapterContent? content =
        await LocalSourceReader.readArchiveContent(cbz.path);

    expect(content, isNotNull);
    expect(
      content!.pages.map((LocalSourcePage page) => page.relativePath),
      <String>['2.png', '10.png'],
    );
    expect(content.payload.images.first.size.width, 200);
    expect(content.payload.images.first.size.height, 300);
  });

  test('CBZ 阅读内容：包缺失或不是合法 ZIP 时返回 null', () async {
    expect(
      await LocalSourceReader.readArchiveContent(
        p.join(root.path, 'missing.cbz'),
      ),
      isNull,
    );
    final File broken = File(p.join(root.path, 'broken.cbz'))
      ..writeAsStringSync('not a zip');
    expect(await LocalSourceReader.readArchiveContent(broken.path), isNull);
  });

  test('CBZ 文件被移走后解析返回 null', () async {
    final File cbz = writeCbz('Manga/Ch 1.cbz', <String, List<int>>{
      '001.png': pngBytes(),
    });
    final String bookKey = await importAndGetKey();

    await cbz.delete();

    expect(
      await LocalSourceReader.resolveChapter(
        db: db,
        bookKey: bookKey,
        chapterIndex: 0,
      ),
      isNull,
    );
  });

  test('给定当前 Local source root 时，root 内的作品正常解析', () async {
    writePng('Manga/Ch 1/001.png');
    final String bookKey = await importAndGetKey();

    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
          localSourceRoot: root,
        );

    expect(resolved, isNotNull);
    expect(resolved!.chapterDirectory.path, p.join(root.path, 'Manga', 'Ch 1'));
  });

  test('切换 Content root 后旧 root 下的本地漫画不再被读取', () async {
    writePng('Manga/Ch 1/001.png');
    final String bookKey = await importAndGetKey();
    final Directory newRoot = await Directory.systemTemp.createTemp(
      'local_source_new_root_',
    );
    addTearDown(() async {
      if (newRoot.existsSync()) await newRoot.delete(recursive: true);
    });

    // 旧根的文件还在（switch 不搬移/删除），但它不是当前 Local source root。
    final LocalSourceResolvedChapter? resolved =
        await LocalSourceReader.resolveChapter(
          db: db,
          bookKey: bookKey,
          chapterIndex: 0,
          localSourceRoot: newRoot,
        );

    expect(resolved, isNull, reason: '不得回读旧 Content root 下的 local');
    expect(
      File(p.join(root.path, 'Manga', 'Ch 1', '001.png')).existsSync(),
      isTrue,
      reason: '旧文件原地保留',
    );
  });

  test('Local source 路径边界判定按目录段、大小写不敏感', () {
    expect(isLocalSourcePathWithinRoot(root.path, root), isTrue);
    expect(
      isLocalSourcePathWithinRoot(p.join(root.path, 'Manga', 'Ch 1'), root),
      isTrue,
    );
    expect(isLocalSourcePathWithinRoot('/another/root/Manga', root), isFalse);
    expect(
      isLocalSourcePathWithinRoot('${root.path}_sibling/Manga', root),
      isFalse,
      reason: '前缀相似但不是子目录',
    );
  });
}
