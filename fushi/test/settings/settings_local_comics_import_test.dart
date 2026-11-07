import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_local_import.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// storage-layout spec 故事 26：设置 →「存储与下载」里的「导入本地漫画」只在
/// 用户点击时扫描 `localcomic`，原地登记，不复制文件（ADR 0013）。
class _TestAppModel extends AppModel {
  _TestAppModel(this._db, this._paths) : super(testPlatformServices());

  final FushiDatabase _db;
  final AppPaths _paths;

  @override
  FushiDatabase get database => _db;

  @override
  AppPaths get appPaths => _paths;
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late AppPaths paths;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('settings_local_import_');
    AppPaths.debugTestEnvironment = <String, String>{
      'FUSHI_TEST_ROOT': tmp.path,
    };
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    paths = await AppPaths.resolve();
  });

  tearDown(() async {
    AppPaths.debugTestEnvironment = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<SettingsContext> captureContext(
    WidgetTester tester,
    AppModel appModel,
  ) async {
    late SettingsContext captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              captured = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  testWidgets('「导入本地漫画」扫描 localcomic 并原地登记，不复制文件', (WidgetTester tester) async {
    final File page = File(
      p.join(paths.localComicRoot.path, 'Manga', 'Ch 1', '001.jpg'),
    )..createSync(recursive: true);
    page.writeAsBytesSync(<int>[1, 2, 3]);
    final SettingsContext settings = await captureContext(
      tester,
      _TestAppModel(db, paths),
    );

    final SettingsSection section = buildLocalComicsImportSection();
    final SettingsStatusItem item = section.items.single as SettingsStatusItem;
    expect(item.id, 'storage.import_local_comics');
    expect(item.actionLabel, t.data_storage_import_local_comics_button);
    final SettingsItemAction? action = item.resolveAction(settings);
    expect(action, isNotNull);

    await tester.runAsync(() async => action!(settings));

    final List<EpubBookRow> rows = await db.getAllEpubBooks();
    expect(rows, hasLength(1), reason: '扫描后作品必须进 Library');
    expect(
      rows.single.extractDir,
      p.join(paths.localComicRoot.path, 'Manga'),
      reason: 'Local source 条目原地指向 localcomic 里的作品目录',
    );
    expect(page.existsSync(), isTrue, reason: '导入不得复制或移动源文件');
    expect(
      Directory(p.join(paths.contentRoot.path, 'fushi_books')).existsSync(),
      isFalse,
      reason: '不得把本地漫画复制进受管书库',
    );
  });
}
