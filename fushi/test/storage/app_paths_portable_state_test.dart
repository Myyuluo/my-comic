import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/webview2_state_root.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Ticket 02：Portable state 的目录布局、旧用户默认 Content root 自动 rebase、
/// 自定义 Content root 逃生屏，以及可丢弃缓存的边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory platformDocuments;
  late Directory installDir;
  late Directory localAppData;

  String currentDefaultContentRoot() =>
      p.join(platformDocuments.path, 'MyComic');

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AppPaths.debugResetDocumentsLayoutCache();
    WebView2StateRoot.debugReset();
    tmp = Directory.systemTemp.createTempSync('fushi_portable_state_');
    platformDocuments = Directory(p.join(tmp.path, 'Users', 'bob', 'Documents'))
      ..createSync(recursive: true);
    installDir = Directory(p.join(tmp.path, 'Program', 'MyComic'))
      ..createSync(recursive: true);
    localAppData = Directory(p.join(tmp.path, 'LocalAppData'))
      ..createSync(recursive: true);
    AppPaths.debugExecutablePathOverride = p.join(
      installDir.path,
      'my_comic.exe',
    );
    AppPaths.debugLocalAppDataOverride = localAppData.path;
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
    AppPaths.debugResetDocumentsLayoutCache();
    WebView2StateRoot.debugReset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test(
    'Portable state 子目录 custom_fonts / webview2 / logs 都在 state 下并被创建',
    () async {
      final AppPaths paths = await AppPaths.resolve();

      expect(
        paths.customFontsRoot.path,
        p.join(paths.stateRoot.path, 'custom_fonts'),
      );
      expect(paths.webView2Root.path, p.join(paths.stateRoot.path, 'webview2'));
      expect(paths.logsRoot.path, p.join(paths.stateRoot.path, 'logs'));

      for (final Directory dir in <Directory>[
        paths.customFontsRoot,
        paths.webView2Root,
        paths.logsRoot,
      ]) {
        expect(dir.existsSync(), isTrue, reason: '首启应创建 ${dir.path}');
      }
      // 它们不在 Content root 下：Content root 不随便携拷贝走。
      expect(
        p.isWithin(paths.contentRoot.path, paths.customFontsRoot.path),
        isFalse,
      );
    },
  );

  test('旧用户默认 Documents\\MyComic 配置被自动 rebase 到当前用户默认', () async {
    final String oldUserDefault = p.join(
      tmp.path,
      'Users',
      'alice',
      'Documents',
      'MyComic',
    );
    Directory(oldUserDefault).createSync(recursive: true);
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: oldUserDefault,
    });

    final AppPaths paths = await AppPaths.resolve();

    expect(
      paths.contentRoot.path,
      currentDefaultContentRoot(),
      reason: '旧用户的默认 MyComic 应自动改到当前用户的默认路径',
    );
    expect(paths.contentRootIsDefault, isTrue);
    expect(
      paths.contentRootRebaseFrom,
      oldUserDefault,
      reason: '启动期 rebase 需要知道旧根',
    );
    // 旧默认偏好不应继续把每次启动都拖回别人的目录。
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(AppPaths.contentRootPrefKey), isNull);
  });

  test('自定义 Content root 不可达仍走「数据位置未响应」异常，不静默建空库', () async {
    final String missingCustom = p.join(
      tmp.path,
      'Users',
      'alice',
      'Documents',
      'CustomMangaData',
    );
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: missingCustom,
    });

    await expectLater(
      AppPaths.resolve(),
      throwsA(
        isA<DataRootUnavailableException>().having(
          (DataRootUnavailableException e) => e.configuredPath,
          'configuredPath',
          missingCustom,
        ),
      ),
    );
  });

  test('名字像默认根但位于自定义目录下的 Content root 不会被误判为旧用户默认根', () async {
    final String custom = p.join(tmp.path, 'D', 'Manga', 'MyComic');
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppPaths.contentRootPrefKey: custom,
    });

    await expectLater(
      AppPaths.resolve(),
      throwsA(isA<DataRootUnavailableException>()),
      reason: '只有 .../Documents/MyComic 形状才自动 rebase；自定义路径缺失应逃生',
    );
  });

  test('cache 是可丢弃的：删掉后 resolve 重建，state 与 Content root 不受影响', () async {
    final AppPaths first = await AppPaths.resolve();
    final File dbMarker = File(p.join(first.stateRoot.path, 'my_comic.db'))
      ..writeAsStringSync('db');
    final File prefsMarker = File(
      p.join(first.stateRoot.path, 'shared_preferences.json'),
    )..writeAsStringSync('{}');
    final File contentMarker = File(
      p.join(first.downloadsRoot.path, 'keep.txt'),
    )..writeAsStringSync('content');

    first.cacheRoot.deleteSync(recursive: true);
    expect(first.cacheRoot.existsSync(), isFalse);

    final AppPaths second = await AppPaths.resolve();

    expect(second.cacheRoot.path, first.cacheRoot.path);
    expect(second.cacheRoot.existsSync(), isTrue, reason: 'cache 必须可重建');
    expect(dbMarker.existsSync(), isTrue);
    expect(prefsMarker.existsSync(), isTrue);
    expect(contentMarker.existsSync(), isTrue);
    expect(second.stateRoot.path, first.stateRoot.path);
    expect(second.contentRoot.path, first.contentRoot.path);
  });

  test('WebView2 user data folder 指向 state/webview2', () async {
    final AppPaths paths = await AppPaths.resolve();
    String? installedName;
    String? installedValue;
    WebView2StateRoot.debugSetEnvironmentVariable =
        (String name, String value) {
          installedName = name;
          installedValue = value;
          return true;
        };

    final bool installed = WebView2StateRoot.install(
      stateRoot: paths.stateRoot,
      isWindows: true,
    );

    expect(installed, isTrue);
    expect(installedName, WebView2StateRoot.userDataFolderEnvironmentVariable);
    expect(installedValue, paths.webView2Root.path);
    expect(
      WebView2StateRoot.mangaUserDataFolderFor(paths.stateRoot.path),
      p.join(paths.stateRoot.path, 'webview2-manga'),
      reason: '漫画站点浏览器的独立 environment 也必须住在 state 根下',
    );
  });

  test('错误日志与学习统计日志默认落 state/logs', () async {
    final AppPaths paths = await AppPaths.resolve();

    await ErrorLogService.instance.init();
    ErrorLogService.instance.log('ticket02.test', 'log location');
    await ErrorLogService.instance.flush();

    await StudyDiagLog.instance.init();
    await StudyDiagLog.instance.pending;

    expect(File(p.join(paths.logsRoot.path, 'error_log.txt')).existsSync(),
        isTrue);
    expect(File(p.join(paths.logsRoot.path, StudyDiagLog.fileName)).existsSync(),
        isTrue);
  });
}
