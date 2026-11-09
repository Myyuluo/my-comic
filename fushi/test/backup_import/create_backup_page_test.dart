import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/backup_export/mihon_backup_exporter.dart';
import 'package:fushi/src/pages/implementations/create_backup_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// Page-level seam: the real [CreateBackupPage] with a real Drift database and
/// real preferences. Only the native save dialog is injected — widget tests
/// cannot open one.
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

Widget _harness(AppModel appModel, Widget page) => ProviderScope(
  overrides: <Override>[
    platformServicesProvider.overrideWithValue(testPlatformServices()),
    appProvider.overrideWith((Ref ref) => appModel),
  ],
  child: TranslationProvider(child: MaterialApp(home: page)),
);

Future<void> _pumpUntil(WidgetTester tester, Finder finder) async {
  for (int i = 0; i < 80; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
}

FushiCheckboxListTile _tile(WidgetTester tester, Key key) =>
    tester.widget<FushiCheckboxListTile>(find.byKey(key));

/// The 设置 group sits below the 书架 group; scroll it above the fixed 创建
/// button so its rows can receive taps.
Future<void> _scrollToSettings(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await tester.pumpAndSettle();
}

void main() {
  late Directory tmp;
  late AppPaths paths;
  late FushiDatabase db;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = await Directory.systemTemp.createTemp('mycomic-create-backup-');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    paths = await AppPaths.resolve();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    LocaleSettings.setLocale(AppLocale.en);
    await db.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  testWidgets('starts with library + chapters selected and resets each open', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
    await tester.pumpAndSettle();

    expect(find.text('创建备份'), findsOneWidget);
    // Group titles also appear in the jump bar / floating header subtitle.
    expect(find.text('书架'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
    expect(find.text('书架中的作品'), findsOneWidget);
    expect(find.text('章节'), findsOneWidget);
    expect(
      _tile(tester, const Key('create_backup_include_library')).value,
      isTrue,
    );
    expect(
      _tile(tester, const Key('create_backup_include_chapters')).value,
      isTrue,
    );
    expect(
      tester
          .widget<FushiCheckboxListTile>(
            find.byKey(const Key('create_backup_include_chapters')),
          )
          .enabled,
      isNot(false),
      reason: 'chapters follow the library default',
    );
    final FushiFilledButton createButton = tester.widget<FushiFilledButton>(
      find.byKey(const Key('create_backup_create')),
    );
    expect(createButton.onPressed, isNotNull);

    // Re-open with a fresh page: the disabled/edited state is not remembered.
    await tester.tap(find.byKey(const Key('create_backup_include_library')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _harness(
        appModel,
        const CreateBackupPage(key: ValueKey<String>('reopened')),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _tile(tester, const Key('create_backup_include_library')).value,
      isTrue,
    );
  });

  testWidgets('history and all-read default on and follow the library option', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
    await tester.pumpAndSettle();

    expect(find.text('历史'), findsOneWidget);
    expect(find.text('所有已读作品'), findsOneWidget);
    expect(
      _tile(tester, const Key('create_backup_include_history')).value,
      isTrue,
    );
    expect(
      _tile(tester, const Key('create_backup_include_all_read')).value,
      isTrue,
    );
    expect(
      _tile(tester, const Key('create_backup_include_history')).enabled,
      isNot(false),
    );
    expect(
      _tile(tester, const Key('create_backup_include_all_read')).enabled,
      isNot(false),
    );

    await tester.tap(find.byKey(const Key('create_backup_include_library')));
    await tester.pumpAndSettle();
    expect(
      _tile(tester, const Key('create_backup_include_history')).enabled,
      isFalse,
      reason: '历史 cannot be exported without 书架中的作品',
    );
    expect(
      _tile(tester, const Key('create_backup_include_all_read')).enabled,
      isFalse,
      reason: '所有已读作品 cannot be exported without 书架中的作品',
    );

    await tester.tap(find.byKey(const Key('create_backup_include_library')));
    await tester.pumpAndSettle();
    expect(
      _tile(tester, const Key('create_backup_include_history')).enabled,
      isNot(false),
    );
    expect(
      _tile(tester, const Key('create_backup_include_all_read')).enabled,
      isNot(false),
    );
  });

  testWidgets('app settings default on and sensitive settings default off', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
    await tester.pumpAndSettle();
    await _scrollToSettings(tester);

    expect(find.text('应用设置'), findsOneWidget);
    expect(find.text('包含敏感设置'), findsOneWidget);
    expect(
      _tile(tester, const Key('create_backup_include_app_settings')).value,
      isTrue,
    );
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).value,
      isFalse,
    );
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).enabled,
      isNot(false),
      reason: 'sensitive settings are available while app settings are on',
    );

    // Re-opening the page restores the defaults; the sensitive tick is not
    // remembered. The row sits below the fold once every section row is shown,
    // so scroll the list before tapping it.
    await _scrollToSettings(tester);
    await tester.tap(
      find.byKey(const Key('create_backup_include_sensitive_settings')),
    );
    await tester.pumpAndSettle();
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).value,
      isTrue,
    );
    await tester.pumpWidget(
      _harness(
        appModel,
        const CreateBackupPage(key: ValueKey<String>('reopened-settings')),
      ),
    );
    await tester.pumpAndSettle();
    await _scrollToSettings(tester);
    expect(
      _tile(tester, const Key('create_backup_include_app_settings')).value,
      isTrue,
    );
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).value,
      isFalse,
    );
  });

  testWidgets('sensitive settings require app settings to be selected', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
    await tester.pumpAndSettle();

    await _scrollToSettings(tester);
    await tester.tap(
      find.byKey(const Key('create_backup_include_app_settings')),
    );
    await tester.pumpAndSettle();
    expect(
      _tile(tester, const Key('create_backup_include_app_settings')).value,
      isFalse,
    );
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).enabled,
      isFalse,
      reason: 'sensitive settings need app settings or source settings',
    );

    await tester.tap(
      find.byKey(const Key('create_backup_include_app_settings')),
    );
    await tester.pumpAndSettle();
    expect(
      _tile(
        tester,
        const Key('create_backup_include_sensitive_settings'),
      ).enabled,
      isNot(false),
    );
  });

  testWidgets(
    'app settings count as exportable content for the create button',
    (WidgetTester tester) async {
      final _TestAppModel appModel = _TestAppModel(db, paths);
      await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('create_backup_include_library')));
      await tester.tap(
        find.byKey(const Key('create_backup_include_categories')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNotNull,
        reason: 'app settings alone are still worth exporting',
      );

      await _scrollToSettings(tester);
      await tester.tap(
        find.byKey(const Key('create_backup_include_app_settings')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNull,
        reason: 'nothing selectable remains',
      );

      await tester.tap(
        find.byKey(const Key('create_backup_include_app_settings')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'created backup passes the app settings selection to the exporter',
    (WidgetTester tester) async {
      final _TestAppModel appModel = _TestAppModel(db, paths);
      final _CapturingOptionsExporter exporter = _CapturingOptionsExporter(
        database: db,
      );
      final String targetPath = p.join(tmp.path, 'options.tachibk');

      await tester.pumpWidget(
        _harness(
          appModel,
          CreateBackupPage(
            exporter: exporter,
            savePathPicker:
                ({
                  required String initialDirectory,
                  required String fileName,
                }) async => targetPath,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToSettings(tester);
      await tester.tap(
        find.byKey(const Key('create_backup_include_sensitive_settings')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create_backup_create')));
      await tester.pumpAndSettle();

      expect(exporter.options, isNotNull);
      expect(exporter.options!.includeAppSettings, isTrue);
      expect(exporter.options!.includeSensitiveSettings, isTrue);
    },
  );

  testWidgets(
    'unchecking「书架中的作品」disables chapters but keeps standalone sections',
    (WidgetTester tester) async {
      final _TestAppModel appModel = _TestAppModel(db, paths);
      await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('create_backup_include_library')));
      await tester.pumpAndSettle();

      expect(
        _tile(tester, const Key('create_backup_include_library')).value,
        isFalse,
      );
      expect(
        _tile(tester, const Key('create_backup_include_chapters')).enabled,
        isFalse,
        reason: '章节 cannot be exported without 书架中的作品',
      );
      expect(
        _tile(tester, const Key('create_backup_include_categories')).enabled,
        isNot(false),
        reason: '分类 is independent of 书架中的作品',
      );
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNotNull,
        reason: '分类 alone keeps 创建 available',
      );

      await tester.tap(
        find.byKey(const Key('create_backup_include_categories')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNotNull,
        reason: '应用设置 is still selected',
      );

      await _scrollToSettings(tester);
      await tester.tap(
        find.byKey(const Key('create_backup_include_app_settings')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNull,
        reason: 'nothing exportable → 创建 is greyed out',
      );

      // Scroll back up to the 书架 group before re-enabling it.
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create_backup_include_library')));
      await tester.pumpAndSettle();
      expect(
        _tile(tester, const Key('create_backup_include_chapters')).enabled,
        isNot(false),
      );
      expect(
        tester
            .widget<FushiFilledButton>(
              find.byKey(const Key('create_backup_create')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('「分类」 starts checked and exports without 书架中的作品', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    final _CapturingOptionsExporter exporter = _CapturingOptionsExporter(
      database: db,
    );
    final String targetPath = p.join(tmp.path, 'categories.tachibk');

    await tester.pumpWidget(
      _harness(
        appModel,
        CreateBackupPage(
          exporter: exporter,
          savePathPicker:
              ({
                required String initialDirectory,
                required String fileName,
              }) async => targetPath,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      _tile(tester, const Key('create_backup_include_categories')).value,
      isTrue,
      reason: '分类 defaults to checked',
    );

    await tester.tap(find.byKey(const Key('create_backup_include_library')));
    await tester.pumpAndSettle();

    expect(
      _tile(tester, const Key('create_backup_include_categories')).enabled,
      isNot(false),
      reason: '分类 does not depend on 书架中的作品',
    );
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(const Key('create_backup_create')),
          )
          .onPressed,
      isNotNull,
      reason: '分类 alone is exportable',
    );

    await tester.tap(find.byKey(const Key('create_backup_create')));
    await _pumpUntil(tester, find.text(t.backup_export_success));

    expect(exporter.options, isNotNull);
    expect(exporter.options!.includeLibrary, isFalse);
    expect(exporter.options!.includeChapters, isFalse);
    expect(exporter.options!.includeCategories, isTrue);
    expect(find.text(t.backup_export_success), findsOneWidget);
  });

  testWidgets(
    '进度记录 starts selected and depends on 书架中的作品',
    (WidgetTester tester) async {
      final _TestAppModel appModel = _TestAppModel(db, paths);
      await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
      await tester.pumpAndSettle();

      expect(find.text('进度记录'), findsOneWidget);
      expect(
        _tile(tester, const Key('create_backup_include_tracking')).value,
        isTrue,
        reason: '进度记录 defaults to checked',
      );
      expect(
        _tile(tester, const Key('create_backup_include_tracking')).enabled,
        isNot(false),
      );

      await tester.tap(find.byKey(const Key('create_backup_include_library')));
      await tester.pumpAndSettle();
      expect(
        _tile(tester, const Key('create_backup_include_tracking')).enabled,
        isFalse,
        reason: '进度记录 cannot be exported without 书架中的作品',
      );

      await tester.tap(find.byKey(const Key('create_backup_include_library')));
      await tester.pumpAndSettle();
      expect(
        _tile(tester, const Key('create_backup_include_tracking')).enabled,
        isNot(false),
      );
    },
  );

  testWidgets('unchecking「分类」greys out 创建 only when nothing is selected', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    await tester.pumpWidget(_harness(appModel, const CreateBackupPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('create_backup_include_categories')));
    await tester.pumpAndSettle();
    expect(
      _tile(tester, const Key('create_backup_include_categories')).value,
      isFalse,
    );
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(const Key('create_backup_create')),
          )
          .onPressed,
      isNotNull,
      reason: 'the library is still exported',
    );

    await tester.tap(find.byKey(const Key('create_backup_include_library')));
    await _scrollToSettings(tester);
    await tester.tap(
      find.byKey(const Key('create_backup_include_app_settings')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(const Key('create_backup_create')),
          )
          .onPressed,
      isNull,
      reason: '书架中的作品, 分类 and 应用设置 are all unselected',
    );

    // Scroll back up to the 书架 group before re-enabling 分类.
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create_backup_include_categories')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FushiFilledButton>(
            find.byKey(const Key('create_backup_create')),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'save dialog defaults to the Backup directory and its cancel writes nothing',
    (WidgetTester tester) async {
      final _TestAppModel appModel = _TestAppModel(db, paths);
      String? seenDirectory;
      String? seenFileName;
      await tester.pumpWidget(
        _harness(
          appModel,
          CreateBackupPage(
            savePathPicker:
                ({
                  required String initialDirectory,
                  required String fileName,
                }) async {
                  seenDirectory = initialDirectory;
                  seenFileName = fileName;
                  return null;
                },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('create_backup_create')));
      await tester.pumpAndSettle();

      expect(seenDirectory, paths.autobackupRoot.path);
      expect(
        seenFileName,
        matches(RegExp(r'^my-comic_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}\.tachibk$')),
      );
      expect(
        paths.autobackupRoot.listSync(),
        isEmpty,
        reason: 'cancelling the save dialog must not write a file',
      );
      expect(find.textContaining('已保存到'), findsNothing);
    },
  );

  testWidgets('shows progress while creating and the saved path on success', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    final _ControlledExporter exporter = _ControlledExporter(database: db);
    final String targetPath = p.join(tmp.path, 'controlled.tachibk');

    await tester.pumpWidget(
      _harness(
        appModel,
        CreateBackupPage(
          exporter: exporter,
          savePathPicker:
              ({
                required String initialDirectory,
                required String fileName,
              }) async => targetPath,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create_backup_create')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('正在创建备份…'), findsOneWidget);
    expect(find.text('已处理 1 / 2 部'), findsOneWidget);

    exporter.finish();
    await tester.pumpAndSettle();
    expect(
      find.text(t.backup_create_saved_path(path: targetPath)),
      findsOneWidget,
    );
  });

  testWidgets('reports export failures and does not claim the file was saved', (
    WidgetTester tester,
  ) async {
    final _TestAppModel appModel = _TestAppModel(db, paths);
    final String targetPath = p.join(tmp.path, 'failed.tachibk');

    await tester.pumpWidget(
      _harness(
        appModel,
        CreateBackupPage(
          exporter: _FailingExporter(database: db),
          savePathPicker:
              ({
                required String initialDirectory,
                required String fileName,
              }) async => targetPath,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('create_backup_create')));
    await _pumpUntil(tester, find.text(t.backup_create_failed_title));

    expect(find.text(t.backup_create_failed_title), findsOneWidget);
    expect(find.textContaining('fixture failure'), findsOneWidget);
    expect(find.textContaining('已保存到'), findsNothing);
    expect(File(targetPath).existsSync(), isFalse);
  });
}

class _FailingExporter extends MihonBackupExporter {
  _FailingExporter({required super.database});

  @override
  Future<MihonBackupExportReport> exportToFile({
    required File target,
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    throw StateError('fixture failure');
  }
}

class _CapturingOptionsExporter extends MihonBackupExporter {
  _CapturingOptionsExporter({required super.database});

  MihonBackupExportOptions? options;

  @override
  Future<MihonBackupExportReport> exportToFile({
    required File target,
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    this.options = options;
    return const MihonBackupExportReport(
      mangaCount: 0,
      chapterCount: 0,
      elapsed: Duration.zero,
    );
  }
}

class _ControlledExporter extends MihonBackupExporter {
  _ControlledExporter({required super.database});

  final Completer<void> _gate = Completer<void>();

  void finish() => _gate.complete();

  @override
  Future<MihonBackupExportReport> exportToFile({
    required File target,
    required MihonBackupExportOptions options,
    void Function(MihonBackupExportProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const MihonBackupExportProgress(
        processed: 1,
        total: 2,
        currentTitle: 'Alpha',
      ),
    );
    await _gate.future;
    return const MihonBackupExportReport(
      mangaCount: 1,
      chapterCount: 0,
      elapsed: Duration.zero,
    );
  }
}
