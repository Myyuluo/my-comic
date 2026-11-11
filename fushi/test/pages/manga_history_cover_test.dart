import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/history/manga_history.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_revision.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/pages/implementations/manga_history_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;

import '../helpers/test_platform_services.dart';

/// Ticket 01：History 封面接入书架 Program state shelf cover 缓存。
///
/// seam 是真实 `loadMangaHistory`（真实 DB 行 + 临时 `shelf_covers` 文件）与
/// History 页面卡片；断言只落在用户可见的 `MangaHistoryEntry` 封面字段 /
/// 卡片图片 provider，不进入私有解析函数。
class _CoverTestAppModel extends AppModel {
  _CoverTestAppModel(this._db) : super(testPlatformServices());

  final FushiDatabase _db;

  @override
  FushiDatabase get database => _db;
}

/// 可控来源可用性的书架封面服务；缓存目录来自真实临时目录。
class _ControllableShelfCovers extends MangaShelfCoverService {
  _ControllableShelfCovers({
    required MangaShelfCoverCache cache,
    this.available = true,
  }) : super(cache: cache, serviceFor: (_) => null);

  bool available;

  @override
  Future<bool> isSourceAvailable(OnlineMangaLibraryEntry entry) async =>
      available;
}

List<int> _pngBytes() {
  final img.Image image = img.Image(width: 8, height: 12)
    ..clear(img.ColorRgb8(255, 0, 0));
  return img.encodePng(image);
}

OnlineMangaLibraryEntry _onlineEntry({String? coverUrl}) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        coverUrl: coverUrl,
        raw: const <String, Object?>{},
      ),
      chapters: const <OnlineMangaChapter>[],
    );

Future<EpubBookRow> _insertLibraryBook(
  FushiDatabase db,
  Directory root, {
  String bookKey = 'history-cover-book',
  String? coverPath,
  bool localCover = false,
  String? seriesCoverUrl,
}) async {
  final Directory extractDir = Directory(p.join(root.path, 'books', bookKey))
    ..createSync(recursive: true);
  if (localCover) {
    File(p.join(extractDir.path, 'cover.jpg'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(_pngBytes());
  }
  final OnlineMangaLibraryEntry entry = _onlineEntry(coverUrl: seriesCoverUrl);
  await db.insertEpubBook(
    EpubBooksCompanion.insert(
      bookKey: bookKey,
      title: 'Fixture series',
      epubPath: '',
      extractDir: extractDir.path,
      chapterCount: 0,
      chaptersJson: '[]',
      importedAt: 1,
      format: const Value<String>('manga'),
      coverPath: Value<String?>(coverPath),
      sourceMetadata: Value<String?>(entry.encode()),
    ),
  );
  return (await db.getEpubBook(bookKey))!;
}

Future<EpubBookRow> _seedHistory(
  FushiDatabase db,
  Directory root, {
  String bookKey = 'history-cover-book',
  String? coverPath,
  bool localCover = false,
  String? seriesCoverUrl,
}) async {
  final EpubBookRow row = await _insertLibraryBook(
    db,
    root,
    bookKey: bookKey,
    coverPath: coverPath,
    localCover: localCover,
    seriesCoverUrl: seriesCoverUrl,
  );
  await recordMangaHistoryOpened(
    db: db,
    row: row,
    onlineEntry: _onlineEntry(coverUrl: seriesCoverUrl),
  );
  return row;
}

/// 写一条不带快照封面 URL 的 History 行：远程只能来自 Library / 快照里的
/// 来源 `series.coverUrl`，用来单独验证来源可用性判定。
Future<void> _insertHistoryRow(
  FushiDatabase db, {
  required String bookKey,
  required String title,
}) async {
  final EpubBookRow book = (await db.getEpubBook(bookKey))!;
  final OnlineMangaLibraryEntry entry = OnlineMangaLibraryEntry.tryParse(
    book.sourceMetadata,
  )!;
  await db.upsertMediaOpenHistory(
    MediaOpenHistoryCompanion(
      mediaType: const Value<String>('reader_media_type'),
      mediaSource: Value<String>(mangaHistoryOnlineSourceKey(entry)),
      mediaId: Value<String>(entry.series.key),
      openedAt: const Value<int>(1),
      position: const Value<int>(0),
      duration: const Value<int>(0),
      snapshotJson: Value<String>(
        jsonEncode(
          MangaHistorySnapshot(
            title: title,
            bookKey: bookKey,
            online: MangaHistoryOnlineRef.fromEntry(entry),
          ).toJson(),
        ),
      ),
    ),
  );
}

Finder _fileCover(String path) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is Image &&
      widget.image is FileImage &&
      (widget.image as FileImage).file.path == path,
);

Widget _harness(
  AppModel appModel,
  MangaShelfCoverService covers, {
  Key? pageKey,
}) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((Ref ref) => appModel),
    mangaHistoryShelfCoverServiceProvider.overrideWithValue(covers),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: Scaffold(body: MangaHistoryPage(key: pageKey)),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump(const Duration(milliseconds: 30));
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FushiDatabase db;
  late MangaShelfCoverCache cache;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    MangaShelfCoverRevision.debugReset();
    root = await Directory.systemTemp.createTemp('manga_history_cover_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    cache = MangaShelfCoverCache(
      Directory(p.join(root.path, 'userdata', 'cache', 'shelf_covers')),
    );
  });

  tearDown(() async {
    MangaShelfCoverRevision.debugReset();
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('Program state 持久封面优先于远程 URL，并以本地文件路径暴露', () async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await cache.store(
      bookKey: book.bookKey,
      sourceUrl: 'https://source.test/remote.jpg',
      bytes: _pngBytes(),
    );
    final File cached = cache.coverPathFor(book.bookKey);
    expect(cached.existsSync(), isTrue);

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache),
    );

    expect(entries, hasLength(1));
    expect(entries.single.coverFilePath, cached.path);
    expect(
      entries.single.coverUrl,
      isNull,
      reason: '已命中 Program state 封面，不应再回退远程 URL',
    );
  });

  test('来源不可用时跳过远程 URL，显示占位', () async {
    await _insertLibraryBook(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await _insertHistoryRow(
      db,
      bookKey: 'history-cover-book',
      title: 'Fixture series',
    );

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache, available: false),
    );

    expect(entries.single.coverFilePath, isNull);
    expect(entries.single.coverUrl, isNull, reason: '来源未安装 / 停用时不得显示必然失败的远程封面');
  });

  test('来源可用时回退到来源 series.coverUrl', () async {
    await _insertLibraryBook(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await _insertHistoryRow(
      db,
      bookKey: 'history-cover-book',
      title: 'Fixture series',
    );

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache),
    );

    expect(entries.single.coverFilePath, isNull);
    expect(entries.single.coverUrl, 'https://source.test/remote.jpg');
  });

  test('未注入 shelf cover service 时保留旧的远程回退（unknown）', () async {
    await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );

    // 旧调用方 / 启动早期没有来源可用性信息：unknown 显式保留远程回退，
    // 而不是把「无法判定」隐式当成 true/false。
    final List<MangaHistoryEntry> entries = await loadMangaHistory(db);

    expect(entries.single.coverFilePath, isNull);
    expect(entries.single.coverUrl, 'https://source.test/remote.jpg');
  });

  test('无 Library 行时也按快照来源可用性跳过远程 URL', () async {
    final OnlineMangaLibraryEntry entry = _onlineEntry(
      coverUrl: 'https://source.test/remote.jpg',
    );
    await db.upsertMediaOpenHistory(
      MediaOpenHistoryCompanion(
        mediaType: const Value<String>('reader_media_type'),
        mediaSource: Value<String>(mangaHistoryOnlineSourceKey(entry)),
        mediaId: Value<String>(entry.series.key),
        openedAt: const Value<int>(1),
        position: const Value<int>(0),
        duration: const Value<int>(0),
        snapshotJson: Value<String>(
          jsonEncode(
            MangaHistorySnapshot(
              title: 'Snapshot only',
              online: MangaHistoryOnlineRef.fromEntry(entry),
            ).toJson(),
          ),
        ),
      ),
    );

    final List<MangaHistoryEntry> unavailable = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache, available: false),
    );
    expect(unavailable.single.bookKey, isNull);
    expect(unavailable.single.coverUrl, isNull);

    final List<MangaHistoryEntry> available = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache),
    );
    expect(available.single.coverUrl, 'https://source.test/remote.jpg');
  });

  test('Library 本地 cover.* 优先于 Program state 封面与远程 URL', () async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      localCover: true,
      coverPath: 'cover.jpg',
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await cache.store(
      bookKey: book.bookKey,
      sourceUrl: 'https://source.test/remote.jpg',
      bytes: _pngBytes(),
    );

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache),
    );

    expect(
      entries.single.coverFilePath,
      p.join(root.path, 'books', book.bookKey, 'cover.jpg'),
    );
    expect(entries.single.coverUrl, isNull);
  });

  test('远程可用且存在生成封面时优先使用远程 URL', () async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await cache.store(
      bookKey: book.bookKey,
      sourceUrl: 'local-first-page:${p.join(root.path, 'Ch 1.cbz')}|100|123',
      bytes: _pngBytes(),
    );

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache),
    );

    expect(
      entries.single.coverFilePath,
      isNull,
      reason: '可用来源的最新远程封面优先于第一页生成封面',
    );
    expect(entries.single.coverUrl, 'https://source.test/remote.jpg');
  });

  test('来源未安装时显示第一页生成封面（darklust 场景）', () async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await cache.store(
      bookKey: book.bookKey,
      sourceUrl: 'local-first-page:${p.join(root.path, 'Ch 1.cbz')}|100|123',
      bytes: _pngBytes(),
    );
    final File generated = cache.coverPathFor(book.bookKey);
    expect(generated.existsSync(), isTrue);

    final List<MangaHistoryEntry> entries = await loadMangaHistory(
      db,
      shelfCovers: _ControllableShelfCovers(cache: cache, available: false),
    );

    expect(
      entries.single.coverFilePath,
      generated.path,
      reason: '来源未安装但已有生成封面时必须显示，不得回到灰占位',
    );
    expect(entries.single.coverUrl, isNull);
  });

  testWidgets('挂载期间封面写入并 bump revision 后自动刷新', (WidgetTester tester) async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    final _ControllableShelfCovers covers = _ControllableShelfCovers(
      cache: cache,
      available: false,
    );
    await tester.pumpWidget(_harness(_CoverTestAppModel(db), covers));
    await _settle(tester);

    final String coverPath = cache.coverPathFor(book.bookKey).path;
    expect(find.byType(ShelfCoverPlaceholder), findsOneWidget);
    expect(_fileCover(coverPath), findsNothing);

    await tester.runAsync(() async {
      await cache.store(
        bookKey: book.bookKey,
        sourceUrl: 'local-first-page:${p.join(root.path, 'Ch 1.cbz')}|1|2',
        bytes: _pngBytes(),
      );
      MangaShelfCoverRevision.bump();
    });
    await _settle(tester);

    expect(
      _fileCover(coverPath),
      findsOneWidget,
      reason: '页面挂载期间封面写入成功后必须重新加载，无需切换页面',
    );
    expect(find.byType(ShelfCoverPlaceholder), findsNothing);
  });

  testWidgets('重新进入 History 页读取最新缓存封面', (WidgetTester tester) async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    final _ControllableShelfCovers covers = _ControllableShelfCovers(
      cache: cache,
      available: false,
    );
    await tester.pumpWidget(_harness(_CoverTestAppModel(db), covers));
    await _settle(tester);
    expect(find.byType(ShelfCoverPlaceholder), findsOneWidget);

    // 页面非 keep-alive：离开后重新进入会重新初始化并重新读取缓存。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await cache.store(
        bookKey: book.bookKey,
        sourceUrl: 'local-first-page:${p.join(root.path, 'Ch 1.cbz')}|1|2',
        bytes: _pngBytes(),
      );
      MangaShelfCoverRevision.bump();
    });

    await tester.pumpWidget(_harness(_CoverTestAppModel(db), covers));
    await _settle(tester);

    expect(
      _fileCover(cache.coverPathFor(book.bookKey).path),
      findsOneWidget,
      reason: '重新进入 History 页面必须读取最新 Program state 封面',
    );
  });

  testWidgets('History 卡片把 Program state 的 file:// 封面渲染为 Image.file', (
    WidgetTester tester,
  ) async {
    final EpubBookRow book = await _seedHistory(
      db,
      root,
      seriesCoverUrl: 'https://source.test/remote.jpg',
    );
    await tester.runAsync(
      () => cache.store(
        bookKey: book.bookKey,
        sourceUrl: 'https://source.test/remote.jpg',
        bytes: _pngBytes(),
      ),
    );
    final File cached = cache.coverPathFor(book.bookKey);

    await tester.pumpWidget(
      _harness(_CoverTestAppModel(db), _ControllableShelfCovers(cache: cache)),
    );
    await _settle(tester);

    expect(find.byType(ShelfCoverFrame), findsOneWidget);
    expect(
      _fileCover(cached.path),
      findsOneWidget,
      reason: 'History 卡片必须读取 Program state 的 file:// 封面，而不只是 cover_path',
    );
  });
}
