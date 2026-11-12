import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/storage/app_paths.dart';

/// Ticket 02：把 WebView2 的 user data folder 固定到 Program state root 的
/// `state/webview2`，让站点登录态、cookie 等 WebView 数据随「程序目录 + userdata」
/// 一起便携拷贝，而不是留在用户级默认位置。
///
/// 为什么走环境变量：WebView2 的 user data folder 只能在创建 environment 时给一次。
/// 本仓库多数 WebView 走 flutter_inappwebview 的**默认 environment**，而插件的
/// Windows 原生实现把 `MYCOMIC_WEBVIEW2_USER_DATA_FOLDER` 当作默认 environment 的
/// folder（原本只服务集成测试隔离）。在 `main()` 里、任何 WebView 创建之前用
/// `SetEnvironmentVariableW` 设置它，默认 environment 与显式传入 folder 的
/// [MangaWebViewEnvironment] 就能落在同一个 state 根下。
///
/// 必须在进程内改环境而不是 `Platform.environment`：后者是只读快照，且 WebView2
/// 原生侧用 `GetEnvironmentVariableW` 读取当前进程环境。
class WebView2StateRoot {
  WebView2StateRoot._();

  /// 插件原生侧读取的变量名（见 `in_app_webview.cpp` /
  /// `webview_environment.cpp` 的 `OptionalEnvWide`）。
  static const String userDataFolderEnvironmentVariable =
      'MYCOMIC_WEBVIEW2_USER_DATA_FOLDER';

  /// `<stateRoot>/webview2` —— 默认 environment 的 user data folder。
  static String userDataFolderFor(String stateRootPath) =>
      p.join(stateRootPath, AppPaths.webView2DirName);

  /// `<stateRoot>/webview2-manga[ suffix]` —— 漫画站点浏览器（登录 / Cloudflare）
  /// 独立 environment 的 user data folder。与默认 environment 同住 state 根，
  /// 但保持独立目录，站点登录态不与阅读器 / 视频 WebView 串扰。
  static String mangaUserDataFolderFor(
    String stateRootPath, {
    String suffix = '',
  }) =>
      p.join(stateRootPath, '${AppPaths.webView2DirName}-manga$suffix');

  /// 测试注入：避免真的改进程环境；返回 false 模拟设置失败。
  @visibleForTesting
  static bool Function(String name, String value)? debugSetEnvironmentVariable;

  /// 安装/刷新环境变量。返回是否已指向 state 根。
  ///
  /// [stateRoot] 缺省时按 [AppPaths.stateRootDirectorySync] 解析（测试根 / exe
  /// 同级 userdata / LOCALAPPDATA 回退）。不是 Windows、或解析不出 state 根时
  /// no-op 返回 false。
  static bool install({Directory? stateRoot, bool? isWindows}) {
    if (!(isWindows ?? Platform.isWindows)) return false;
    final Directory? root = stateRoot ?? AppPaths.stateRootDirectorySync();
    if (root == null) return false;
    try {
      root.createSync(recursive: true);
    } on FileSystemException {
      return false;
    }
    final bool Function(String, String) setter =
        debugSetEnvironmentVariable ?? _setWindowsEnvironmentVariable;
    return setter(
      userDataFolderEnvironmentVariable,
      userDataFolderFor(root.path),
    );
  }

  /// 清掉测试注入，避免跨测试泄漏。
  @visibleForTesting
  static void debugReset() {
    debugSetEnvironmentVariable = null;
  }

  static bool _setWindowsEnvironmentVariable(String name, String value) {
    if (!Platform.isWindows) return false;
    try {
      final DynamicLibrary kernel32 = DynamicLibrary.open('kernel32.dll');
      final _SetEnvironmentVariableDart setEnvironmentVariable = kernel32
          .lookupFunction<
            _SetEnvironmentVariableNative,
            _SetEnvironmentVariableDart
          >('SetEnvironmentVariableW');
      final Pointer<Utf16> nativeName = name.toNativeUtf16();
      final Pointer<Utf16> nativeValue = value.toNativeUtf16();
      try {
        return setEnvironmentVariable(nativeName, nativeValue) != 0;
      } finally {
        calloc.free(nativeName);
        calloc.free(nativeValue);
      }
    } on Object catch (error) {
      debugPrint('[WebView2StateRoot] SetEnvironmentVariableW failed: $error');
      return false;
    }
  }
}

typedef _SetEnvironmentVariableNative =
    Int32 Function(Pointer<Utf16> name, Pointer<Utf16> value);
typedef _SetEnvironmentVariableDart =
    int Function(Pointer<Utf16> name, Pointer<Utf16> value);
