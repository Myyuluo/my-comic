import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_drop.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 06：拖入 Local source 的内容**先复制**到 `localcomic/{manga}/...`，再
/// 登记；原始文件保持不动。
void main() {
  late Directory root;
  late Directory managedRoot;
  late Directory outside;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_drop_root_');
    managedRoot = await Directory.systemTemp.createTemp(
      'local_source_drop_managed_',
    );
    outside = await Directory.systemTemp.createTemp(
      'local_source_drop_outside_',
    );
    EpubStorage.debugBaseDirectoryOverride = managedRoot.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    for (final Directory dir in <Directory>[root, managedRoot, outside]) {
      if (dir.existsSync()) await dir.delete(recursive: true);
    }
  });

  File writeFile(Directory base, String relative) {
    final File file = File(p.join(base.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(<int>[1, 2, 3]);
    return file;
  }

  File writeCbz(String path) {
    final List<int> page = img.encodePng(img.Image(width: 80, height: 120));
    final Archive archive = Archive()
      ..addFile(ArchiveFile('001.png', page.length, page));
    final File file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(ZipEncoder().encode(archive)!);
    return file;
  }

  test('拖入文件夹：复制进 localcomic 并登记，原文件保留', () async {
    final Directory source = Directory(p.join(outside.path, 'Dropped'))
      ..createSync(recursive: true);
    writeFile(source, 'cover.jpg');
    writeFile(source, p.join('Ch 1', '001.jpg'));
    writeFile(source, p.join('Ch 1', '002.jpg'));
    writeFile(source, p.join('Ch 2', '001.jpg'));

    final LocalSourceDropResult result =
        await LocalSourceDrop.importDroppedPath(
          db: db,
          root: root,
          sourcePath: source.path,
        );

    expect(result.registered, isTrue);
    expect(result.mangaDirectory?.path, p.join(root.path, 'Dropped'));
    expect(
      File(p.join(root.path, 'Dropped', 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(
      File(p.join(source.path, 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
      reason: '原始文件必须保留',
    );

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.title, 'Dropped');
    expect(row.extractDir, p.join(root.path, 'Dropped'));
    expect(row.coverPath, 'cover.jpg');
    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      row.chaptersJson,
    );
    expect(chapters, hasLength(2));
  });

  test('拖入单章文件夹（manga 目录直接含页图）也按单章登记', () async {
    final Directory source = Directory(p.join(outside.path, 'Single'))
      ..createSync(recursive: true);
    writeFile(source, '001.jpg');
    writeFile(source, '002.jpg');

    final LocalSourceDropResult result =
        await LocalSourceDrop.importDroppedPath(
          db: db,
          root: root,
          sourcePath: source.path,
        );

    expect(result.registered, isTrue);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      row.chaptersJson,
    );
    expect(chapters.single.relativePath, '');
    expect(row.chapterCount, 2);
  });

  test('同名作品不覆盖：复制为可预测的后缀并各自登记', () async {
    final Directory first = Directory(p.join(outside.path, 'a', 'Same'))
      ..createSync(recursive: true);
    writeFile(first, '001.jpg');
    final Directory second = Directory(p.join(outside.path, 'b', 'Same'))
      ..createSync(recursive: true);
    writeFile(second, '001.jpg');
    writeFile(second, '002.jpg');

    await LocalSourceDrop.importDroppedPath(
      db: db,
      root: root,
      sourcePath: first.path,
    );
    final LocalSourceDropResult secondResult =
        await LocalSourceDrop.importDroppedPath(
          db: db,
          root: root,
          sourcePath: second.path,
        );

    expect(secondResult.mangaDirectory?.path, p.join(root.path, 'Same (2)'));
    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(2));
    expect(
      rows.map((EpubBookRow row) => row.extractDir),
      containsAll(<String>[
        p.join(root.path, 'Same'),
        p.join(root.path, 'Same (2)'),
      ]),
    );
  });

  test('拖入 CBZ：复制到 {manga}/{chapter}.cbz 并登记，原文件保留', () async {
    final File cbz = writeCbz(p.join(outside.path, 'Vol 1.cbz'));

    final LocalSourceDropResult result =
        await LocalSourceDrop.importDroppedPath(
          db: db,
          root: root,
          sourcePath: cbz.path,
        );

    final String copied = p.join(root.path, 'Vol 1', 'Vol 1.cbz');
    expect(result.copiedPath, copied);
    expect(File(copied).existsSync(), isTrue);
    expect(cbz.existsSync(), isTrue);
    expect(result.registered, isTrue);
    expect(result.mangaDirectory?.path, p.join(root.path, 'Vol 1'));

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.title, 'Vol 1');
    expect(row.extractDir, p.join(root.path, 'Vol 1'));
    expect(row.coverPath, isNull);
    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      row.chaptersJson,
    );
    expect(chapters, hasLength(1));
    expect(chapters.single.key, 'Vol 1.cbz');
    expect(chapters.single.name, 'Vol 1');
  });

  test('拖入已在 localcomic 里的文件夹：不复制、直接登记', () async {
    final Directory source = Directory(p.join(root.path, 'InPlace'))
      ..createSync(recursive: true);
    writeFile(source, '001.jpg');

    final LocalSourceDropResult result =
        await LocalSourceDrop.importDroppedPath(
          db: db,
          root: root,
          sourcePath: source.path,
        );

    expect(result.mangaDirectory?.path, source.path);
    expect(result.registered, isTrue);
    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    expect(row.extractDir, source.path);
  });

  test('不支持的文件类型被明确拒绝', () async {
    final File txt = File(p.join(outside.path, 'notes.txt'))
      ..writeAsStringSync('hi');

    await expectLater(
      LocalSourceDrop.importDroppedPath(
        db: db,
        root: root,
        sourcePath: txt.path,
      ),
      throwsA(isA<LocalSourceDropException>()),
    );
  });
}
