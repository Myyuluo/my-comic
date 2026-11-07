import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase, fushiDatabaseFileName;
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';

/// Ticket 01/12：Content root / Program state root 的解析与创建；旧 root API 已删除。
///
/// 生产默认形态：
///  - Content root = `<Documents>/MyComic`，首启创建 `downloads` / `autobackup` /
///    `localcomic`；
///  - Program state root = `<exeDir>/userdata`，创建 `state` / `cache`。
///
/// 测试用 path_provider mock + exe/LOCALAPPDATA 注入，不触碰真实用户目录。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory platformSupport;
  late Directory installDir;
  late Directory localAppData;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('fushi_storage_roots_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
      ..createSync(recursive: true);
    platformSupport = Directory(p.join(tmp.path, 'AppData'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'install'))
      ..createSync(recursive: true);
    localAppData = Directory(p.join(tmp.path, 'LocalAppData'))
      ..createSync(recursive: true);
    AppPaths.debugExecutablePathOverride =
        p.join(installDir.path, 'my_comic.exe');
    AppPaths.debugLocalAppDataOverride = localAppData.path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getApplicationDocumentsDirectory':
            return platformDocuments.path;
          case 'getApplicationSupportDirectory':
            return platformSupport.path;
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
    EpubStorage.debugBaseDirectoryOverride = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('resolve 创建 Content root 与 Program state root 及其子目录', () async {
    final AppPaths paths = await AppPaths.resolve();

    final Directory content =
        Directory(p.join(platformDocuments.path, 'MyComic'));
    final Directory programState =
        Directory(p.join(installDir.path, 'userdata'));
    final Directory state = Directory(p.join(programState.path, 'state'));
    final Directory cache = Directory(p.join(programState.path, 'cache'));

    expect(paths.contentRoot.path, content.path);
    expect(paths.downloadsRoot.path, p.join(content.path, 'downloads'));
    expect(paths.autobackupRoot.path, p.join(content.path, 'autobackup'));
    expect(paths.localComicRoot.path, p.join(content.path, 'localcomic'));
    expect(paths.programStateRoot.path, programState.path);
    expect(paths.stateRoot.path, state.path);
    expect(paths.cacheRoot.path, cache.path);

    for (final Directory dir in <Directory>[
      content,
      paths.downloadsRoot,
      paths.autobackupRoot,
      paths.localComicRoot,
      programState,
      state,
      cache,
    ]) {
      expect(dir.existsSync(), isTrue, reason: '首启应创建 ${dir.path}');
    }
  });

  test('静态便捷层与实例根同源', () async {
    final AppPaths paths = await AppPaths.resolve();

    expect((await AppPaths.contentRootDirectory()).path,
        paths.contentRoot.path);
    expect((await AppPaths.downloadsRootDirectory()).path,
        paths.downloadsRoot.path);
    expect((await AppPaths.autobackupRootDirectory()).path,
        paths.autobackupRoot.path);
    expect((await AppPaths.localComicRootDirectory()).path,
        paths.localComicRoot.path);
    expect((await AppPaths.programStateRootDirectory()).path,
        paths.programStateRoot.path);
    expect((await AppPaths.stateRootDirectory()).path, paths.stateRoot.path);
    expect((await AppPaths.cacheRootDirectory()).path, paths.cacheRoot.path);
  });

  test('content_root 偏好决定 Content root，并在新位置创建三个空目录', () async {
    final Directory custom = Directory(p.join(tmp.path, 'CustomContent'))
      ..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'content_root': custom.path,
    });

    final AppPaths paths = await AppPaths.resolve();

    expect(paths.contentRoot.path, custom.path);
    expect(paths.downloadsRoot.path, p.join(custom.path, 'downloads'));
    expect(paths.autobackupRoot.path, p.join(custom.path, 'autobackup'));
    expect(paths.localComicRoot.path, p.join(custom.path, 'localcomic'));
    for (final Directory dir in <Directory>[
      paths.downloadsRoot,
      paths.autobackupRoot,
      paths.localComicRoot,
    ]) {
      expect(dir.existsSync(), isTrue);
      expect(dir.listSync(), isEmpty, reason: '切换 Content root 不搬文件');
    }
    // Program state root 不受 Content root 配置影响。
    expect(paths.programStateRoot.path,
        p.join(installDir.path, 'userdata'));
  });

  test('旧 data_root 与布局锚点偏好不再影响根解析，也不读取旧根', () async {
    final Directory oldRoot = Directory(p.join(tmp.path, 'OldFushiData'))
      ..createSync(recursive: true);
    File(p.join(oldRoot.path, 'support', 'my_comic.db'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old database');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'data_root': oldRoot.path,
      'documents_layout': 'flat',
      'documents_container': 'Hibiki',
    });

    final AppPaths paths = await AppPaths.resolve();

    expect(paths.contentRoot.path,
        p.join(platformDocuments.path, 'MyComic'));
    expect(paths.programStateRoot.path,
        p.join(installDir.path, 'userdata'));
    expect(p.isWithin(oldRoot.path, paths.contentRoot.path), isFalse);
    expect(p.isWithin(oldRoot.path, paths.stateRoot.path), isFalse);
  });

  test('安装目录不可写 → Program state root 回退 LOCALAPPDATA/MyComic/userdata',
      () async {
    // 用一个「文件」冒充安装目录：其下无法创建 userdata。
    final File blockedInstall = File(p.join(tmp.path, 'blocked_install'))
      ..writeAsStringSync('not a directory');
    AppPaths.debugExecutablePathOverride =
        p.join(blockedInstall.path, 'my_comic.exe');

    final AppPaths paths = await AppPaths.resolve();

    final Directory fallback =
        Directory(p.join(localAppData.path, 'MyComic', 'userdata'));
    expect(paths.programStateRoot.path, fallback.path);
    expect(paths.programStateRootIsFallback, isTrue);
    expect(paths.stateRoot.existsSync(), isTrue);
    expect(paths.cacheRoot.existsSync(), isTrue);
  });

  test('数据库与 prefs 同住 Program state root 的 state/ 下', () async {
    final AppPaths paths = await AppPaths.resolve();

    final FushiDatabase db = FushiDatabase(paths.stateRoot.path);
    await db.customSelect('SELECT 1').get();
    await db.close();

    expect(
      File(p.join(paths.stateRoot.path, fushiDatabaseFileName)).existsSync(),
      isTrue,
      reason: '数据库必须落在 <programState>/state/',
    );
    expect(
      File(p.join(paths.contentRoot.path, fushiDatabaseFileName)).existsSync(),
      isFalse,
      reason: '数据库不得落在 Content root',
    );
    expect(
      File(p.join(platformSupport.path, fushiDatabaseFileName)).existsSync(),
      isFalse,
      reason: '数据库不得落回旧的 %APPDATA% support 根',
    );
  });

}
