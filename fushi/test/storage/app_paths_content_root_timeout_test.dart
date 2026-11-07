import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/storage/app_paths.dart';

import '../helpers/source_guard.dart';

/// Content root 掉线盘的启动契约。
///
/// TODO-1260：同步 `existsSync()` 在掉线盘上阻塞主 isolate 到 OS 超时 → 无限加载。
/// 修复改用带 2s 超时的异步 `exists()`，绝不 hang。
///
/// BUG-815 语义保留到新的 Content root：配置了 `content_root` 但不可达 →
/// [AppPaths.resolve] 抛 [DataRootUnavailableException]（UI 显逃生屏）；只有用户
/// 显式选择「本次用默认位置启动」（[AppPaths.forceDefaultRootForSession]）才退回
/// 默认 `<Documents>/MyComic`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory installDir;

  String defaultContentRoot() => p.join(platformDocuments.path, 'MyComic');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('fushi_content_timeout_');
    platformDocuments = Directory(p.join(tmp.path, 'Documents'))
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
            return platformDocuments.path;
          case 'getApplicationSupportDirectory':
            return p.join(tmp.path, 'default_support');
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
    AppPaths.forceDefaultRootForSession = false;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('配置的 Content root 不可达 → 抛 DataRootUnavailableException，快速返回不 hang',
      () async {
    final String missing = p.join(tmp.path, 'offline_drive_root');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'content_root': missing,
    });

    final Stopwatch sw = Stopwatch()..start();
    await expectLater(
      AppPaths.resolve(),
      throwsA(
        isA<DataRootUnavailableException>().having(
          (DataRootUnavailableException e) => e.configuredPath,
          'configuredPath',
          missing,
        ),
      ),
      reason: 'Content root 不可达时必须抛异常让 UI 决策，绝不静默建空库',
    );
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
        reason: '坏 / 掉线 Content root 必须被超时降级，不得让 resolve() 无限阻塞');
  });

  test('不可达 + 用户显式选择默认位置 → 退回 <Documents>/MyComic，不抛', () async {
    final String missing = p.join(tmp.path, 'offline_drive_root');
    SharedPreferences.setMockInitialValues(<String, Object>{
      'content_root': missing,
    });
    AppPaths.forceDefaultRootForSession = true;

    final AppPaths paths = await AppPaths.resolve();
    expect(paths.contentRoot.path, defaultContentRoot());
  });

  test('未配置 Content root（普通默认用户）→ 正常用 <Documents>/MyComic', () async {
    final AppPaths paths = await AppPaths.resolve();
    expect(paths.contentRoot.path, defaultContentRoot());
  });

  test('源码守卫：根存在性探测不得再用阻塞式 existsSync()，必须走带超时的异步 exists()',
      () {
    final File? f = <String>[
      'lib/src/storage/app_paths.dart',
      'fushi/lib/src/storage/app_paths.dart',
    ].map(File.new).cast<File?>().firstWhere(
          (File? f) => f != null && f.existsSync(),
          orElse: () => null,
        );
    expect(f, isNotNull, reason: 'app_paths.dart not found');
    final String src = f!.readAsStringSync();

    // 先把注释换成等长空白再定位：注释里会提到 existsSync 解释旧代码。
    final String code = maskComments(src);
    final int start = code.indexOf('static Future<bool> _probeDataRootExists(');
    expect(start, greaterThanOrEqualTo(0));
    final int end = code.indexOf('static ', start + 10);
    final String body = code.substring(start, end);
    expect(body.contains('existsSync('), isFalse,
        reason: '根探测必须异步 + 超时，禁止 existsSync() 阻塞启动');
    expect(body.contains('.exists()'), isTrue);
    expect(body.contains('.timeout('), isTrue);
  });
}
