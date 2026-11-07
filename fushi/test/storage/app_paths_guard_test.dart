import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/storage/app_paths.dart';

/// Ticket 01 守卫：钉死「存储根唯一入口 [AppPaths]」的收敛不被回退。
///
/// 两类断言：
///  1. **测试根行为**（运行时）：`FUSHI_TEST_ROOT` 注入下，Content root 落
///     `<testRoot>/content`、Program state root 落 `<testRoot>/userdata`，旧 root
///     getter 以 alias 指向新根。
///  2. **单一入口**（源码扫描）：核心数据存储模块不再直连
///     `getApplicationDocumentsDirectory` / `getApplicationSupportDirectory`，必须经
///     [AppPaths]；`app_model` 从新根派生 DB / cache / content。
void main() {
  group('Ticket 01 测试根：新根与旧 alias 同源', () {
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
      expect(paths.contentRoot.path,
          equals(p.join(root.absolute.path, 'content')));
      expect(paths.programStateRoot.path,
          equals(p.join(root.absolute.path, 'userdata')));
      expect(paths.stateRoot.path,
          equals(p.join(root.absolute.path, 'userdata', 'state')));
      expect(paths.cacheRoot.path,
          equals(p.join(root.absolute.path, 'userdata', 'cache')));
    });

    test('旧 root getter alias 指向新根', () async {
      final AppPaths paths = await AppPaths.resolve();
      expect(paths.documentsRoot.path, paths.contentRoot.path);
      expect(paths.supportRoot.path, paths.stateRoot.path);
      expect(paths.tempRoot.path, paths.cacheRoot.path);
    });

    test('Content root 子目录 getter 在内容根下逐字节派生', () async {
      final Directory docs = await AppPaths.contentRootDirectory();
      expect((await AppPaths.audiobooksDirectory()).path,
          p.join(docs.path, 'audiobooks'));
      expect((await AppPaths.epubBooksDirectory()).path,
          p.join(docs.path, 'fushi_books'));
      expect((await AppPaths.videoCoversDirectory()).path,
          p.join(docs.path, 'video_covers'));
      expect((await AppPaths.videoSubtitlesDirectory()).path,
          p.join(docs.path, 'video_subtitles'));
      expect((await AppPaths.mpvShadersDirectory()).path,
          p.join(docs.path, 'mpv_shaders'));
      expect((await AppPaths.remoteVideosDirectory()).path,
          p.join(docs.path, 'remote_videos'));
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
      '../packages/fushi_engine/lib/epub/epub_storage.dart',
    ];

    for (final String rel in convergedModules) {
      test('$rel 不直连 documents/support 数据根（经 AppPaths）', () {
        final String src = read(rel);
        expect(src.contains('getApplicationDocumentsDirectory'), isFalse,
            reason: '$rel 应经 AppPaths 取 documents 根，不得直连 path_provider');
        expect(src.contains('getApplicationSupportDirectory'), isFalse,
            reason: '$rel 应经 AppPaths 取 support 根，不得直连 path_provider');
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
      final String src =
          read('lib/src/utils/misc/update_checker_download.dart');
      expect(src.contains('AppPaths.stateRootDirectory'), isTrue,
          reason: '更新包属于 Program state，卸载删除、更新保留');
      expect(src.contains('getApplicationSupportDirectory'), isFalse,
          reason: '更新包不得再落回旧的 %APPDATA% support 根');
    });

    test('app_model 经 AppPaths.resolve 派生新根', () {
      final String src = read('lib/src/models/app_model.dart');
      expect(src.contains('AppPaths.resolve()'), isTrue,
          reason: '_prepareRuntimeDirectories 必须经 AppPaths.resolve 解析');
      expect(src.contains('_appPaths.contentRoot'), isTrue,
          reason: '内容/书库根必须是 Content root');
      expect(src.contains('_appPaths.stateRoot'), isTrue,
          reason: '数据库根必须是 Program state root 的 state/');
      expect(src.contains('_appPaths.cacheRoot'), isTrue,
          reason: '临时/缓存根必须是 Program state root 的 cache/');
      expect(src.contains('consumeInstallerDataRootBootstrap'), isFalse,
          reason: '旧 data-root bootstrap 不得再参与启动解析');
    });

    test('fushi_audio 包内 audiobook_storage 有单一 documents 解析点', () {
      // 上游包不能 import app 层 AppPaths，故包内自有单一解析点 _documentsRoot；
      // 三处持久目录方法都经它，不再各自直连 path_provider。
      final String src = read(
          '../packages/fushi_audio/lib/src/audiobook/audiobook_storage.dart');
      expect(src.contains('_documentsRoot()'), isTrue,
          reason: 'audiobook_storage 必须有包内单一 documents 解析点 _documentsRoot');
      // _documentsRoot 是唯一真正调用 path_provider 的地方：三个持久目录方法都改读
      // `await _documentsRoot()`，包内对 getApplicationDocumentsDirectory() 的实际
      // 调用表达式只剩 _documentsRoot 自身一处（注释里提到名字不算调用）。
      expect(
        '_documentsRoot()'.allMatches(src).length,
        equals(4),
        reason: '_documentsRoot 定义 1 次 + 三个持久目录方法各调用 1 次 = 4',
      );
      // TODO-1236：_documentsRoot 改为 resolver 注入优先；无头服务端拆分后
      // audiobook_storage.dart 是纯 Dart，**不再直连 path_provider**——平台兜底
      // `getApplicationDocumentsDirectory` 挪到重文件 audiobook_storage_platform.dart，
      // 由 installAudiobookStoragePlatform() 以 `??=` 装入（不覆盖 app 层注入的 AppPaths）。
      expect(src.contains('path_provider'), isFalse,
          reason: 'audiobook_storage.dart 必须零插件（无头服务端消费）');
      expect(
        RegExp(r'documentsRootResolver \?\? _unassignedDocumentsRoot')
            .hasMatch(src),
        isTrue,
        reason: '_documentsRoot 应经 resolver 门控、未装配时抛 StateError',
      );
      final String platformSrc = read(
          'lib/src/media/audiobook/audiobook_storage_platform.dart');
      expect(
        RegExp(r'documentsRootResolver \?\?= getApplicationDocumentsDirectory')
            .hasMatch(platformSrc),
        isTrue,
        reason: '平台兜底只能以 ??= 补默认值，不得覆盖 AppPaths 注入',
      );
    });
  });
}
