import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// Ticket 01 守卫：钉死「存储根唯一入口 [AppPaths]」的收敛不被回退。
///
/// 两类断言：
///  1. **测试根行为**（运行时）：`FUSHI_TEST_ROOT` 注入下，Content root 落
///     `<testRoot>/content`、Program state root 落 `<testRoot>/userdata`。
///  2. **单一入口**（源码扫描）：核心数据存储模块不再直连
///     `getApplicationDocumentsDirectory` / `getApplicationSupportDirectory`，必须经
///     [AppPaths]；`app_model` 从新根派生 DB / cache / content。
void main() {
  group('Ticket 12 测试根：只保留新 root', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_app_paths_');
      AppPaths.debugTestEnvironment = <String, String>{
        'FUSHI_TEST_ROOT': root.path,
      };
    });

    tearDown(() {
      AppPaths.debugTestEnvironment = null;
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('Content root 与 Program state root 落在测试根下', () async {
      final AppPaths paths = await AppPaths.resolve();
      expect(
        paths.contentRoot.path,
        equals(p.join(root.absolute.path, 'content')),
      );
      expect(
        paths.programStateRoot.path,
        equals(p.join(root.absolute.path, 'userdata')),
      );
      expect(
        paths.stateRoot.path,
        equals(p.join(root.absolute.path, 'userdata', 'state')),
      );
      expect(
        paths.cacheRoot.path,
        equals(p.join(root.absolute.path, 'userdata', 'cache')),
      );
    });

    test('Content root 子目录 getter 在内容根下逐字节派生', () async {
      final Directory content = await AppPaths.contentRootDirectory();
      expect(
        (await AppPaths.downloadsRootDirectory()).path,
        p.join(content.path, 'downloads'),
      );
      expect(
        (await AppPaths.autobackupRootDirectory()).path,
        p.join(content.path, 'autobackup'),
      );
      expect(
        (await AppPaths.localComicRootDirectory()).path,
        p.join(content.path, 'local'),
      );
    });

    test('Program state 子目录 getter 在 state/ 下逐字节派生', () async {
      final Directory root = await AppPaths.programStateRootDirectory();
      expect(
        (await AppPaths.stateRootDirectory()).path,
        p.join(root.path, 'state'),
      );
      expect(
        (await AppPaths.cacheRootDirectory()).path,
        p.join(root.path, 'cache'),
      );
      expect(
        (await AppPaths.customFontsRootDirectory()).path,
        p.join(root.path, 'state', 'custom_fonts'),
      );
      expect(
        (await AppPaths.webView2RootDirectory()).path,
        p.join(root.path, 'state', 'webview2'),
      );
      expect(
        (await AppPaths.logsRootDirectory()).path,
        p.join(root.path, 'state', 'logs'),
      );
    });
  });

  group('TODO-935 E0 单一入口：核心存储模块不再直连 path_provider 数据根', () {
    String read(String relative) {
      final File f = File(relative);
      expect(f.existsSync(), isTrue, reason: '缺失文件: $relative');
      return f.readAsStringSync();
    }

    // 被收敛的核心存储模块（fushi/ 下，相对 fushi/ 运行）。my-comic 已删除
    // 视频域，只剩漫画/书库真正使用的模块。
    const List<String> convergedModules = <String>[
      'lib/src/models/app_model.dart',
      '../packages/fushi_engine/lib/media/manga/book_storage.dart',
    ];

    for (final String rel in convergedModules) {
      test('$rel 不直连 documents/support 数据根（经 AppPaths）', () {
        final String src = read(rel);
        expect(
          src.contains('getApplicationDocumentsDirectory'),
          isFalse,
          reason: '$rel 应经 AppPaths 取 documents 根，不得直连 path_provider',
        );
        expect(
          src.contains('getApplicationSupportDirectory'),
          isFalse,
          reason: '$rel 应经 AppPaths 取 support 根，不得直连 path_provider',
        );
      });
    }

    test('AppPaths 是唯一解析 Content / Program state 根的入口', () {
      final String src = read('lib/src/storage/app_paths.dart');
      // 平台默认根解析只允许出现在 AppPaths。
      expect(src.contains('getApplicationDocumentsDirectory'), isTrue);
      expect(src.contains('getApplicationSupportDirectory'), isTrue);
      // 新根名字是单一真相源。
      expect(src.contains('contentRootDirName'), isTrue);
      expect(src.contains('programStateRootDirName'), isTrue);
      expect(src.contains('stateDirName'), isTrue);
      expect(src.contains('cacheDirName'), isTrue);
    });

    test('更新包落在 Program state root 的 state/ 下', () {
      final String src = read(
        'lib/src/utils/misc/update_checker_download.dart',
      );
      expect(
        src.contains('AppPaths.stateRootDirectory'),
        isTrue,
        reason: '更新包属于 Program state，卸载删除、更新保留',
      );
      expect(
        src.contains('getApplicationSupportDirectory'),
        isFalse,
        reason: '更新包不得再落回旧的 %APPDATA% support 根',
      );
    });

    test('app_model 经 AppPaths.resolve 派生新根', () {
      final String src = read('lib/src/models/app_model.dart');
      expect(
        src.contains('AppPaths.resolve()'),
        isTrue,
        reason: '_prepareRuntimeDirectories 必须经 AppPaths.resolve 解析',
      );
      expect(
        src.contains('_appPaths.contentRoot'),
        isTrue,
        reason: '内容/书库根必须是 Content root',
      );
      expect(
        src.contains('_appPaths.stateRoot'),
        isTrue,
        reason: '数据库根必须是 Program state root 的 state/',
      );
      expect(
        src.contains('_appPaths.cacheRoot'),
        isTrue,
        reason: '临时/缓存根必须是 Program state root 的 cache/',
      );
      expect(
        src.contains('consumeInstallerDataRootBootstrap'),
        isFalse,
        reason: '旧 data-root bootstrap 不得再参与启动解析',
      );
    });

  });
}
