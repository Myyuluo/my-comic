/// Ticket 12：设置 →「清除缓存」里的 WebView / HTTP 缓存步骤。
///
/// 只清 WebView profile 的 HTTP 响应缓存，**绝不**删除 WebView2 数据目录：
/// cookies、localStorage、IndexedDB、Preferences 都保留。清理走 CDP
/// `Network.clearBrowserCache`（或等价的 cache-only API），因此不需要重启。
///
/// 默认 WebView profile（`state/webview2`）与漫画 WebView profile
/// （`state/webview2-manga*`）各清一次。设置页发起清理时没有可靠的可见
/// WebView 引用，步骤默认临时创建 headless WebView（`about:blank`）执行后销毁；
/// [MangaWebViewCacheSessionSource.findVisible] 为将来复用可见 controller 预留。
library;

import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/storage/manga_cache_clear_service.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 一次 WebView profile 的清缓存会话。
abstract class MangaWebViewCacheSession {
  /// 该会话对应的 profile（默认 / 漫画），只用于诊断日志。
  String get profileId;

  /// 只清 HTTP 响应缓存。实现不得清 cookies / localStorage / IndexedDB。
  Future<void> clearHttpCache();

  /// 销毁临时 headless WebView；复用可见 controller 时必须是 no-op。
  Future<void> dispose();
}

/// 打开某个 profile 的清缓存会话：优先复用可见 WebView，没有时建 headless。
class MangaWebViewCacheSessionSource {
  const MangaWebViewCacheSessionSource({
    required this.openHeadless,
    this.findVisible,
  });

  /// 没有可见 WebView 时临时创建 headless WebView（`about:blank`）。
  final Future<MangaWebViewCacheSession> Function() openHeadless;

  /// 可见 WebView 查找缝；返回 null 表示当前没有可复用的可见 WebView。
  final Future<MangaWebViewCacheSession?> Function()? findVisible;

  Future<MangaWebViewCacheSession> open() async {
    final MangaWebViewCacheSession? visible = await findVisible?.call();
    if (visible != null) return visible;
    return openHeadless();
  }
}

/// 一个需要清理 HTTP 缓存的 WebView profile。
class MangaWebViewCacheProfile {
  const MangaWebViewCacheProfile({
    required this.id,
    required this.sessionSource,
  });

  final String id;
  final MangaWebViewCacheSessionSource sessionSource;
}

/// 依次清理每个 profile；单个 profile 失败不阻断其余 profile。
///
/// WebView HTTP 缓存大小无法在不读取用户数据的前提下安全统计，因此
/// [measureBytes] 返回 0（不计入副标题占用）；失败按 [failedEntries] 计入
/// 部分成功提示。
class MangaWebViewCacheClearStep extends MangaCacheClearStep {
  const MangaWebViewCacheClearStep({
    required this.id,
    required this.label,
    required this.profiles,
    this.clearTimeout = const Duration(seconds: 30),
    this.disposeTimeout = const Duration(seconds: 10),
  });

  @override
  final String id;

  @override
  final String label;

  final List<MangaWebViewCacheProfile> profiles;

  /// 单个 CDP 调用 / profile 打开的上限，避免设置页进度框无限等待。
  final Duration clearTimeout;

  /// 临时 WebView 销毁的上限。
  final Duration disposeTimeout;

  @override
  Future<int> measureBytes() async => 0;

  @override
  Future<MangaCacheClearStepResult> clear() async {
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
    return MangaCacheClearStepResult(
      id: id,
      freedBytes: 0,
      failedEntries: failures,
    );
  }
}

/// 生产环境的两个 WebView profile。默认 profile 使用插件的默认 environment
/// （已由 `WebView2StateRoot.install()` 固定到 `state/webview2`）；漫画 profile
/// 复用 [MangaWebViewEnvironment] 的 `state/webview2-manga*`。
///
/// 两个 profile 都走临时 headless WebView：设置页没有可见 WebView 的可靠引用，
/// 而 WebView2 的 HTTP cache 归 environment 所有，同 profile 的 headless 实例
/// 清理的正是共享缓存。
List<MangaWebViewCacheProfile> buildMangaWebViewCacheProfiles() {
  return <MangaWebViewCacheProfile>[
    MangaWebViewCacheProfile(
      id: 'default',
      sessionSource: MangaWebViewCacheSessionSource(
        openHeadless: () =>
            MangaWebViewCdpCacheSession.headless(profileId: 'default'),
      ),
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
