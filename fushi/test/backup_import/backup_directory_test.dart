import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/backup_import/mihon_backup_import_flow.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/backup_service.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 11: the Backup directory.
///
/// `.tachibk` import opens in `<Content root>/autobackup` (ADR 0011 / ADR 0005
/// update). `.fushi.zip` stays an App snapshot: it is a different format and is
/// never written into the Backup directory. v1 has no scheduled automatic
/// backup.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory installDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('fushi_backup_dir_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'install'))..createSync();
    AppPaths.debugExecutablePathOverride = p.join(
      installDir.path,
      'my_comic.exe',
    );
    AppPaths.debugLocalAppDataOverride = p.join(tmp.path, 'LocalAppData');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async {
            switch (call.method) {
              case 'getApplicationDocumentsDirectory':
                return platformDocuments.path;
              case 'getApplicationSupportDirectory':
                return p.join(tmp.path, 'AppData');
              case 'getTemporaryDirectory':
                return p.join(tmp.path, 'systemp');
            }
            return null;
          },
        );
  });

  tearDown(() {
    AppPaths.debugExecutablePathOverride = null;
    AppPaths.debugLocalAppDataOverride = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('import picker defaults to <Content root>/autobackup and selects '
      '.tachibk files there', () async {
    final AppPaths paths = await AppPaths.resolve();
    final Directory expected = Directory(
      p.join(platformDocuments.path, 'MyComic', 'autobackup'),
    );
    expect(paths.autobackupRoot.path, expected.path);
    expect(paths.autobackupRoot.existsSync(), isTrue);

    // A Backup placed in autobackup is directly selectable from the picker's
    // default location.
    final File backup = File(p.join(paths.autobackupRoot.path, 'manga.tachibk'))
      ..writeAsStringSync('backup');

    final _RecordingFilePicker picker = _RecordingFilePicker(
      resultPath: backup.path,
    );
    final String? picked = await pickMihonBackupFile(
      initialDirectory: mihonBackupPickerInitialDirectory(paths),
      picker: picker,
    );

    expect(picked, backup.path);
    expect(picker.lastInitialDirectory, expected.path);
    expect(picker.lastType, FileType.custom);
    expect(picker.lastAllowedExtensions, <String>['tachibk']);
    expect(picker.lastAllowMultiple, isFalse);
  });

  test(
    'runMihonBackupImport opens the picker in the Backup directory',
    () async {
      final AppPaths paths = await AppPaths.resolve();
      // Pure Dart tests have no registered platform FilePicker yet; keep the
      // pre-existing instance (if any) so this test does not leak the fake.
      FilePicker? previous;
      try {
        previous = FilePicker.platform;
      } catch (_) {
        previous = null;
      }
      final _RecordingFilePicker picker = _RecordingFilePicker();
      FilePicker.platform = picker;
      addTearDown(() {
        if (previous != null) FilePicker.platform = previous;
      });

      // The fake picker returns null, so the flow stops at the picker boundary
      // and never needs a live BuildContext / database.
      await runMihonBackupImport(
        SettingsContext(
          context: _FakeBuildContext(),
          appModel: _PathsAppModel(paths),
          ref: _FakeWidgetRef(),
          readerSource: ReaderFushiSource.instance,
          refresh: () {},
        ),
      );

      expect(picker.lastInitialDirectory, paths.autobackupRoot.path);
      expect(picker.lastAllowedExtensions, <String>['tachibk']);
    },
  );

  test('import picker follows a configured Content root', () async {
    final Directory customContent = Directory(p.join(tmp.path, 'CustomContent'))
      ..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'content_root': customContent.path,
    });

    final AppPaths paths = await AppPaths.resolve();
    final Directory expected = Directory(
      p.join(customContent.path, 'autobackup'),
    );

    expect(paths.autobackupRoot.path, expected.path);
    expect(expected.existsSync(), isTrue);
    expect(mihonBackupPickerInitialDirectory(paths), expected.path);
  });

  test('.fushi.zip remains an App snapshot, not a .tachibk Backup', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final BackupService service = BackupService(
      db: db,
      dbDirectory: tmp.path,
      appVersion: 'test',
    );

    final String appSnapshotName = service.defaultFilename();
    expect(
      appSnapshotName,
      matches(RegExp(r'^fushi-backup-\d{4}-\d{2}-\d{2}\.fushi\.zip$')),
    );
    expect(appSnapshotName.endsWith('.tachibk'), isFalse);
  });

  test(
    'App snapshot (.fushi.zip) export never targets the Backup directory',
    () {
      // The legacy `.fushi.zip` export path stays exactly as it was: a user
      // save/share target, never `<Content root>/autobackup`.
      for (final String source in <String>[
        'lib/src/sync/backup_service.dart',
        'lib/src/sync/sync_settings_schema/backup.part.dart',
      ]) {
        expect(
          File(source).readAsStringSync().contains('autobackup'),
          isFalse,
          reason: '$source writes the App snapshot, not the Backup directory',
        );
      }
    },
  );

  test('no scheduled automatic backup task is wired into the backup flow', () {
    for (final String source in <String>[
      'lib/src/backup_import/mihon_backup_import_flow.dart',
      'lib/src/backup_import/mihon_backup_import_service.dart',
      'lib/src/sync/backup_service.dart',
    ]) {
      final String src = File(source).readAsStringSync();
      expect(src.contains('Timer.periodic'), isFalse, reason: source);
      expect(src.contains('Timer('), isFalse, reason: source);
    }
  });
}

class _FakeBuildContext extends Fake implements BuildContext {}

class _FakeWidgetRef extends Fake implements WidgetRef {}

class _PathsAppModel extends AppModel {
  _PathsAppModel(this._paths) : super(testPlatformServices());

  final AppPaths _paths;

  @override
  AppPaths get appPaths => _paths;
}

class _RecordingFilePicker extends FilePicker {
  _RecordingFilePicker({this.resultPath});

  final String? resultPath;

  String? lastInitialDirectory;
  FileType? lastType;
  List<String>? lastAllowedExtensions;
  bool? lastAllowMultiple;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    lastInitialDirectory = initialDirectory;
    lastType = type;
    lastAllowedExtensions = allowedExtensions;
    lastAllowMultiple = allowMultiple;
    final String? path = resultPath;
    if (path == null) return null;
    return FilePickerResult(<PlatformFile>[
      PlatformFile(
        name: p.basename(path),
        path: path,
        size: File(path).lengthSync(),
      ),
    ]);
  }
}
