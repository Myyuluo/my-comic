import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// Ticket 02：从 Mihon 备份导入的 Library 作品没有本地封面文件，备份里只存了
/// `series.coverUrl`。书架封面解析必须回退到这条远程 URL（交给现有 HTTP 图片
/// 缓存懒加载），同时保持本地封面优先、不污染「最近可用本地封面」缓存。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导入作品封面远程回退（书架解析链）', () {
    late Directory tempDir;
    late FushiDatabase db;

    setUp(() {
      ReaderFushiSource.debugResetCoverCache();
      tempDir = Directory.systemTemp.createTempSync('fushi_imported_cover_');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      MediaSource.setDatabase(db);
    });

    tearDown(() async {
      ReaderFushiSource.debugResetCoverCache();
      await db.close();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    String metadataWithCover(String? coverUrl) => OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'mihon.unavailable',
      sourceId: '524579092615598717',
      series: OnlineMangaSeries(
        key: '/series/imported',
        title: 'Imported',
        coverUrl: coverUrl,
        raw: const <String, Object?>{},
      ),
      chapters: const <OnlineMangaChapter>[],
    ).encode();

    Future<void> insertImportedBook({
      String? coverUrl,
      bool localCover = false,
    }) async {
      final String extractDir = p.join(tempDir.path, 'imported');
      Directory(extractDir).createSync(recursive: true);
      if (localCover) {
        File(p.join(extractDir, 'cover.jpg'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
      }
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'imported',
          title: 'Imported',
          epubPath: p.join(tempDir.path, 'imported.epub'),
          extractDir: extractDir,
          chapterCount: 0,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
          format: const Value<String>('manga'),
          sourceMetadata: Value<String?>(metadataWithCover(coverUrl)),
        ),
      );
    }

    test('本地没有封面文件时，imageUrl 回退到备份里的 series.coverUrl', () async {
      await insertImportedBook(coverUrl: 'https://example.test/imported.jpg');

      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey('imported');

      expect(item, isNotNull);
      expect(
        item!.imageUrl,
        'https://example.test/imported.jpg',
        reason: '导入作品没有本地封面时必须使用备份已存的远程封面，而不是灰占位',
      );
    });

    test('本地封面文件优先于远程 coverUrl', () async {
      await insertImportedBook(
        coverUrl: 'https://example.test/imported.jpg',
        localCover: true,
      );

      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey('imported');

      expect(item, isNotNull);
      expect(
        Uri.parse(item!.imageUrl!).toFilePath(),
        p.join(tempDir.path, 'imported', 'cover.jpg'),
        reason: '本地封面始终优先，远程回退不得覆盖已有的本地封面',
      );
    });

    test('远程回退不写入本地「最近可用封面」缓存', () async {
      await insertImportedBook(coverUrl: 'https://example.test/first.jpg');
      final MediaItem? first = await ReaderFushiSource.instance
          .mediaItemForBookKey('imported');
      expect(first?.imageUrl, 'https://example.test/first.jpg');

      // 同一个 bookKey（始终没有本地封面），换一条远程地址。若上一次的远程
      // URL 被误写进「最近可用封面」缓存，第二次解析会在缓存层直接命中旧地址，
      // 而不是新地址——这就是本地缓存语义被远程回退污染的可见后果。
      await (db.update(
        db.epubBooks,
      )..where((EpubBooks tbl) => tbl.bookKey.equals('imported'))).write(
        EpubBooksCompanion(
          sourceMetadata: Value<String?>(
            metadataWithCover('https://example.test/second.jpg'),
          ),
        ),
      );

      final MediaItem? second = await ReaderFushiSource.instance
          .mediaItemForBookKey('imported');

      expect(
        second?.imageUrl,
        'https://example.test/second.jpg',
        reason: '远程回退不得进入只存本地 file:// URL 的 last-good 缓存（BUG-513）',
      );
    });

    test('coverUrl 为空时不伪造封面：imageUrl 为 null，由占位封面兜底', () async {
      await insertImportedBook(coverUrl: '   ');

      final MediaItem? item = await ReaderFushiSource.instance
          .mediaItemForBookKey('imported');

      expect(item, isNotNull);
      expect(item!.imageUrl, isNull, reason: '空的远程地址不得变成可渲染的封面 URL');
    });
  });
}
