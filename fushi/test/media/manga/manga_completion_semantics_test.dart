import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/manga_adjacent_chapter.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// manga-shelf-download-ux 票 01：书级完成标记只在**规范阅读顺序最后一章
/// （最新一话）的最后一页**自动写入；读完旧章只写章级 `readAt`。
///
/// 真实 37 表内存库 + 真实在线章节目录 + 真实漫画阅读页：把阅读器里的页码
/// 推到章末，断言数据库里的章状态与 `EpubBooks.completedAt`。
class _CompletionTestAppModel extends AppModel {
  _CompletionTestAppModel({
    required FushiDatabase database,
    required PreferencesRepository prefs,
    required Directory directory,
    required OnlineMangaLibraryService library,
  }) : _directory = directory,
       _library = library,
       super(testPlatformServices()) {
    wireDatabaseForTesting(database);
    wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: directory);
  }

  final Directory _directory;
  final OnlineMangaLibraryService _library;

  @override
  Directory get temporaryDirectory => _directory;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  @override
  double get appUiScale => 1.0;

  @override
  bool get mangaChromeFloating => false;

  @override
  MangaReaderPreferences get mangaReaderPreferences =>
      const MangaReaderPreferences(ocrTrigger: 'manual');
}

class _FakeOnlineAdapter implements OnlineMangaRuntimeAdapter {
  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => 'Fake';

  @override
  Future<OnlineMangaRefreshResult> refresh(
    OnlineMangaLibraryEntry entry,
  ) async =>
      OnlineMangaRefreshResult(series: entry.series, chapters: entry.chapters);

  @override
  Future<List<OnlineMangaPageRef>> resolveChapterPages({
    required OnlineMangaLibraryEntry entry,
    required OnlineMangaChapter chapter,
  }) async => throw StateError('source unavailable');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) async =>
      throw StateError('source unavailable');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47];
}

MediaItem _item(String bookKey) => MediaItem(
  mediaIdentifier: 'fushi://book/$bookKey',
  mediaSourceIdentifier: 'reader_manga',
  title: 'Completion Manga',
  mediaTypeIdentifier: 'reader',
  position: 0,
  duration: 1,
  canDelete: false,
  canEdit: true,
);

Widget _harness(AppModel appModel, String bookKey, {int? chapterIndex}) =>
    ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(testPlatformServices()),
        appProvider.overrideWith((ref) => appModel),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: MangaFushiPage(
            item: _item(bookKey),
            bookKey: bookKey,
            initialChapterIndex: chapterIndex,
          ),
        ),
      ),
    );

// 存储数组**旧章在前**：第 1 话下标 0，第 2 话（最新）下标 1。规范阅读顺序
// 是第 1 话 → 第 2 话；旧实现会让读完第 1 话写书级完成。
const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Completion series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
  currentChapterIndex: 0,
);

Future<void> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
  OnlineMangaChapter chapter,
) async {
  final String folderName = 'Chapter ${chapter.number!.toInt()}';
  final Directory chapterDir = downloadChapterDirectory(bookDir, folderName);
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await File(p.join(chapterDir.path, '002.jpg')).writeAsBytes(<int>[2]);
  await writePagesManifestAtomically(
    chapterDir,
    MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Completion series',
      chapterKey: chapter.key,
      chapterName: chapter.name,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
          MokuroImage(
            url: '002.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 7),
    ),
  );
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapter.key,
    folderName: folderName,
    updatedAt: 1,
  );
}

void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  tearDown(() {
    EpubStorage.debugBaseDirectoryOverride = null;
  });

  test('规范阅读顺序：本地源的存储顺序就是阅读顺序，在线条目按 sourceOrder/话数', () {
    const List<OnlineMangaChapter> natural = <OnlineMangaChapter>[
      OnlineMangaChapter(
        key: '/old',
        name: 'Chapter 1',
        raw: <String, Object?>{},
      ),
      OnlineMangaChapter(
        key: '/new',
        name: 'Chapter 2',
        raw: <String, Object?>{},
      ),
    ];
    expect(
      isLastMangaChapterInReadingOrder(
        chapters: natural,
        index: 1,
        ordering: MangaChapterOrdering.natural,
      ),
      isTrue,
    );
    expect(
      isLastMangaChapterInReadingOrder(
        chapters: natural,
        index: 0,
        ordering: MangaChapterOrdering.natural,
      ),
      isFalse,
    );
    // 在线条目没有本地源的自然顺序标记：按话数推出第 2 话是最后一章。
    expect(
      isLastMangaChapterInReadingOrder(chapters: _chapters, index: 0),
      isFalse,
    );
    expect(
      isLastMangaChapterInReadingOrder(chapters: _chapters, index: 1),
      isTrue,
    );
    const List<OnlineMangaChapter> single = <OnlineMangaChapter>[
      OnlineMangaChapter(
        key: '/only',
        name: 'Only',
        number: 1,
        raw: <String, Object?>{},
      ),
    ];
    expect(
      isLastMangaChapterInReadingOrder(chapters: single, index: 0),
      isTrue,
      reason: '单章作品的唯一一章同时是最后一章',
    );
  });

  testWidgets('读完旧章只写章级已读；读到最新章末页才写书级完成', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final Directory root = Directory.systemTemp.createTempSync(
      'fushi_completion_online_',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    EpubStorage.debugBaseDirectoryOverride = root.path;
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final OnlineMangaLibraryService library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeOnlineAdapter(),
    );
    final AppModel appModel = _CompletionTestAppModel(
      database: db,
      prefs: prefs,
      directory: root,
      library: library,
    );

    late String bookKey;
    late String bookUid;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      bookUid = row.uid;
      for (final OnlineMangaChapter chapter in _chapters) {
        await _writeDownloadedChapter(db, row.bookKey, row.extractDir, chapter);
      }
      // 从旧章（存储下标 0）打开。
      await tester.pumpWidget(_harness(appModel, bookKey, chapterIndex: 0));
      await pumpUntilFound(
        tester,
        find.byKey(const ValueKey<String>('manga_content_ready')),
      );
    });

    // 旧章翻到最后一页：章级已读写上，书级完成不写。
    await tester.runAsync(() async {
      await readerSessionRemotes.current.value!.goToPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    final MangaChapterStateRow oldState = (await db.getMangaChapterState(
      bookUid: bookUid,
      chapterKey: '/chapter/1',
    ))!;
    expect(oldState.readAt, isNotNull, reason: '读出旧章末页 = 该章已读');
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNull,
      reason: '读完旧章不得把整部作品标成读完',
    );

    // 切到最新章（规范阅读顺序最后一章）并翻到末页：这时才写书级完成。
    await tester.runAsync(() async {
      expect(await readerSessionRemotes.current.value!.goToChapter(1), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await readerSessionRemotes.current.value!.goToPage(1);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    expect(
      (await db.getMangaChapterState(
        bookUid: bookUid,
        chapterKey: '/chapter/2',
      ))!.readAt,
      isNotNull,
    );
    expect(
      (await db.getEpubBook(bookKey))!.completedAt,
      isNotNull,
      reason: '读到规范阅读顺序最后一章末页才自动完成整部作品',
    );
  });
}
