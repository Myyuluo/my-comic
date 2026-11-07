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
import 'package:fushi/src/media/manga/library/manga_series_page.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import '../../helpers/test_platform_services.dart';

/// Ticket 05/10 的恢复条目：源未安装时 Rebuild 把 `downloads/{source}/{manga}`
/// 降级成指向该文件夹的 Local source 条目。它的文件不在 `localcomic` 根内，
/// 「删除本地文件」必然被 LocalSourceLibrary 拒绝——入口必须隐藏。
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

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
}

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.en);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('manga_series_local_actions_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> insertLocalSourceRow({
    required String title,
    required Directory mangaDir,
    required String relativePath,
  }) async {
    final Directory chapterDir = Directory(p.join(mangaDir.path, 'Ch 1'))
      ..createSync(recursive: true);
    File(p.join(chapterDir.path, '001.jpg')).writeAsBytesSync(<int>[1, 2, 3]);
    final String bookKey = localSourceBookKeyFor(mangaDir.path);
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        epubPath: '',
        extractDir: mangaDir.path,
        chapterCount: 1,
        chaptersJson: encodeLocalSourceChapters(<LocalSourceChapterRecord>[
          const LocalSourceChapterRecord(
            key: 'ch1',
            name: 'Ch 1',
            relativePath: 'Ch 1',
          ),
        ]),
        importedAt: 1,
        format: const Value<String>('manga'),
        sourceMetadata: Value<String>(
          LocalSourceMetadata(relativePath: relativePath).encode(),
        ),
      ),
    );
    return bookKey;
  }

  testWidgets('downloads 根里的恢复条目隐藏「删除本地文件」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory recoveredDir = Directory(
      p.join(paths.downloadsRoot.path, 'Example Source', 'Fixture series'),
    );
    final String bookKey = await insertLocalSourceRow(
      title: 'Fixture series',
      mangaDir: recoveredDir,
      relativePath: 'Example Source/Fixture series',
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_delete_local_files')),
      findsNothing,
      reason: '指向 downloads 的条目不在 localcomic 根内，删除动作必须隐藏',
    );
  });

  testWidgets('localcomic 根里的条目仍显示「删除本地文件」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final Directory localDir = Directory(
      p.join(paths.localComicRoot.path, 'Fixture series'),
    );
    final String bookKey = await insertLocalSourceRow(
      title: 'Fixture series',
      mangaDir: localDir,
      relativePath: 'Fixture series',
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(_harness(_TestAppModel(db, paths, tmp), bookKey));
      await _pumpUntil(
        tester,
        find.byKey(const ValueKey<String>('manga_series_title')),
      );
    });

    expect(
      find.byKey(const ValueKey<String>('manga_series_delete_local_files')),
      findsOneWidget,
      reason: 'localcomic 内的条目仍可显式删除本地文件',
    );
  });
}
