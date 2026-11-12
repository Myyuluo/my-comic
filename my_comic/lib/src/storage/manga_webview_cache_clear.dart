/// Ticket 12：设置 →「清除缓存」里的 WebView / HTTP 缓存步骤。
///
/// 只清 WebView profile 的 HTTP 响应缓存，**绝不**删除 WebView2 数据目录：
/// cookies、localStorage、IndexedDB、Preferences 都保留。清理走 CDP
/// `Network.clearBrowserCache`（或等价的 cache-only API），因此不需要重启。
///
/// 默认 WebView profile（`state/webview2`）与漫画 WebView profile
/// （`state/webview2-manga*`）各清一次。设置页发起清理时没有可靠的可见
/// WebView 引用，每个 profile 都临时创建 headless WebView（`about:blank`）
/// 执行后销毁。清理只在 Windows（WebView2 / CDP）上可用：其它平台把步骤标记为
/// skipped，整体结果按部分成功提示，而不是静默当作清完了。
///
/// 占用统计只读扫描 CDP `Network.clearBrowserCache` **确实会清理的 HTTP cache
/// 子目录**；GPU / Shader / Dawn / Code Cache 等运行时组件与 cookies /
/// localStorage / IndexedDB / Preferences 等站点数据既不计入也不读取。清理的
/// `freedBytes` 取清理前后这些可清理目录的真实差值，不再硬编码 0。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/manga_cache_clear_service.dart';
import 'package:my_comic/src/utils/misc/error_log_service.dart';

/// 一次 WebView profile 的清缓存会话。
abstract class MangaWebViewCacheSession {
  /// 该会话对应的 profile（默认 / 漫画），只用于诊断日志。
  String get profileId;

  /// 只清 HTTP 响应缓存。实现不得清 cookies / localStorage / IndexedDB。
  Future<void> clearHttpCache();

  /// 销毁临时 headless WebView；复用可见 controller 时必须是 no-op。
  Future<void> dispose();
}

/// 打开某个 profile 的 headless 清缓存会话。
class MangaWebViewCacheSessionSource {
  const MangaWebViewCacheSessionSource({required this.openHeadless});

  /// 临时创建 headless WebView（`about:blank`），用完由步骤销毁。
  final Future<MangaWebViewCacheSession> Function() openHeadless;

  Future<MangaWebViewCacheSession> open() => openHeadless();
}

/// 一个需要清理 HTTP 缓存的 WebView profile。
class MangaWebViewCacheProfile {
  const MangaWebViewCacheProfile({
    required this.id,
    required this.sessionSource,
    this.cacheDirectories = const <Directory>[],
  });

  final String id;
  final MangaWebViewCacheSessionSource sessionSource;

  /// 该 profile 下 CDP 会清理的 HTTP cache 子目录；
  /// [MangaWebViewCacheClearStep.measureBytes] 只读扫描这些目录。为空 = 不参与
  /// 占用统计（例如测试 fake / 解析不到 state 根）。
  final List<Directory> cacheDirectories;
}

/// 依次清理每个 profile；单个 profile 失败不阻断其余 profile。
///
/// [measureBytes] 汇总各 profile 的 HTTP cache 子目录大小，[clear] 用清理前后
/// 的差值报告真实释放量；失败按 [failedEntries] 计入部分成功提示，平台不支持时
/// 整个步骤报告 skipped。
class MangaWebViewCacheClearStep extends MangaCacheClearStep {
  const MangaWebViewCacheClearStep({
    required this.id,
    required this.label,
    required this.profiles,
    this.supported = true,
    this.clearTimeout = const Duration(seconds: 30),
    this.disposeTimeout = const Duration(seconds: 10),
    this.measureDirectories = mangaCacheDirectorySize,
  });

  @override
  final String id;

  @override
  final String label;

  final List<MangaWebViewCacheProfile> profiles;

  /// WebView2 / CDP 清理在当前平台是否可用；false = 跳过并报告 skipped。
  final bool supported;

  /// 单个 CDP 调用 / profile 打开的上限，避免设置页进度框无限等待。
  final Duration clearTimeout;

  /// 临时 WebView 销毁的上限。
  final Duration disposeTimeout;

  /// 目录大小测量缝；默认 [mangaCacheDirectorySize]。测试注入以区分
  /// 「文件系统读失败」（按 0 计）与意外异常（必须继续抛出）。
  @visibleForTesting
  final Future<int> Function(List<Directory> directories) measureDirectories;

  @override
  Future<int> measureBytes() {
    if (!supported) return Future<int>.value(0);
    return _measureClearableBytes();
  }

  /// CDP 实际会清掉的 HTTP cache 总量。
  ///
  /// 只吞文件系统错误（权限 / 并发删除）：占用只是展示，读不到就按 0 计。
  /// 其它异常继续抛出，不被「测量失败按 0 计」掩盖。
  Future<int> _measureClearableBytes() async {
    final List<Directory> directories = <Directory>[
      for (final MangaWebViewCacheProfile profile in profiles)
        ...profile.cacheDirectories,
    ];
    try {
      return await measureDirectories(directories);
    } on FileSystemException catch (error, stack) {
      ErrorLogService.instance.log('MangaWebViewCache.measure', error, stack);
      return 0;
    }
  }

  @override
  Future<MangaCacheClearStepResult> clear() async {
    if (!supported) {
      return MangaCacheClearStepResult(id: id, freedBytes: 0, skipped: true);
    }
    final int before = await _measureClearableBytes();
    int failures = 0;
    for (final MangaWebViewCacheProfile profile in profiles) {
      MangaWebViewCacheSession? session;
      try {
        session = await profile.sessionSource.open().timeout(clearTimeout);
        await session.clearHttpCache().timeout(clearTimeout);
      } on Object catch (error, stack) {
        failures++;
        ErrorLogService.instance.log(
          'MangaWebViewCache.clear:${profile.id}',
          error,
          stack,
        );
      } finally {
        if (session != null) {
          try {
            await session.dispose().timeout(disposeTimeout);
          } on Object catch (error, stack) {
            failures++;
            ErrorLogService.instance.log(
              'MangaWebViewCache.dispose:${profile.id}',
              error,
              stack,
            );
          }
        }
      }
    }
    final int after = await _measureClearableBytes();
    return MangaCacheClearStepResult(
      id: id,
      // 只报告清理前后可清理目录的真实差值。正常渲染重新填充的封面 / 图片
      // 缓存会反映在之后的测量里，但不会被算作这次清理“未完成”或虚报释放量。
      freedBytes: before > after ? before - after : 0,
      failedEntries: failures,
    );
  }
}

/// WebView2 user data folder 下 CDP `Network.clearBrowserCache` 确实会清理的
/// HTTP cache 子目录（相对路径）。
///
/// 只列 HTTP cache：该 CDP 命令最终调用 `NetworkContext::ClearHttpCache`。
/// GPU / Shader / Dawn / Code Cache 属于运行时组件、CDP 不清；cookies /
/// localStorage / IndexedDB / Preferences 等站点数据也不在清理范围，因此它们
/// 既不计入占用，也不会被删除。
const List<String> kMangaWebViewClearableCacheSubdirectories = <String>[
  'EBWebView/Default/Cache',
];

/// 一个 WebView2 user data folder 下会被 CDP 清理的 HTTP cache 子目录。
List<Directory> mangaWebViewClearableCacheDirectories(
  Directory userDataFolder,
) => <Directory>[
  for (final String relative in kMangaWebViewClearableCacheSubdirectories)
    Directory(p.joinAll(<String>[userDataFolder.path, ...relative.split('/')])),
];

/// 生产环境的两个 WebView profile。默认 profile 使用插件的默认 environment
/// （已由 `WebView2StateRoot.install()` 固定到 `state/webview2`）；漫画 profile
/// 复用 [MangaWebViewEnvironment] 当前的 `state/webview2-manga[后缀]`。
///
/// [stateRoot] 为空时按 [AppPaths.stateRootDirectorySync] 解析；解析不到时
/// profile 没有可统计的 cache 目录（占用按 0 计，清理仍可执行）。
///
/// 漫画 profile **只统计当前环境实际使用的那一个目录**：换代理参数后 environment
/// 会落到带哈希后缀的兄弟目录，旧目录不会再被清理，不能继续计入占用。环境尚未
/// 创建时按第一次创建会用的基础目录计——与实际清理集合一致。
///
/// 两个 profile 都走临时 headless WebView：设置页没有可见 WebView 的可靠引用，
/// 而 WebView2 的 HTTP cache 归 environment 所有，同 profile 的 headless 实例
/// 清理的正是共享缓存。
List<MangaWebViewCacheProfile> buildMangaWebViewCacheProfiles({
  Directory? stateRoot,
}) {
  final Directory? root = stateRoot ?? AppPaths.stateRootDirectorySync();
  List<Directory> defaultCacheDirectories = const <Directory>[];
  List<Directory> mangaCacheDirectories = const <Directory>[];
  if (root != null) {
    defaultCacheDirectories = mangaWebViewClearableCacheDirectories(
      Directory(p.join(root.path, AppPaths.webView2DirName)),
    );
    final String? activeMangaFolder =
        MangaWebViewEnvironment.currentUserDataFolder;
    mangaCacheDirectories = mangaWebViewClearableCacheDirectories(
      activeMangaFolder == null
          ? Directory(p.join(root.path, '${AppPaths.webView2DirName}-manga'))
          : Directory(activeMangaFolder),
    );
  }
  return <MangaWebViewCacheProfile>[
    MangaWebViewCacheProfile(
      id: 'default',
      sessionSource: MangaWebViewCacheSessionSource(
        openHeadless: () =>
            MangaWebViewCdpCacheSession.headless(profileId: 'default'),
      ),
      cacheDirectories: defaultCacheDirectories,
    ),
    MangaWebViewCacheProfile(
      id: 'manga',
      sessionSource: MangaWebViewCacheSessionSource(
        openHeadless: () async {
          final WebViewEnvironment? environment =
              await MangaWebViewEnvironment.obtain();
          if (environment == null) {
            throw StateError('Manga WebView environment is unavailable');
          }
          return MangaWebViewCdpCacheSession.headless(
            profileId: 'manga',
            environment: environment,
          );
        },
      ),
      cacheDirectories: mangaCacheDirectories,
    ),
  ];
}

/// 通过 CDP 清 HTTP 缓存的会话。
///
/// 只调用 `Network.clearBrowserCache`；不调用
/// `Network.clearBrowserCookies` / `Storage.clearDataForOrigin` 等会破坏登录态
/// 的 API。
class MangaWebViewCdpCacheSession implements MangaWebViewCacheSession {
  MangaWebViewCdpCacheSession({
    required this.profileId,
    required MangaWebViewCdpCall callDevToolsProtocolMethod,
    required Future<void> Function() disposeWebView,
  }) : _callDevToolsProtocolMethod = callDevToolsProtocolMethod,
       _disposeWebView = disposeWebView;

  /// Chromium DevTools Protocol 的 cache-only 清理命令。
  static const String clearBrowserCacheMethod = 'Network.clearBrowserCache';

  /// headless WebView 创建 + `onWebViewCreated` 的上限。
  static const Duration defaultCreationTimeout = Duration(seconds: 20);

  @override
  final String profileId;

  final MangaWebViewCdpCall _callDevToolsProtocolMethod;
  final Future<void> Function() _disposeWebView;

  @override
  Future<void> clearHttpCache() async {
    await _callDevToolsProtocolMethod(clearBrowserCacheMethod);
  }

  @override
  Future<void> dispose() => _disposeWebView();

  /// 临时 headless WebView（`about:blank`）会话；销毁由 [dispose] 负责。
  static Future<MangaWebViewCdpCacheSession> headless({
    required String profileId,
    WebViewEnvironment? environment,
    Duration timeout = defaultCreationTimeout,
  }) async {
    final Completer<InAppWebViewController> controllerReady =
        Completer<InAppWebViewController>();
    final HeadlessInAppWebView webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri('about:blank')),
      webViewEnvironment: environment,
      onWebViewCreated: (InAppWebViewController controller) {
        if (!controllerReady.isCompleted) controllerReady.complete(controller);
      },
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) {
            if (!controllerReady.isCompleted) {
              controllerReady.completeError(
                StateError('WebView renderer gone: $detail'),
              );
            }
          },
    );
    Future<InAppWebViewController> create() async {
      await webView.run();
      return controllerReady.future;
    }

    try {
      final InAppWebViewController controller = await create().timeout(timeout);
      return MangaWebViewCdpCacheSession(
        profileId: profileId,
        callDevToolsProtocolMethod: (String methodName) =>
            controller.callDevToolsProtocolMethod(methodName: methodName),
        disposeWebView: webView.dispose,
      );
    } on Object {
      // run 成功但 onWebViewCreated 没来 / renderer 死亡：别把 headless
      // WebView 留在进程里。
      try {
        await webView.dispose();
      } on Object {
        // 销毁失败只能放弃；创建失败本身已经会作为该 profile 的失败上报。
      }
      rethrow;
    }
  }
}

/// CDP 调用缝：生产实现是 `controller.callDevToolsProtocolMethod`。
typedef MangaWebViewCdpCall = Future<dynamic> Function(String methodName);
