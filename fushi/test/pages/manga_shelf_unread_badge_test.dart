// 漫画书架封面未读角标（ticket 03）。
//
// 用户口径：漫画封面右上角显示未读章节数，0 时隐藏，≥100 显示「99+」，宽度随
// 内容伸展；读到一半（有页码但没有已读标记）也算未读；锁定 / 未下载章同样计入。
// 漫画封面左上角不再显示用户标签 chip，底部进度条保留。在线漫画与本地图源漫画
// 同一规则。从阅读器返回（mediaType.refreshTab）后角标刷新。
//
// 页面级测试：真实 37 表内存库 + 真实页面，只断言用户可见结果，不伸手进私有方法。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show kShelfCoverBadgeDimension, ReaderFushiHistoryPage;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/utils/components/cover_badge.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiTagChip;
import 'package:fushi/src/utils/components/shelf_card_widgets.dart'
    show CoverProgressStrip;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

import '../helpers/test_platform_services.dart';

const String _onlineKey = 'manga_unread_online';
const String _onlineTitle = '在线漫画';
const String _localKey = 'manga_unread_local';
const String _localTitle = '本地图源漫画';
const String _bookKey = 'plain_book';
const String _bookTitle = '普通书';

/// 在线条目：章节目录住在 sourceMetadata 描述符里。
OnlineMangaLibraryEntry _onlineEntry(List<String> chapterKeys) =>
    OnlineMangaLibraryEntry(
      runtime: OnlineMangaRuntimeKind.mihon,
      extensionPackage: 'org.example.fixture',
      sourceId: '1',
      series: const OnlineMangaSeries(
        key: '/series/fixture',
        title: _onlineTitle,
        raw: <String, Object?>{'url': '/series/fixture'},
      ),
      chapters: <OnlineMangaChapter>[
        for (final String key in chapterKeys)
          OnlineMangaChapter(
            key: key,
            name: key,
            raw: <String, Object?>{'url': key},
          ),
      ],
      currentChapterIndex: chapterKeys.isEmpty ? null : 0,
    );

MediaItem _mangaItem(String bookKey, String title) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
  title: title,
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: MangaFushiSource.kUniqueKey,
  position: 0,
  duration: 100,
  canDelete: false,
  canEdit: true,
);

MediaItem _plainBookItem(String bookKey, String title) => MediaItem(
  mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
  title: title,
  mediaTypeIdentifier: ReaderMediaType.instance.uniqueKey,
  mediaSourceIdentifier: ReaderFushiSource.instance.uniqueKey,
  position: 0,
  duration: 100,
  canDelete: false,
  canEdit: true,
);

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_manga_unread_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });

  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late AppModel appModel;
  late PreferencesRepository prefs;
  late Directory storeDir;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_manga_unread_store');
    appModel = AppModel(testPlatformServices())
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    appModel.populateLanguages();
    appModel.populateMediaTypes();
    appModel.populateMediaSources();
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      try {
        storeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  /// 插入一部在线漫画（chaptersJson 留空，章节身份只在描述符里）。
  Future<EpubBookRow> insertOnlineManga(List<String> chapterKeys) async {
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _onlineKey,
        title: _onlineTitle,
        epubPath: '/tmp/$_onlineKey',
        extractDir: '/tmp/$_onlineKey',
        chapterCount: chapterKeys.length,
        chaptersJson: '[]',
        sourceMetadata: Value<String?>(_onlineEntry(chapterKeys).encode()),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  /// 插入一部本地图源漫画：章节目录住在 chaptersJson 里。
  Future<EpubBookRow> insertLocalSourceManga(List<String> chapterKeys) async {
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _localKey,
        title: _localTitle,
        epubPath: '',
        extractDir: '/tmp/$_localKey',
        chapterCount: chapterKeys.length,
        chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          for (final String key in chapterKeys)
            LocalSourceChapterRecord(key: key, name: key, relativePath: key),
        ]),
        sourceMetadata: Value<String?>(
          const LocalSourceMetadata(relativePath: 'manga/local').encode(),
        ),
        importedAt: 0,
        format: const Value<String>('manga'),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  /// 插入一本普通 EPUB 书，用来守卫非漫画卡行为不变。
  Future<EpubBookRow> insertPlainBook() async {
    final String bookKey = await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: _bookKey,
        title: _bookTitle,
        epubPath: '/tmp/$_bookKey.epub',
        extractDir: '/tmp/$_bookKey',
        chapterCount: 1,
        chaptersJson: '["a"]',
        importedAt: 0,
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  Widget buildApp(List<MediaItem> items, {bool mangaOnly = true}) =>
      ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(testPlatformServices()),
          appProvider.overrideWith((ref) => appModel),
          fushiBooksProvider.overrideWith(
            (ref, language) => Future<List<MediaItem>>.value(items),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ReaderFushiHistoryPage(
                mangaOnly: mangaOnly,
              ),
            ),
          ),
        ),
      );

  /// 让真实异步（DB 读、书架映射）落地；fake 时钟推不动它们。
  Future<void> pumpRealAsync(WidgetTester tester, {int steps = 40}) async {
    await tester.runAsync(() async {
      for (int i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
  }

  Future<void> pumpShelf(
    WidgetTester tester,
    List<MediaItem> items, {
    bool mangaOnly = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1400, 1400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp(items, mangaOnly: mangaOnly));
    await pumpRealAsync(tester);
  }

  CoverBadge? badgeOf(WidgetTester tester, String bookKey) {
    final Finder finder = find.byKey(
      ValueKey<String>('manga_unread_badge_$bookKey'),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<CoverBadge>(finder);
  }

  testWidgets('在线漫画：未读数按章已读标记计算，读到一半的章仍算未读', (WidgetTester tester) async {
    late int tagId;
    final EpubBookRow row =
        await tester.runAsync(() async {
              final EpubBookRow row = await insertOnlineManga(<String>[
                '/chapter/3',
                '/chapter/2',
                '/chapter/1',
              ]);
              // 已读完 /chapter/3；/chapter/2 只读到第 5 页（没有 readAt）——仍算未读。
              await db.markMangaChaptersRead(
                bookUid: row.uid,
                chapterKeys: <String>['/chapter/3'],
              );
              await db.saveMangaChapterState(
                bookUid: row.uid,
                chapterKey: '/chapter/2',
                lastPage: 5,
              );
              tagId = await db.createTag('收藏', 0xFF112233);
              await db.addTagToBook(_onlineKey, tagId);
              return row;
            })
            as EpubBookRow;
    expect(row.uid.isNotEmpty, isTrue);

    await pumpShelf(tester, <MediaItem>[_mangaItem(_onlineKey, _onlineTitle)]);

    // Ticket 01：有用户标签的漫画只出现在对应标签页签下，「书架」只收无标签漫画。
    await tester.tap(
      find.byKey(ValueKey<String>('manga_tag_tab_$tagId')),
    );
    await tester.pumpAndSettle();

    final CoverBadge? badge = badgeOf(tester, _onlineKey);
    expect(badge, isNotNull, reason: '有未读章时必须渲染角标');
    expect(badge!.label, '2', reason: '已读 1 章、读到一半 1 章 + 完全未读 1 章');

    // 漫画封面左上角不再显示用户标签 chip（标签仍在页签栏里）。
    final Finder card = find.byKey(
      ValueKey<String>(
        'book_entry_${_mangaItem(_onlineKey, _onlineTitle).mediaIdentifier}',
      ),
    );
    expect(
      find.descendant(of: card, matching: find.byType(FushiTagChip)),
      findsNothing,
      reason: '漫画封面左上角不再渲染标签 chip',
    );
    expect(
      find.descendant(of: card, matching: find.byType(CoverProgressStrip)),
      findsOneWidget,
      reason: '封面底部阅读进度条保留',
    );
  });

  testWidgets('未读数为 0 时整个角标不渲染', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final EpubBookRow row = await insertOnlineManga(<String>[
        '/chapter/2',
        '/chapter/1',
      ]);
      await db.markMangaChaptersRead(
        bookUid: row.uid,
        chapterKeys: <String>['/chapter/2', '/chapter/1'],
      );
    });

    await pumpShelf(tester, <MediaItem>[_mangaItem(_onlineKey, _onlineTitle)]);

    expect(find.text(_onlineTitle), findsWidgets, reason: '卡片本身仍渲染');
    expect(badgeOf(tester, _onlineKey), isNull, reason: '0 未读时角标完全不显示');
  });

  testWidgets('未读数 ≥100 显示「99+」，且角标宽度随内容伸展', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await insertOnlineManga(<String>[
        for (int i = 0; i < 100; i++) '/chapter/$i',
      ]);
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'manga_unread_short',
          title: '少量未读',
          epubPath: '/tmp/manga_unread_short',
          extractDir: '/tmp/manga_unread_short',
          chapterCount: 5,
          chaptersJson: '[]',
          sourceMetadata: Value<String?>(
            _onlineEntry(<String>[
              for (int i = 0; i < 5; i++) '/short/$i',
            ]).encode(),
          ),
          importedAt: 0,
          format: const Value<String>('manga'),
        ),
      );
    });

    await pumpShelf(tester, <MediaItem>[
      _mangaItem(_onlineKey, _onlineTitle),
      _mangaItem('manga_unread_short', '少量未读'),
    ]);

    final CoverBadge? longBadge = badgeOf(tester, _onlineKey);
    final CoverBadge? shortBadge = badgeOf(tester, 'manga_unread_short');
    expect(longBadge?.label, '99+', reason: '≥100 封顶显示 99+');
    expect(shortBadge?.label, '5');

    final Size longSize = tester.getSize(
      find.byKey(const ValueKey<String>('manga_unread_badge_$_onlineKey')),
    );
    final Size shortSize = tester.getSize(
      find.byKey(
        const ValueKey<String>('manga_unread_badge_manga_unread_short'),
      ),
    );
    expect(
      longSize.width,
      greaterThan(shortSize.width),
      reason: '三位数角标必须比一位数更宽（宽度随内容伸展）',
    );
    expect(
      longSize.width,
      greaterThan(kShelfCoverBadgeDimension),
      reason: '不再受原有固定方形尺寸限制',
    );
  });

  testWidgets('本地图源漫画同样按章已读标记计算未读数', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final EpubBookRow row = await insertLocalSourceManga(<String>[
        'vol/1',
        'vol/2',
      ]);
      await db.markMangaChaptersRead(
        bookUid: row.uid,
        chapterKeys: <String>['vol/1'],
      );
    });

    await pumpShelf(tester, <MediaItem>[_mangaItem(_localKey, _localTitle)]);

    expect(
      badgeOf(tester, _localKey)?.label,
      '1',
      reason: '本地图源章节目录来自 chaptersJson',
    );
  });

  testWidgets('从阅读器返回（refreshTab）后未读数刷新', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final EpubBookRow row = await insertOnlineManga(<String>[
        '/chapter/2',
        '/chapter/1',
      ]);
      // 先只读完第一章 → 角标应为 1。
      await db.markMangaChaptersRead(
        bookUid: row.uid,
        chapterKeys: <String>['/chapter/2'],
      );
    });

    await pumpShelf(tester, <MediaItem>[_mangaItem(_onlineKey, _onlineTitle)]);
    expect(badgeOf(tester, _onlineKey)?.label, '1');

    // 模拟在作品页 / 阅读器里读完剩下的章，然后走阅读器关闭时的同一刷新信号。
    await tester.runAsync(() async {
      final EpubBookRow row = (await db.getEpubBook(_onlineKey))!;
      await db.markMangaChaptersRead(
        bookUid: row.uid,
        chapterKeys: <String>['/chapter/1'],
      );
    });
    ReaderMediaType.instance.refreshTab();
    await pumpRealAsync(tester);

    expect(badgeOf(tester, _onlineKey), isNull, reason: '全部读完返回书架后角标消失');
  });

}
