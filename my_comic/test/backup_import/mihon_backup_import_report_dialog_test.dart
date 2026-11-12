import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/backup_import/mihon_backup_import_flow.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/platform/platform_providers.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/utils/components/my_comic_inline_notice.dart';
import 'package:my_comic/src/utils/components/my_comic_m3e_overlays.dart';
import 'package:my_comic/src/utils/components/my_comic_material_components.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_buttons.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/book_storage.dart';
import 'package:my_comic_engine/media/manga/download_library_storage.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart';

import '../helpers/test_platform_services.dart';
import 'mihon_backup_fixture.dart';

/// Page-level seam: the real `.tachibk` import flow ([runMihonBackupImport])
/// against a real Drift database and a synthetic backup fixture. Only the native
/// file picker is faked — widget tests cannot open one.
///
/// Ticket 01: the completion report dialog is a MyComic dialog with a hero header,
/// two grouped cards, warning notice for missing sources and no extra buttons.
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final MyComicDatabase _db;
  final AppPaths _paths;

  @override
  MyComicDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

class _ImportHost extends ConsumerWidget {
  const _ImportHost({required this.appModel});

  final AppModel appModel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => runMihonBackupImport(
            SettingsContext(
              context: context,
              appModel: appModel,
              ref: ref,
              readerSource: ReaderMyComicSource.instance,
              refresh: () {},
            ),
          ),
          child: const Text('import backup'),
        ),
      ),
    );
  }
}

Widget _harness(AppModel appModel) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((Ref ref) => appModel),
  ],
  child: TranslationProvider(
    child: MaterialApp(home: _ImportHost(appModel: appModel)),
  ),
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
}

/// Fixture creation is real file I/O; widget tests run in a fake-async zone, so
/// it must go through [WidgetTester.runAsync] to actually complete.
Future<File> _writeFixtureInTest(
  WidgetTester tester,
  Directory tmp, {
  String name = 'report.tachibk',
}) async {
  final File? backup = await tester.runAsync(
    () => _writeFixture(tmp, name: name),
  );
  return backup!;
}

/// [realIo] lets the import's disk scan (downloads/local manifest probes) run on
/// the real event loop; the fake clock alone never completes those futures.
Future<void> _openReportDialog(
  WidgetTester tester,
  File backup, {
  bool realIo = false,
}) async {
  final Future<String?> Function(String)? previous =
      debugMihonBackupFilePicker;
  String? pickedDirectory;
  debugMihonBackupFilePicker = (String initialDirectory) async {
    pickedDirectory = initialDirectory;
    return backup.path;
  };
  addTearDown(() {
    debugMihonBackupFilePicker = previous;
  });

  await tester.tap(find.text('import backup'));
  if (realIo) {
    await tester.runAsync(() async {
      for (int i = 0; i < 120; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('备份导入完成').evaluate().isNotEmpty) return;
      }
    });
  } else {
    await _pumpUntil(tester, find.text('备份导入完成'));
  }
  await tester.pumpAndSettle();
  expect(pickedDirectory, isNotNull);
  expect(p.basename(pickedDirectory!), 'autobackup');
}

/// Two library entries, one category, one chapter with history, one non-MyComic
/// preference and one extension store. The (`sourceId` 123, 再漫画) source is not
/// installed, so the report must warn about it.
Future<File> _writeFixture(Directory tmp, {String name = 'report.tachibk'}) {
  return writeFixtureBackup(
    tmp,
    name: name,
    sources: const <FixtureSource>[FixtureSource(id: 123, name: '再漫画')],
    categories: const <FixtureCategory>[
      FixtureCategory(name: 'Action', order: 0, id: 10),
    ],
    preferences: const <FixturePreference>[
      FixturePreference(
        key: 'mihon.theme',
        type: FixturePreferenceType.stringValue,
        value: 'dark',
      ),
    ],
    extensionStores: const <FixtureExtensionStore>[
      FixtureExtensionStore(
        indexUrl: 'https://example.test/index.pb',
        name: 'Example',
      ),
    ],
    mangas: const <FixtureManga>[
      FixtureManga(
        source: 123,
        url: '/manga/alpha',
        title: 'Alpha',
        categoryOrders: <int>[0],
        chapters: <FixtureChapter>[
          FixtureChapter(
            url: '/chapter/a1',
            name: 'Chapter 1',
            read: true,
            lastPageRead: 5,
            dateFetch: 1700000000500,
          ),
        ],
        history: <FixtureHistory>[
          FixtureHistory(url: '/chapter/a1', lastRead: 1700000001000),
        ],
      ),
      FixtureManga(
        source: 123,
        url: '/manga/beta',
        title: 'Beta',
        chapters: <FixtureChapter>[
          FixtureChapter(url: '/chapter/b1', name: 'Chapter 1'),
        ],
      ),
    ],
  );
}

void main() {
  late Directory tmp;
  late AppPaths paths;
  late MyComicDatabase db;
  late _TestAppModel appModel;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('mycomic-import-report-');
    AppPaths.debugTestEnvironment = <String, String>{
      'MYCOMIC_TEST_ROOT': tmp.path,
    };
    // The import flow builds its own service with the default book directory.
    EpubStorage.debugBaseDirectoryOverride = tmp.path;
    paths = await AppPaths.resolve();
    db = MyComicDatabase.forTesting(NativeDatabase.memory());
    appModel = _TestAppModel(db, paths);
  });

  tearDown(() async {
    EpubStorage.debugBaseDirectoryOverride = null;
    AppPaths.debugTestEnvironment = null;
    LocaleSettings.setLocale(AppLocale.en);
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  testWidgets(
    'report dialog pads its body, groups the two cards and hides zero diagnostics',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness(appModel));
      await tester.pumpAndSettle();

      final File backup = await _writeFixtureInTest(tester, tmp);
      await _openReportDialog(tester, backup);

      // Hero header: title + processed-total subtitle.
      expect(find.text('备份导入完成'), findsOneWidget);
      expect(find.text('共处理 2 部作品'), findsOneWidget);
      expect(find.byType(MyComicDialogHeroIcon), findsOneWidget);

      // Body padding: the first card is inset from the sheet on both sides.
      final Rect sheet = tester.getRect(find.byType(MyComicModalSheetFrame));
      final Rect card = tester.getRect(find.byType(MyComicCard).first);
      expect(
        card.left - sheet.left,
        greaterThanOrEqualTo(16),
        reason: '正文卡片不能贴在弹窗左边缘',
      );
      expect(
        sheet.right - card.right,
        greaterThanOrEqualTo(16),
        reason: '正文卡片不能贴在弹窗右边缘',
      );

      // Grouping: library card first, settings card second.
      expect(find.text('书架与阅读'), findsOneWidget);
      expect(find.text('设置与来源'), findsOneWidget);
      expect(
        find.text('书架：新增 2，合并 0，跳过 0，失败 0'),
        findsOneWidget,
        reason: '书架主计数始终显示',
      );
      expect(find.textContaining('分类：新建 1，已存在 0'), findsOneWidget);
      expect(find.textContaining('阅读进度：'), findsOneWidget);
      expect(find.textContaining('历史：'), findsOneWidget);
      expect(find.textContaining('应用设置：补齐 0，跳过 1'), findsOneWidget);
      expect(find.textContaining('已跳过的非 MyComic 设置：1'), findsOneWidget);
      expect(find.textContaining('扩展仓库：新增 1'), findsOneWidget);

      final double libraryTop = tester.getTopLeft(find.text('书架与阅读')).dy;
      final double entriesTop = tester
          .getTopLeft(find.text('书架：新增 2，合并 0，跳过 0，失败 0'))
          .dy;
      final double settingsTop = tester.getTopLeft(find.text('设置与来源')).dy;
      final double storesTop = tester
          .getTopLeft(find.textContaining('扩展仓库：新增 1'))
          .dy;
      expect(entriesTop, greaterThan(libraryTop));
      expect(settingsTop, greaterThan(entriesTop));
      expect(storesTop, greaterThan(settingsTop));

      // Zero-only diagnostics stay hidden.
      expect(find.text('已跳过的分类（名称为空）：0'), findsNothing);
      expect(find.text('不在书架（仅阅读记录）：0'), findsNothing);
      expect(find.text('未入架历史：恢复 0，跳过 0'), findsNothing);
      expect(find.text('追踪：新增 0，合并 0，跳过 0'), findsNothing);
      expect(find.text('来源偏好：导入 0，跳过 0'), findsNothing);
      expect(find.textContaining('缺少漫画 URL 的条目：0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('report counts non-library rows and their History', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness(appModel));
    await tester.pumpAndSettle();

    final File backup = (await tester.runAsync(
      () => writeFixtureBackup(
        tmp,
        name: 'non-library.tachibk',
        sources: const <FixtureSource>[FixtureSource(id: 123, name: '再漫画')],
        mangas: const <FixtureManga>[
          FixtureManga(
            source: 123,
            url: '/manga/alpha',
            title: 'Alpha',
            chapters: <FixtureChapter>[
              FixtureChapter(url: '/chapter/a1', name: 'Chapter 1'),
            ],
            history: <FixtureHistory>[
              FixtureHistory(url: '/chapter/a1', lastRead: 1700000001000),
            ],
          ),
          FixtureManga(
            source: 123,
            url: '/manga/beta',
            title: 'Beta',
            favorite: false,
            chapters: <FixtureChapter>[
              FixtureChapter(url: '/chapter/b1', name: 'Chapter 1', read: true),
            ],
            history: <FixtureHistory>[
              FixtureHistory(url: '/chapter/b1', lastRead: 1700000002000),
            ],
          ),
        ],
      ),
    ))!;
    await _openReportDialog(tester, backup);

    expect(find.text('书架：新增 1，合并 0，跳过 0，失败 0'), findsOneWidget);
    expect(find.text('不在书架（仅阅读记录）：1'), findsOneWidget);
    expect(find.text('历史：2 条最近记录'), findsOneWidget);
    expect(find.text('未入架历史：恢复 1，跳过 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'import relinks matching downloads and reports matched/skipped counts',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness(appModel));
      await tester.pumpAndSettle();

      final File backup = (await tester.runAsync(() async {
        final File file = await writeFixtureBackup(
          tmp,
          name: 'downloads-match.tachibk',
          sources: const <FixtureSource>[FixtureSource(id: 123, name: '再漫画')],
          mangas: const <FixtureManga>[
            FixtureManga(
              source: 123,
              url: '/manga/alpha',
              title: 'Alpha',
              chapters: <FixtureChapter>[
                FixtureChapter(url: '/chapter/a1', name: 'Chapter 1'),
                FixtureChapter(url: '/chapter/a2', name: 'Chapter 2'),
              ],
            ),
          ],
        );
        final Directory mangaDir = Directory(
          p.join(paths.downloadsRoot.path, '再漫画', 'Alpha'),
        );
        for (final ({String key, String name, String folder}) chapter
            in <({String key, String name, String folder})>[
              (key: '/chapter/a1', name: 'Chapter 1', folder: 'Chapter 1'),
              (key: '/chapter/a2', name: 'Chapter 2', folder: 'Chapter 2'),
            ]) {
          final Directory chapterDir = Directory(
            p.join(mangaDir.path, chapter.folder),
          );
          await chapterDir.create(recursive: true);
          await File(p.join(chapterDir.path, '001.jpg')).writeAsString('page');
          await writePagesManifestAtomically(
            chapterDir,
            MangaPagesManifest(
              sourceRuntime: 'mihon',
              sourceId: '123',
              sourceName: '再漫画',
              extensionPackage: 'org.example.fixture',
              mangaKey: '/manga/alpha',
              mangaTitle: 'Alpha',
              chapterKey: chapter.key,
              chapterName: chapter.name,
              payload: const MokuroPayload(
                images: <MokuroImage>[
                  MokuroImage(
                    url: '001.jpg',
                    size: MokuroSize(100, 150),
                    blocks: <MokuroBlock>[],
                  ),
                ],
              ),
              downloadedAt: DateTime.utc(2026, 11, 7),
            ),
          );
        }
        return file;
      }))!;
      await _openReportDialog(tester, backup, realIo: true);

      expect(find.text('下载匹配：匹配 1 部，写入 2 章，跳过 0 部'), findsOneWidget);
      final EpubBookRow row = (await db.getAllEpubBooks()).single;
      expect(
        p.equals(
          row.extractDir,
          p.join(paths.downloadsRoot.path, '再漫画', 'Alpha'),
        ),
        isTrue,
      );
      final Map<String, MangaChapterDirRow> mappings = await db
          .getMangaChapterDirRowsForBook(row.bookKey);
      expect(mappings.keys, <String>{'/chapter/a1', '/chapter/a2'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing sources render as a warning notice without actions', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_harness(appModel));
    await tester.pumpAndSettle();

    final File backup = await _writeFixtureInTest(
      tester,
      tmp,
      name: 'missing.tachibk',
    );
    await _openReportDialog(tester, backup);

    expect(find.byType(MyComicInlineNotice), findsOneWidget);
    final MyComicInlineNotice notice = tester.widget<MyComicInlineNotice>(
      find.byType(MyComicInlineNotice),
    );
    expect(notice.severity, MyComicNoticeSeverity.warning);
    expect(notice.actions, isEmpty, reason: '缺失来源提示不得带跳转扩展商店按钮');
    expect(notice.trailing, isNull);
    expect(find.textContaining('缺少来源（1）：再漫画'), findsOneWidget);
    expect(find.textContaining('安装对应扩展后即可阅读'), findsOneWidget);
    expect(find.textContaining('打开扩展商店'), findsNothing);

    // The only action is the footer's 完成 button.
    expect(find.text(t.dialog_done), findsOneWidget);
    expect(find.byType(MyComicFilledButton), findsOneWidget);
  });

  testWidgets(
    'missing sources without backup names use localized wording, not numeric ids',
    (WidgetTester tester) async {
      await tester.pumpWidget(_harness(appModel));
      await tester.pumpAndSettle();

      // The backup references two sources it never names (an old backup shape).
      // The warning must not surface their numeric ids and repeated unknown
      // labels collapse to one.
      final File backup = (await tester.runAsync(
        () => writeFixtureBackup(
          tmp,
          name: 'unknown-sources.tachibk',
          mangas: const <FixtureManga>[
            FixtureManga(source: 123, url: '/manga/a', title: 'A'),
            FixtureManga(source: 456, url: '/manga/b', title: 'B'),
          ],
        ),
      ))!;
      await _openReportDialog(tester, backup);

      expect(find.byType(MyComicInlineNotice), findsOneWidget);
      expect(
        find.textContaining('缺少来源（2）：来源未安装'),
        findsOneWidget,
        reason: '名称缺失时显示本地化的「来源未安装」，并去重重复名称',
      );
      expect(find.textContaining('Source 123'), findsNothing);
      expect(find.textContaining('Source 456'), findsNothing);
      expect(find.textContaining('来源未安装, 来源未安装'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no warning notice when every source is installed', (
    WidgetTester tester,
  ) async {
    await db
        .into(db.mangaOnlineSources)
        .insert(
          MangaOnlineSourcesCompanion.insert(
            extensionPackage: 'com.example.ext',
            sourceId: '123',
            name: '再漫画',
            language: 'zh',
          ),
        );
    await tester.pumpWidget(_harness(appModel));
    await tester.pumpAndSettle();

    final File backup = await _writeFixtureInTest(
      tester,
      tmp,
      name: 'installed.tachibk',
    );
    await _openReportDialog(tester, backup);

    expect(find.byType(MyComicInlineNotice), findsNothing);
    expect(find.textContaining('缺少来源'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('report dialog scrolls instead of overflowing a short window', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 360);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(appModel));
    await tester.pumpAndSettle();

    final File backup = await _writeFixtureInTest(
      tester,
      tmp,
      name: 'short.tachibk',
    );
    await _openReportDialog(tester, backup);

    expect(
      find.descendant(
        of: find.byType(MyComicModalSheetFrame),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
      reason: '正文应只有一层滚动视图',
    );
    expect(tester.takeException(), isNull, reason: '窄窗口不得布局溢出');

    await tester.ensureVisible(find.textContaining('扩展仓库：新增 1'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
