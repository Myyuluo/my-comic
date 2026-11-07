import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';

/// Ticket 01：用户可见的写路径（有声书 / 字幕 / 封面）必须跟随 Content root，
/// 不再跟随已废弃的 `data_root`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory defaultDocs;
  late Directory installDir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('fushi_wpaths_content_');
    defaultDocs = Directory(p.join(tmp.path, 'default_documents'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'install'))..createSync();
    AppPaths.debugExecutablePathOverride =
        p.join(installDir.path, 'my_comic.exe');
    AppPaths.debugLocalAppDataOverride =
        Directory(p.join(tmp.path, 'LocalAppData')).path;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        switch (call.method) {
          case 'getApplicationDocumentsDirectory':
            return defaultDocs.path;
          case 'getApplicationSupportDirectory':
            return p.join(tmp.path, 'default_support');
          case 'getTemporaryDirectory':
            return p.join(tmp.path, 'systemp');
        }
        return null;
      },
    );
    // 生产接线：app 启动期把有声书根解析接到 AppPaths（这里显式重放以端到端验证）。
    AudiobookStorage.documentsRootResolver = AppPaths.contentRootDirectory;
  });

  tearDown(() {
    AppPaths.debugExecutablePathOverride = null;
    AppPaths.debugLocalAppDataOverride = null;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AudiobookStorage.documentsRootResolver = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('默认 Content root → 写路径落 <Documents>/MyComic/<child>', () async {
    final AppPaths paths = await AppPaths.resolve();
    final String content = paths.contentRoot.path;
    expect(content, p.join(defaultDocs.path, 'MyComic'));

    expect((await AppPaths.downloadsRootDirectory()).path,
        p.join(content, 'downloads'));
    expect((await AppPaths.autobackupRootDirectory()).path,
        p.join(content, 'autobackup'));
    expect((await AppPaths.localComicRootDirectory()).path,
        p.join(content, 'localcomic'));
    expect(p.equals(await AudiobookStorage.audiobooksRootDir(),
        p.join(content, 'audiobooks')), isTrue);

    // 不再散落在共享 Documents 根。
    expect((await AppPaths.downloadsRootDirectory()).path,
        isNot(equals(p.join(defaultDocs.path, 'downloads'))));
  });

  test('content_root 生效 → 写路径落新 Content root', () async {
    final Directory content = Directory(p.join(tmp.path, 'CustomContent'))
      ..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'content_root': content.path,
    });

    expect((await AppPaths.downloadsRootDirectory()).path,
        p.join(content.path, 'downloads'));
    expect((await AppPaths.localComicRootDirectory()).path,
        p.join(content.path, 'localcomic'));
    expect(p.equals(await AudiobookStorage.audiobooksRootDir(),
        p.join(content.path, 'audiobooks')), isTrue);
  });

  test('旧 data_root 不再影响写路径', () async {
    final Directory oldRoot = Directory(p.join(tmp.path, 'OldDataRoot'))
      ..createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      'data_root': oldRoot.path,
    });

    expect((await AppPaths.downloadsRootDirectory()).path,
        p.join(defaultDocs.path, 'MyComic', 'downloads'));
  });
}
