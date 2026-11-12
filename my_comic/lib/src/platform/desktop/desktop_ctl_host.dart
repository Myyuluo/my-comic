import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:my_comic_cli/my_comic_cli.dart';

import 'package:my_comic/src/startup/test_environment.dart';

/// 关闭桌面控制通道的环境变量（值为 `off`）。
const String kDesktopCtlDisableEnv = 'MYCOMIC_CTL';

/// `my_comic_cli open <target>` 的裁决：my-comic 已删除外部视频 / 查词 / 配对深链，
/// 唯一支持的媒体打开通道是 app 内书架，故 CLI 的 open 目标一律拒绝。
CtlOpenResult classifyCtlOpenTarget(
  String target, {
  bool Function(String path)? fileExists,
}) {
  return const CtlOpenResult.rejected('my-comic 只支持在 app 内打开漫画库');
}

/// 桌面控制通道的 app 侧实现：把 [CtlDesktopHandler] 的四个动作接到 app 已有的
/// 入口上（具体落点由 `main.dart` 的 `_MyComicReaderAppState` 以回调注入）。
class DesktopCtlHost implements CtlDesktopHandler {
  DesktopCtlHost({
    required this.isReady,
    required this.appVersion,
    required this.openTarget,
    required this.lookupWord,
    required this.quitApp,
    this.routes = const <CtlRoute>[],
  });

  /// AppModel 初始化完成且主导航可用。
  final bool Function() isReady;
  final String? Function() appVersion;
  final Future<CtlOpenResult> Function(String target) openTarget;
  final Future<void> Function(String word) lookupWord;
  final Future<void> Function() quitApp;

  /// 按域注册的路由（`ctl/desktop_ctl_routes.dart`）。
  @override
  final List<CtlRoute> routes;

  @override
  CtlAppStatus status() {
    final bool ready = isReady();
    return CtlAppStatus(
      pid: pid,
      platform: Platform.operatingSystem,
      initialised: ready,
      version: ready ? appVersion() : null,
    );
  }

  @override
  Future<CtlOpenResult> open(String target) => openTarget(target);

  @override
  Future<void> lookup(String word) => lookupWord(word);

  @override
  Future<void> quit() => quitApp();
}

/// 启动桌面控制通道（127.0.0.1 随机端口 + token，发现文件见 [resolveCtlStateDir]）。
///
/// 失败只记日志返回 null：CLI 用不了不该拖垮 app 启动。`MYCOMIC_CTL=off` 时不启动。
Future<CtlServer?> startDesktopCtlServer(
  CtlDesktopHandler handler, {
  Map<String, String>? environment,
}) async {
  final Map<String, String> env = environment ?? Platform.environment;
  if (env[kDesktopCtlDisableEnv]?.trim().toLowerCase() == 'off') return null;
  final String? stateDir = resolveCtlStateDir(
    environment: env,
    operatingSystem: Platform.operatingSystem,
    testRoot: myComicTestRootPath(environment: env),
  );
  if (stateDir == null) {
    debugPrint('[MyComic] ctl channel disabled: no per-user state dir');
    return null;
  }
  final CtlServer server = CtlServer(handler: handler, stateDir: stateDir);
  try {
    final CtlEndpoint endpoint = await server.start();
    debugPrint('[MyComic] ctl channel listening on 127.0.0.1:${endpoint.port}');
    return server;
  } on Object catch (error) {
    debugPrint('[MyComic] ctl channel failed to start: $error');
    return null;
  }
}
