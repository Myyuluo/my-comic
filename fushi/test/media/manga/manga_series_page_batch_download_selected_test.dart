import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 08（manga-download-materialization）的页面级证据：多选批量栏的
/// 「下载选中章节」。真实 37 表内存库 + 真实作品页 + 真实下载服务（worker 未
/// 启动，任务停在 queued）；在线 Source 用可控 fake。只断言用户可见行为、任务表
/// 与章节行下载状态。

class _FakeAdapter implements OnlineMangaRuntimeAdapter {
  _FakeAdapter({this.label = 'Fake'});

  /// null = 来源未安装 / 停用（运行时解析不到来源）。
  final String? label;

  @override
  OnlineMangaRuntimeKind get kind => OnlineMangaRuntimeKind.mihon;

  @override
  bool get isSupportedOnThisPlatform => true;

  @override
  Future<String?> sourceLabel(OnlineMangaLibraryEntry entry) async => label;

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
  }) async {}
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
    key: '/chapter/4',
    name: 'Chapter 4',
    number: 4,
    raw: <String, Object?>{'url': '/chapter/4'},
  ),
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

OnlineMangaLibraryEntry _entry({bool lockedChapter3 = false}) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: 'Fixture series',
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[
        for (final OnlineMangaChapter chapter in _chapters)
          if (lockedChapter3 && chapter.key == '/chapter/3')
            OnlineMangaChapter(
              key: chapter.key,
              name: chapter.name,
              number: chapter.number,
              locked: true,
              raw: chapter.raw,
            )
          else
            chapter,
      ],
    );

/// 在 Download library 里放一章完整下载（章目录 + pages.json + 页图 + 映射行）。
Future<void> _writeDownloadedChapter(
  FushiDatabase db,
  String bookKey,
  String bookDir,
  String chapterKey,
  String chapterName,
) async {
  final Directory chapterDir = downloadChapterDirectory(bookDir, chapterName);
  await chapterDir.create(recursive: true);
  await File(p.join(chapterDir.path, '001.jpg')).writeAsBytes(<int>[1]);
  await writePagesManifestAtomically(
    chapterDir,
    MangaPagesManifest(
      sourceRuntime: 'mihon',
      sourceId: '1',
      sourceName: 'Fake',
      extensionPackage: 'org.example.fixture',
      mangaKey: '/series/fixture',
      mangaTitle: 'Fixture series',
      chapterKey: chapterKey,
      chapterName: chapterName,
      payload: const MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: '001.jpg',
            size: MokuroSize(100, 150),
            blocks: <MokuroBlock>[],
          ),
        ],
      ),
      downloadedAt: DateTime.utc(2026, 11, 8),
    ),
  );
  await db.upsertMangaChapterDir(
    bookKey: bookKey,
    chapterKey: chapterKey,
    folderName: chapterName,
    updatedAt: 1,
  );
}

Future<void> _insertJob(
  FushiDatabase db, {
  required String bookKey,
  required String chapterKey,
  required String status,
}) => db.upsertMangaDownloadJob(
  MangaDownloadJobsCompanion.insert(
    jobId: 'job-$chapterKey',
    kind: MangaDownloadJobKind.chapter,
    bookKey: bookKey,
    chapterKey: chapterKey,
    runtime: 'mihon',
    title: 'Fixture series',
    chapterTitle: chapterKey,
    status: Value<String>(status),
    pagesDone: const Value<int>(0),
    pagesTotal: const Value<int>(0),
    attemptCount: const Value<int>(0),
    autoOcr: const Value<bool>(false),
    createdAt: 1,
    updatedAt: 1,
  ),
);

const ValueKey<String> _downloadSelectedKey = ValueKey<String>(
  'manga_series_batch_download_selected',
);
const ValueKey<String> _markReadKey = ValueKey<String>(
  'manga_series_batch_mark_read',
);
const ValueKey<String> _markUnreadKey = ValueKey<String>(
  'manga_series_batch_mark_unread',
);
const ValueKey<String> _deleteDownloadsKey = ValueKey<String>(
  'manga_series_batch_delete_downloads',
);

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

MediaDetailItemRow _rowWidget(WidgetTester tester, String title) =>
    tester.widget<MediaDetailItemRow>(_chapterRow(title));

bool _enabled(WidgetTester tester, ValueKey<String> key) =>
    tester.widget<FushiIconButton>(find.byKey(key)).enabled;

/// 推进弹簧 / 进场 / 批量栏动画。手势在 fake clock 下驱动。
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 交替让真实事件循环跑一步（runAsync）与推帧：FakeAsync 区里 await 文件 /
/// 数据库 IO 不会自己结束，IO 的续体又排回 fake zone，只能一轮一轮推进。
Future<void> _advanceUntil(WidgetTester tester, bool Function() done) async {
  for (int i = 0; i < 400; i++) {
    await tester.pump(const Duration(milliseconds: 10));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    if (!done()) continue;
    // 收尾：任务表监听可能再触发一轮磁盘扫描；让文件读取完全结束再交给
    // tearDown，否则 Windows 上仍在打开的 pages.json 会挡住临时目录删除。
    for (int j = 0; j < 40; j++) {
      await tester.pump(const Duration(milliseconds: 10));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
    }
    await _settle(tester);
    return;
  }
  fail('等待批量下载完成超时');
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late OnlineMangaLibraryService library;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    root = await Directory.systemTemp.createTemp('manga_batch_download_');
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
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('批量栏在标记未读与删除下载之间提供下载动作，对可下载选中章可用', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);
    });

    await tester.longPress(_chapterRow('Chapter 2'));
    await _settle(tester);

    expect(find.byKey(_downloadSelectedKey), findsOneWidget);
    expect(
      _enabled(tester, _downloadSelectedKey),
      isTrue,
      reason: '选中的在线未下载章可批量下载',
    );
    expect(
      tester.widget<FushiIconButton>(find.byKey(_downloadSelectedKey)).icon,
      FushiIcons.download,
      reason: '动作使用下载图标',
    );
    expect(
      tester
          .widget<BatchActionBar>(find.byType(BatchActionBar))
          .actions
          .map((Widget action) => action.key)
          .toList(),
      <Key?>[
        _markReadKey,
        _markUnreadKey,
        _downloadSelectedKey,
        _deleteDownloadsKey,
      ],
      reason: '下载动作位于「标记未读」与「删除下载」之间',
    );
  });

  testWidgets('只入队选中章，按旧→新入队且不弹确认，章节行立即显示排队', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.add(_entry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);
    });

    // 选中最旧的第 1 章与最新的第 3 章；第 2 章不选。
    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    await tester.tap(_chapterRow('Chapter 3'));
    await _settle(tester);

    await tester.tap(find.byKey(_downloadSelectedKey));
    await _advanceUntil(tester, () {
      return _rowWidget(tester, 'Chapter 1').downloadState ==
              MediaDetailDownloadState.queued &&
          _rowWidget(tester, 'Chapter 3').downloadState ==
              MediaDetailDownloadState.queued;
    });

    // 不弹二次确认：入队直接发生。
    expect(find.byType(AlertDialog), findsNothing);

    final MangaDownloadJobRow? first = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: row.bookKey,
      chapterKey: '/chapter/1',
    );
    final MangaDownloadJobRow? third = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: row.bookKey,
      chapterKey: '/chapter/3',
    );
    final MangaDownloadJobRow? unselected = await db.findMangaDownloadJob(
      kind: MangaDownloadJobKind.chapter,
      bookKey: row.bookKey,
      chapterKey: '/chapter/2',
    );
    expect(first?.status, MangaDownloadJobStatus.queued);
    expect(third?.status, MangaDownloadJobStatus.queued);
    expect(unselected, isNull, reason: '未选中的第 2 章不得入队');
    expect(
      first!.createdAt,
      lessThan(third!.createdAt),
      reason: '与「下载全部」一致：旧→新入队（第 1 章先于第 3 章）',
    );

    // 章节行与下载状态立即刷新：选中的显示排队，未选中的仍是未下载。
    expect(
      _rowWidget(tester, 'Chapter 1').downloadState,
      MediaDetailDownloadState.queued,
    );
    expect(
      _rowWidget(tester, 'Chapter 3').downloadState,
      MediaDetailDownloadState.queued,
    );
    expect(
      _rowWidget(tester, 'Chapter 2').downloadState,
      MediaDetailDownloadState.none,
    );
  });

  testWidgets('已下载、排队中与锁定章都不入队；无适用项置灰，混合选择只处理子集', (WidgetTester tester) async {
    sizeView(tester);
    final _TestAppModel appModel = _TestAppModel(db, library, root);
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await library.add(_entry(lockedChapter3: true));
      await _writeDownloadedChapter(
        db,
        row.bookKey,
        row.extractDir,
        '/chapter/1',
        'Chapter 1',
      );
      await _insertJob(
        db,
        bookKey: row.bookKey,
        chapterKey: '/chapter/2',
        status: MangaDownloadJobStatus.queued,
      );
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await _settle(tester);
    });

    // 已下载 → 置灰。
    await tester.longPress(_chapterRow('Chapter 1'));
    await _settle(tester);
    expect(
      _enabled(tester, _downloadSelectedKey),
      isFalse,
      reason: '已下载章不参与批量下载',
    );

    // 加选排队中的章 → 仍置灰。
    await tester.tap(_chapterRow('Chapter 2'));
    await _settle(tester);
    expect(
      _enabled(tester, _downloadSelectedKey),
      isFalse,
      reason: '排队中 / 下载中的章不重复入队',
    );

    // 加选锁定章 → 仍置灰（锁定章入队必败）。
    await tester.tap(_chapterRow('Chapter 3'));
    await _settle(tester);
    expect(_enabled(tester, _downloadSelectedKey), isFalse, reason: '锁定章不算适用项');

    // 加选未下载且可下载的第 4 章 → 动作可用；混合选择只处理它。
    await tester.tap(_chapterRow('Chapter 4'));
    await _settle(tester);
    expect(_enabled(tester, _downloadSelectedKey), isTrue);

    await tester.tap(find.byKey(_downloadSelectedKey));
    await _advanceUntil(tester, () {
      return _rowWidget(tester, 'Chapter 4').downloadState ==
          MediaDetailDownloadState.queued;
    });

    expect(
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: row.bookKey,
        chapterKey: '/chapter/4',
      ))?.status,
      MangaDownloadJobStatus.queued,
    );
    expect(
      await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: row.bookKey,
        chapterKey: '/chapter/3',
      ),
      isNull,
      reason: '锁定章不入队',
    );
    expect(
      await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: row.bookKey,
        chapterKey: '/chapter/1',
      ),
      isNull,
      reason: '已下载章不重复入队',
    );
    expect(
      (await db.findMangaDownloadJob(
        kind: MangaDownloadJobKind.chapter,
        bookKey: row.bookKey,
        chapterKey: '/chapter/2',
      ))!.createdAt,
      1,
      reason: '排队中的章保持原任务，不被重新入队',
    );

    // 行状态：已下载 / 排队保持，锁定章未下载，适用章已排队。
    expect(
      _rowWidget(tester, 'Chapter 1').downloadState,
      MediaDetailDownloadState.downloaded,
    );
    expect(
      _rowWidget(tester, 'Chapter 2').downloadState,
      MediaDetailDownloadState.queued,
    );
    expect(
      _rowWidget(tester, 'Chapter 3').downloadState,
      MediaDetailDownloadState.none,
    );
    expect(
      _rowWidget(tester, 'Chapter 4').downloadState,
      MediaDetailDownloadState.queued,
    );
  });

  testWidgets('来源未安装时下载动作置灰', (WidgetTester tester) async {
    sizeView(tester);
    final OnlineMangaLibraryService missingSourceLibrary =
        OnlineMangaLibraryService(
          database: db,
          rootDirectory: Directory(p.join(root.path, 'legacy')),
          adapter: _FakeAdapter(label: null),
        );
    final _TestAppModel appModel = _TestAppModel(
      db,
      missingSourceLibrary,
      root,
    );
    late EpubBookRow row;
    await tester.runAsync(() async {
      row = await missingSourceLibrary.add(_entry());
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Chapter 1'));
      await pumpUntilFound(
        tester,
        find.byKey(
          const ValueKey<String>('manga_series_missing_source_notice'),
        ),
      );
      await _settle(tester);
    });

    await tester.longPress(_chapterRow('Chapter 4'));
    await _settle(tester);

    expect(find.byKey(_downloadSelectedKey), findsOneWidget);
    expect(
      _enabled(tester, _downloadSelectedKey),
      isFalse,
      reason: '来源未安装时不能发起在线下载',
    );
  });
}
