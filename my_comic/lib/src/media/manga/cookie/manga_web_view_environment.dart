import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:my_comic/src/storage/app_paths.dart';
import 'package:my_comic/src/storage/webview2_state_root.dart';
import 'package:my_comic/src/utils/misc/error_log_service.dart';
import 'package:my_comic_engine/utils/net/app_proxy.dart';

/// 漫画源的「站点浏览器」页（源站登录、Cloudflare 解题）在 Windows 上共用的
/// WebView2 环境（BUG-2477 / BUG-2478）。
///
/// ## 为什么必须有一个显式环境
///
/// 这两页都靠 [CookieManager] 把浏览器里的会话导出给运行时。WebView2 的 cookie
/// 归**环境**（user data folder）所有；fork 里裸 `InAppWebView`（不传环境）走
/// 插件的默认建站点、裸 `CookieManager.instance()` 走 `WebViewEnvironmentManager`
/// 自己另建的默认环境——两处对着**同一个** user data folder 用**不同的**浏览器参数
/// 建环境，WebView2 拒绝第二个（`0x8007139F`），于是登录页明明已经登录，点「完成」
/// 却「没有捕获到会话 cookie」；Cloudflare 页同理永远轮询不到 `cf_clearance`。
///
/// 让 WebView 和 CookieManager 绑**同一个**显式环境，这类不一致就从结构上消失。
/// 独立 user data folder 也让站点登录态与阅读器 / 网页视频那两套 WebView 互不
/// 串扰。
///
/// ## 代理
///
/// WebView2 默认跟系统代理，与 app 自己的代理设置无关（BUG-2478）。浏览器参数是
/// 唯一能把出口交给它的地方，且**只能在建环境时给**：所以按参数串缓存环境，参数
/// 变了（用户改了代理设置）就换一个环境。同一 user data folder 不能被两套参数
/// 同时占着，故换环境时先 dispose 旧的；WebView2 的浏览器进程在最后一个视图关闭
/// 后才退出，dispose 后立刻重建**同一目录**可能仍撞 `0x8007139F`，那时退到按参数
/// 派生的兄弟目录（登录态因此要重登一次——只在改代理后发生一次，可接受）。
///
/// 手动代理的 Basic 认证凭据**接不进去**：WebView2 的代理认证走
/// `BasicAuthenticationRequested`，本 fork 没有暴露它。局域网/本机代理绝大多数
/// 不要认证，先不为它引一层原生改动。
abstract final class MangaWebViewEnvironment {
  static Future<WebViewEnvironment?>? _pending;
  static WebViewEnvironment? _current;
  static String? _currentArguments;

  /// 当前活动的漫画环境实际使用的 user data folder；从未成功创建过为 null。
  ///
  /// 「清除缓存」只统计这个目录下的 HTTP cache：换代理参数后 environment 会落到
  /// 带哈希后缀的兄弟目录，旧目录不会再被清理，不能继续计入占用。
  static String? _currentUserDataFolder;

  /// 当前漫画环境的 user data folder（诊断 / 清缓存计量）。null = 尚未创建。
  static String? get currentUserDataFolder => _currentUserDataFolder;

  /// 测试注入「当前环境目录」，不真的创建 WebView2 环境。
  @visibleForTesting
  static void debugSetCurrentUserDataFolder(String? path) {
    _currentUserDataFolder = path;
  }

  /// 测试 / 非 Windows 的旁路：返回 null = 让 `InAppWebView` 与 `CookieManager`
  /// 都走各自的平台默认（Android / iOS / macOS 那边 cookie 由系统 WebView 持有，
  /// 本来就是同一份）。
  @visibleForTesting
  static Future<WebViewEnvironment?> Function()? override;

  /// 本次应交给 WebView2 的代理参数；空串 = 跟系统代理（`auto` 且没查到代理）。
  ///
  /// 抽成纯函数以便直接断言：`direct` 必须显式 `--no-proxy-server`，否则「用户选了
  /// 直连、浏览器却偷用系统代理」和 [resolveAppProxyDirective] 的裁决相悖。
  static String proxyArguments({
    required String mode,
    required String? proxyHostPort,
  }) {
    if (mode == kProxyModeDirect) return '--no-proxy-server';
    if (proxyHostPort == null || proxyHostPort.isEmpty) return '';
    return '--proxy-server=$proxyHostPort';
  }

  static String _userDataFolder({String suffix = ''}) {
    final String? testFolder =
        Platform.environment['MYCOMIC_WEBVIEW2_USER_DATA_FOLDER'];
    if (testFolder != null && testFolder.isNotEmpty) {
      return '$testFolder-manga$suffix';
    }
    // Ticket 02：WebView2 数据属于 Portable state。默认 environment 由
    // `WebView2StateRoot.install()` 指到 `<state>/webview2`；Dart 侧
    // `Platform.environment` 是启动快照、看不到那次进程内设置，所以这里直接按
    // AppPaths 解析 state 根，用同根的独立兄弟目录。
    final Directory? stateRoot = AppPaths.stateRootDirectorySync();
    if (stateRoot != null) {
      return WebView2StateRoot.mangaUserDataFolderFor(
        stateRoot.path,
        suffix: suffix,
      );
    }
    final String base = Platform.environment['LOCALAPPDATA'] ?? '.';
    return '$base\\MyComic\\MangaWebView2$suffix';
  }

  /// 取当前代理设置下的环境；非 Windows 返回 null。
  static Future<WebViewEnvironment?> obtain() {
    final Future<WebViewEnvironment?> Function()? injected = override;
    if (injected != null) return injected();
    if (!Platform.isWindows) return Future<WebViewEnvironment?>.value();
    final String arguments = proxyArguments(
      mode: appUserProxyModeReader(),
      proxyHostPort: resolveAppProxyHostPort(),
    );
    final Future<WebViewEnvironment?>? pending = _pending;
    if (pending != null && _currentArguments == arguments) return pending;
    final Future<WebViewEnvironment?> started = _create(arguments);
    _pending = started;
    _currentArguments = arguments;
    // 建不出来（0x8007139F 之类）不能把 null 钉进缓存：下一次打开页面要能重试，
    // 否则一次失败就是整个会话里所有登录页都退回默认环境。
    started.then((WebViewEnvironment? env) {
      if (env == null && identical(_pending, started)) {
        _pending = null;
        _currentArguments = null;
      }
    });
    return started;
  }

  static Future<WebViewEnvironment?> _create(String arguments) async {
    final WebViewEnvironment? previous = _current;
    _current = null;
    _currentUserDataFolder = null;
    if (previous != null) {
      try {
        await previous.dispose();
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaWebViewEnvironment.dispose',
          error,
          stack,
        );
      }
    }
    for (final String suffix in <String>[
      '',
      '-${arguments.hashCode.toRadixString(16)}',
    ]) {
      try {
        final WebViewEnvironment created = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: _userDataFolder(suffix: suffix),
            additionalBrowserArguments: arguments.isEmpty ? null : arguments,
          ),
        );
        _current = created;
        _currentUserDataFolder = _userDataFolder(suffix: suffix);
        return created;
      } on MissingPluginException {
        // 没有平台实现（widget 测试）：走默认。
        return null;
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaWebViewEnvironment.create[$suffix]',
          error,
          stack,
        );
      }
    }
    return null;
  }
}
