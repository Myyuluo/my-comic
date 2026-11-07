import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ticket 06：把 `localcomic` 扫描结果登记进 Library —— 原地引用，不复制；
/// 移出书架只删记录（tombstone），删文件是单独且显式确认的动作。
void main() {
  late Directory root;
  late Directory managedRoot;
  late FushiDatabase db;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('local_source_lib_root_');
    managedRoot = await Directory.systemTemp.createTemp(
      'local_source_lib_managed_',
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

  File writeFile(String relative, {List<int> bytes = const <int>[1, 2, 3]}) {
    final File file = File(p.join(root.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
    return file;
  }

  test('扫描后登记为 manga 行：extractDir 原地指向、cover 与章节元数据落库', () async {
    writeFile(p.join('Manga A', 'cover.jpg'));
    writeFile(p.join('Manga A', 'Ch 1', '001.jpg'));
    writeFile(p.join('Manga A', 'Ch 1', '002.jpg'));
    writeFile(p.join('Manga A', 'Ch 2', '001.jpg'));
    writeFile(p.join('Single', '001.png'));
    writeFile(p.join('Single', '002.png'));

    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    final LocalSourceImportReport report = await library.importFromRoot();

    expect(report.added, 2);
    expect(report.refreshed, 0);
    expect(report.skippedTombstoned, 0);
    expect(report.failed, 0);

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    final EpubBookRow mangaA = rows.singleWhere(
      (EpubBookRow row) => row.title == 'Manga A',
    );
    expect(mangaA.format, 'manga');
    expect(mangaA.extractDir, p.join(root.path, 'Manga A'));
    expect(mangaA.coverPath, 'cover.jpg');
    expect(mangaA.chapterCount, 3, reason: 'chapterCount 记录总页数');
    expect(
      LocalSourceMetadata.tryParse(mangaA.sourceMetadata)?.relativePath,
      'Manga A',
    );

    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      mangaA.chaptersJson,
    );
    expect(
      chapters.map((LocalSourceChapterRecord c) => c.relativePath),
      <String>['Ch 1', 'Ch 2'],
    );
    expect(chapters.first.key, 'Ch 1');

    final EpubBookRow single = rows.singleWhere(
      (EpubBookRow row) => row.title == 'Single',
    );
    expect(single.coverPath, '001.png');
    final List<LocalSourceChapterRecord> singleChapters =
        decodeLocalSourceChapters(single.chaptersJson);
    expect(singleChapters, hasLength(1));
    expect(singleChapters.single.relativePath, '');
    expect(singleChapters.single.key, kLocalSourceRootChapterKey);

    // 原地读取：受管书库目录里没有这本书的任何副本。
    expect(managedRoot.listSync(), isEmpty);
  });

  test('重复扫描幂等：更新同一行，不重复登记、不搬文件', () async {
    writeFile(p.join('Manga', 'Ch 1', '001.jpg'));
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);

    await library.importFromRoot();
    writeFile(p.join('Manga', 'Ch 1', '002.jpg'));
    writeFile(p.join('Manga', 'Ch 2', '001.jpg'));
    final LocalSourceImportReport second = await library.importFromRoot();

    expect(second.added, 0);
    expect(second.refreshed, 1);

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1));
    expect(rows.single.chapterCount, 3);
    expect(
      decodeLocalSourceChapters(
        rows.single.chaptersJson,
      ).map((LocalSourceChapterRecord c) => c.relativePath),
      <String>['Ch 1', 'Ch 2'],
    );
    expect(
      File(p.join(root.path, 'Manga', 'Ch 1', '002.jpg')).existsSync(),
      isTrue,
    );
  });

  test('移出书架只删记录并立墓碑，磁盘文件原样保留；再扫描不会复活', () async {
    writeFile(p.join('Manga', 'Ch 1', '001.jpg'));
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.importFromRoot();
    final EpubBookRow row = (await db.getAllEpubBooks()).single;

    expect(await library.removeFromLibrary(row.bookKey), isTrue);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getBookTombstoneKeys(), contains(row.bookKey));
    expect(
      File(p.join(root.path, 'Manga', 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );

    final LocalSourceImportReport again = await library.importFromRoot();
    expect(again.added, 0);
    expect(again.skippedTombstoned, 1);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getBookTombstoneKeys(), contains(row.bookKey));
  });

  test('删除本地文件必须显式确认；未确认不动文件，确认后删目录并留墓碑', () async {
    writeFile(p.join('Manga', 'Ch 1', '001.jpg'));
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.importFromRoot();
    final EpubBookRow row = (await db.getAllEpubBooks()).single;

    final LocalSourceDeleteResult notConfirmed = await library.deleteLocalFiles(
      row.bookKey,
      confirmed: false,
    );
    expect(notConfirmed.deleted, isFalse);
    expect(notConfirmed.reason, LocalSourceDeleteReason.notConfirmed);
    expect(
      File(p.join(root.path, 'Manga', 'Ch 1', '001.jpg')).existsSync(),
      isTrue,
    );
    expect(await db.getAllEpubBooks(), hasLength(1));

    final LocalSourceDeleteResult confirmed = await library.deleteLocalFiles(
      row.bookKey,
      confirmed: true,
    );
    expect(confirmed.deleted, isTrue);
    expect(Directory(p.join(root.path, 'Manga')).existsSync(), isFalse);
    expect(await db.getAllEpubBooks(), isEmpty);
    expect(await db.getBookTombstoneKeys(), contains(row.bookKey));
  });

  test('拒绝删除 Local source root 之外登记的条目', () async {
    final Directory outside = await Directory.systemTemp.createTemp(
      'local_source_outside_',
    );
    addTearDown(() async {
      if (outside.existsSync()) await outside.delete(recursive: true);
    });
    final File page = File(p.join(outside.path, '001.jpg'))
      ..writeAsBytesSync(<int>[1]);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'local-outside',
        title: 'Outside',
        epubPath: '',
        extractDir: outside.path,
        chapterCount: 1,
        chaptersJson: encodeLocalSourceChapters(
          const <LocalSourceChapterRecord>[
            LocalSourceChapterRecord(
              key: '.',
              name: 'Outside',
              relativePath: '',
            ),
          ],
        ),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(relativePath: 'Outside').encode(),
        ),
      ),
    );

    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    final LocalSourceDeleteResult result = await library.deleteLocalFiles(
      'local-outside',
      confirmed: true,
    );

    expect(result.deleted, isFalse);
    expect(result.reason, LocalSourceDeleteReason.outsideLocalSourceRoot);
    expect(page.existsSync(), isTrue);
    expect(await db.getAllEpubBooks(), hasLength(1));
  });

  test('bookKey 由绝对目录路径决定：同一路径稳定，改名视为新作品', () async {
    final String a = p.join(root.path, 'Manga');
    final String b = p.join(root.path, 'Manga Renamed');

    expect(localSourceBookKeyFor(a), localSourceBookKeyFor(a));
    expect(localSourceBookKeyFor(a), isNot(localSourceBookKeyFor(b)));
    expect(localSourceBookKeyFor(a), startsWith('local-'));
    expect(localSourceBookKeyFor(a).length, 38);
  });

  test('cover.jpg 不进入单章的页表', () async {
    writeFile(p.join('Single', 'cover.jpg'));
    writeFile(p.join('Single', '001.jpg'));
    final LocalSourceLibrary library = LocalSourceLibrary(db: db, root: root);
    await library.importFromRoot();

    final EpubBookRow row = (await db.getAllEpubBooks()).single;
    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      row.chaptersJson,
    );
    expect(chapters.single.relativePath, '');
    final Map<String, Object?> metadata =
        jsonDecode(row.sourceMetadata!) as Map<String, Object?>;
    expect(metadata['kind'], LocalSourceMetadata.marker);
  });
}
