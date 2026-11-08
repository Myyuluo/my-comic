import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Ticket 06：书架长按 / 批删 / 合集连删都经过 [ReaderFushiSource.deleteBook]；
/// Local source 条目必须只删记录并立墓碑，**不删 local 文件**。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory managedRoot;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_shelf_root_');
    managedRoot = await Directory.systemTemp.createTemp(
      'local_source_shelf_managed_',
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

  test('书架删除 Local source 条目：删记录 + 墓碑，文件原样保留', () async {
    final File page = File(p.join(root.path, 'Manga', 'Ch 1', '001.jpg'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.registerScannedManga(
      (await scanLocalSourceRoot(root)).single,
    );
    final String bookKey = (await db.getAllEpubBooks()).single.bookKey;

    final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
      db: db,
      bookKey: bookKey,
      appModel: null,
    );

    expect(result.deleted, isTrue);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getBookTombstoneKeys(), contains(bookKey));
    expect(page.existsSync(), isTrue, reason: '移出书架不得删除本地文件');
    expect(managedRoot.listSync(), isEmpty, reason: '不得在受管书库里留下副本');
  });

  test('书架删除 Local source CBZ 条目：删记录 + 墓碑，CBZ 原样保留', () async {
    final List<int> pageBytes = img.encodePng(
      img.Image(width: 80, height: 120),
    );
    final Archive archive = Archive()
      ..addFile(ArchiveFile('001.png', pageBytes.length, pageBytes));
    final File cbz = File(p.join(root.path, 'Vol 1', 'Vol 1.cbz'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.registerScannedManga(
      (await scanLocalSourceRoot(root)).single,
    );
    final String bookKey = (await db.getAllEpubBooks()).single.bookKey;

    final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
      db: db,
      bookKey: bookKey,
      appModel: null,
    );

    expect(result.deleted, isTrue);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getBookTombstoneKeys(), contains(bookKey));
    expect(cbz.existsSync(), isTrue, reason: '移出书架不得删除 CBZ');
    expect(managedRoot.listSync(), isEmpty, reason: '不得在受管书库里留下副本');
  });
}
