import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_storage.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;

import '../../helpers/test_platform_services.dart';

/// 作品页阶段 C（设计稿 2026-09-12 §1.3 / §2.3 / §5）：「下载全部」、「完成后自动
/// 识别」chip、「识别本章」、「识别全部已下载」、订阅 / 新章自动下载。
class _FakeAdapter implements OnlineMangaRuntimeAdapter {
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
  }) => throw StateError('the series page must not resolve pages');

  @override
  Future<Uint8List> fetchChapterPage(OnlineMangaPageRef page) =>
      throw StateError('the series page must not fetch pages');

  @override
  Future<List<int>> fetchCover(
    OnlineMangaLibraryEntry entry,
    String url,
  ) async => <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
}

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._library, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final OnlineMangaLibraryService _library;
  final List<MediaItem?> opened = <MediaItem?>[];

  @override
  FushiDatabase get database => _db;

  @override
  OnlineMangaLibraryService onlineMangaLibraryService(
    OnlineMangaRuntimeKind runtime,
  ) => _library;

  @override
  Future<void> openMedia({
    required WidgetRef ref,
    required MediaSource mediaSource,
    bool killOnPop = false,
    bool pushReplacement = false,
    MediaItem? item,
    Bookmark? initialBookmarkJump,
    bool recordHistory = true,
    bool waitUntilClosed = true,
    Widget Function()? launchPageBuilder,
  }) async {
    opened.add(item);
  }
}

Widget _harness(AppModel appModel, String bookKey) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(
      home: MangaSeriesPage(target: ShelfMangaSeriesTarget(bookKey)),
    ),
  ),
);

const List<OnlineMangaChapter> _chapters = <OnlineMangaChapter>[
  OnlineMangaChapter(
    key: '/chapter/3',
    name: 'Chapter 3',
    number: 3,
    raw: <String, Object?>{'url': '/chapter/3'},
  ),
  OnlineMangaChapter(
    key: '/chapter/2',
    name: 'Chapter 2',
    number: 2,
    raw: <String, Object?>{'url': '/chapter/2'},
  ),
  OnlineMangaChapter(
    key: '/chapter/1',
    name: 'Chapter 1',
    number: 1,
    raw: <String, Object?>{'url': '/chapter/1'},
  ),
];

OnlineMangaLibraryEntry _entry() => const OnlineMangaLibraryEntry(
  runtime: OnlineMangaRuntimeKind.mihon,
  extensionPackage: 'org.example.fixture',
  sourceId: '1',
  series: OnlineMangaSeries(
    key: '/series/fixture',
    title: 'Fixture series',
    raw: <String, Object?>{'url': '/series/fixture'},
  ),
  chapters: _chapters,
);

/// 造一章「已下载」：页图 + manga.json。[withBlocks] = 这章已经识别过（blocks 非空）。
Future<void> _writeDownloadedChapter(
  String bookDir,
  String chapterKey, {
  bool withBlocks = false,
}) async {
  final Directory chapterDir = mangaChapterDirectory(bookDir, chapterKey);
  final Directory images = mangaChapterImagesDirectory(chapterDir);
  await images.create(recursive: true);
  await File(p.join(images.path, 'page-000001.jpg')).writeAsBytes(<int>[1]);
  await mangaChapterJsonFile(chapterDir).writeAsString(
    jsonEncode(<String, Object?>{
      'pages': <Map<String, Object?>>[
        <String, Object?>{
          'url': 'images/page-000001.jpg',
          'width': 100,
          'height': 150,
          'blocks': <Object?>[
            if (withBlocks)
              <String, Object?>{
                'box': <int>[0, 0, 10, 10],
                'vertical': false,
                'font_size': 12,
                'lines': <String>['x'],
              },
          ],
        },
      ],
    }),
  );
}

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// 等异步回调落地 + 推进动画时钟（弹出菜单的开合动画不推 duration 不会结束）。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 作品页 hero 的「⋯」更多操作（M3E 详情骨架：原 AppBar 动作、自动识别、
/// 识别全部已下载都在这里）。
const ValueKey<String> _moreKey = ValueKey<String>('online_work_more');

/// 某一章行尾的溢出菜单按钮。
Finder _chapterMenu(String chapterName) => find.descendant(
  of: find.ancestor(
    of: find.text(chapterName),
    matching: find.byType(MediaDetailItemRow),
  ),
  matching: find.byType(FushiOverflowMenu<String>),
);

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_series_phase_c_');
    EpubStorage.debugBaseDirectoryOverride = root.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    library = OnlineMangaLibraryService(
      database: db,
      rootDirectory: Directory(p.join(root.path, 'legacy')),
      adapter: _FakeAdapter(),
    );
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('下载全部：已下载的不入队、再点一次不重复', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late String bookKey;
    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await _writeDownloadedChapter(row.extractDir, '/chapter/1');
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_downloaded')),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await _settle(tester);
    });

    List<MangaDownloadJobRow> jobs = await db.listMangaDownloadJobs();
    expect(jobs, hasLength(2), reason: '三章里已下载的那章不入队');
    expect(jobs.map((MangaDownloadJobRow j) => j.chapterKey).toSet(), <String>{
      '/chapter/2',
      '/chapter/3',
    });
    for (final MangaDownloadJobRow job in jobs) {
      expect(job.status, MangaDownloadJobStatus.queued);
      expect(job.autoOcr, isFalse, reason: '偏好默认 false');
    }

    await tester.runAsync(() async {
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_chapter_download_queued')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_download_all')),
      );
      await _settle(tester);
    });
    jobs = await db.listMangaDownloadJobs();
    expect(jobs, hasLength(2), reason: '已排队的章不重复入队');
  });

  testWidgets('订阅：书签开 → subscribed+autoDownload；菜单关自动下载；书签关两位都关', (
    WidgetTester tester,
  ) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late String bookKey;
    Future<OnlineMangaLibraryEntry> persisted() async {
      final EpubBookRow row = (await db.getEpubBook(bookKey))!;
      return OnlineMangaLibraryEntry.tryParse(row.sourceMetadata)!;
    }

    await tester.runAsync(() async {
      final EpubBookRow row = await library.add(_entry());
      bookKey = row.bookKey;
      await tester.pumpWidget(_harness(appModel, bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      expect(find.byIcon(FushiIcons.bookmarkAdd), findsOneWidget);
      // 没订阅时「⋯」里没有「新章自动下载」。
      await tester.tap(find.byKey(_moreKey));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey<String>('manga_series_auto_download')),
        findsNothing,
      );
      // 点遮罩关菜单。
      await tester.tapAt(const Offset(4, 4));
      await _settle(tester);

      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      await _settle(tester);
    });

    OnlineMangaLibraryEntry entry = await persisted();
    expect(entry.subscribed, isTrue);
    expect(entry.autoDownload, isTrue, reason: '开订阅默认开自动下载');
    expect(find.byIcon(FushiIcons.filled(FushiIcons.bookmark)), findsOneWidget);

    await tester.runAsync(() async {
      await tester.tap(find.byKey(_moreKey));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_auto_download')),
      );
      await _settle(tester);
    });
    entry = await persisted();
    expect(entry.subscribed, isTrue);
    expect(entry.autoDownload, isFalse);

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey<String>('manga_series_subscribe')),
      );
      await _settle(tester);
    });
    entry = await persisted();
    expect(entry.subscribed, isFalse);
    expect(entry.autoDownload, isFalse, reason: '关订阅把两位一起关');
    expect(find.byIcon(FushiIcons.bookmarkAdd), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(_moreKey));
      await _settle(tester);
    });
    expect(
      find.byKey(const ValueKey<String>('manga_series_auto_download')),
      findsNothing,
    );
  });
}
