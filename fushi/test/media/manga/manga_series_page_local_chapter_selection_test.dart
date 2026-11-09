import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/pump_until.dart';
import '../../helpers/test_platform_services.dart';

/// Ticket 05：本地图源章节同样可以批量标记已读 / 未读（章级状态由 ticket 02
/// 的 `manga_chapter_states` 提供）。真实内存库 + 真实本地图源章节文件。

class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths, Directory root)
    : super(testPlatformServices()) {
    wireLocalAudioForTesting(
      prefsRepo: PreferencesRepository(_db),
      databaseDirectory: root,
    );
  }

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;

  @override
  Directory get temporaryDirectory => _paths.cacheRoot;

  @override
  double get appUiScale => 1.0;
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

const List<String> _chapterNames = <String>['Ch 1', 'Ch 2', 'Ch 3'];

Finder _chapterRow(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(MediaDetailItemRow),
);

void main() {
  late Directory tmp;
  late AppPaths paths;
  late Directory mangaDir;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    // 数据库在 setUp（与页面操作同一 async zone）里建：页面在 fake 时钟下发的
    // 批量写库不能跨 zone 等一个在 `runAsync` 里创建的 drift executor。
    tmp = Directory.systemTemp.createTempSync('manga_local_selection_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    mangaDir = Directory(p.join(paths.localComicRoot.path, 'Fixture Series'))
      ..createSync(recursive: true);
    for (final String name in _chapterNames) {
      final Directory dir = Directory(p.join(mangaDir.path, name))
        ..createSync(recursive: true);
      File(p.join(dir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    }
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void sizeView(WidgetTester tester) {
    tester.view.physicalSize = const Size(600, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<EpubBookRow> insertLocalSourceRow() async {
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: 'Fixture Series',
        epubPath: '',
        extractDir: mangaDir.path,
        chapterCount: 3,
        chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          for (final String name in _chapterNames)
            LocalSourceChapterRecord(key: name, name: name, relativePath: name),
        ]),
        importedAt: 0,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(relativePath: 'Fixture Series').encode(),
        ),
      ),
    );
    return (await db.getEpubBook(bookKey))!;
  }

  testWidgets('本地图源章节可批量标记已读 / 未读，只写章级 readAt', (WidgetTester tester) async {
    sizeView(tester);
    final EpubBookRow row = await insertLocalSourceRow();
    late AppModel appModel;
    await tester.runAsync(() async {
      appModel = _TestAppModel(db, paths, tmp);
      await tester.pumpWidget(_harness(appModel, row.bookKey));
      await pumpUntilFound(tester, find.text('Ch 1'));
    });

    await tester.longPress(_chapterRow('Ch 1'));
    await tester.tap(_chapterRow('Ch 2'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester
          .widget<FushiIconButton>(
            find.byKey(const ValueKey<String>('manga_series_batch_mark_read')),
          )
          .enabled,
      isTrue,
      reason: '本地图源章节也能批量标记已读',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('manga_series_batch_mark_read')),
    );
    // 批量写库链在 fake 时钟下推进；先推几帧把 write + reload 跑完。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      for (int i = 0; i < 100; i++) {
        final MangaChapterStateRow? first = await db.getMangaChapterState(
          bookUid: row.uid,
          chapterKey: 'Ch 1',
        );
        final MangaChapterStateRow? second = await db.getMangaChapterState(
          bookUid: row.uid,
          chapterKey: 'Ch 2',
        );
        if (first?.readAt != null && second?.readAt != null) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('等待本地图源章节已读状态超时');
    });
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'Ch 1',
      ))!.readAt,
      isNotNull,
    );
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'Ch 2',
      ))!.readAt,
      isNotNull,
    );
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'Ch 3',
      ))?.readAt,
      isNull,
      reason: '未选中的本地章节不受影响',
    );
    expect(
      (await db.getEpubBook(row.bookKey))!.completedAt,
      isNull,
      reason: '批量已读不改书级完成标记',
    );

    // 批量未读：只清章级 readAt。
    await tester.tap(
      find.byKey(const ValueKey<String>('manga_series_batch_mark_unread')),
    );
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() async {
      for (int i = 0; i < 100; i++) {
        final MangaChapterStateRow? first = await db.getMangaChapterState(
          bookUid: row.uid,
          chapterKey: 'Ch 1',
        );
        if (first?.readAt == null) return;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      fail('等待本地图源章节未读状态超时');
    });
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'Ch 1',
      ))!.readAt,
      isNull,
    );
    expect(
      (await db.getMangaChapterState(
        bookUid: row.uid,
        chapterKey: 'Ch 2',
      ))!.readAt,
      isNull,
    );
  });
}
