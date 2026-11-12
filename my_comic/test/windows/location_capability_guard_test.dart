// BUG-1887 源码守卫：Windows 上 MyComic 不得在启动时占用系统定位能力。
//
// 症状：Windows「设置 → 隐私和安全性 → 定位」把 MyComic.exe 列成「正在使用定位」，
// 从 app 启动那一秒起、退出才停。用户看到的就是「这个 app 在读我的位置」。
//
// 根因**不是** WebView2（一开始的直觉方向），也**不是**有功能在读位置：
// `permission_handler_windows` 0.1.2 的插件**构造函数**无条件订阅
// `Geolocator::PositionChanged`（回调体是空的）。订阅 = 让 Windows 开一个持续的
// 定位会话，而插件对象在 `RegisterPlugins()` 期间构造 —— 于是启动 0.7s 内
// CapabilityAccessManager 就记下 LastUsedTimeStart、Stop=0，直到进程退出。
//
// 实测判别（见 docs/bugs/BUG-1887-...md）：把所有 WebView2 环境创建全部弄失败、
// 零个 msedgewebview2.exe 子进程，账本照样写 —— 与 WebView2 无关。
//
// 修复分两件**不同**的事，缺一不可，所以这里分两组断言：
//   ① vendored permission_handler_windows：Geolocator + 订阅推迟到唯一读它的地方
//      （checkServiceStatus(LOCATION*)）。MyComic 的 Windows 端从不问，于是永远不开
//      定位会话。这是消掉系统显示的那一层。
//   ② runner 自有的两个裸 WebView2（app 外查词浮窗 + 剪贴板面板）装权限拒绝门，
//      拦**页面运行期**发起的定位/麦克风/摄像头请求。in-app 的 fork 早有这道门，
//      这两个窗一直没有。它修不掉 ① 的显示，但没有它，将来任意 HTML 内容都能
//      弹系统权限提示条。
//
// C++ 与 pubspec 在 Dart 测试里跑不了，所以在源码层锁定。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// workspace 根 pubspec —— pub workspace 只认根 pubspec 的 dependency_overrides。
const String _rootPubspecPath = '../pubspec.yaml';

/// runner 自有的原生覆盖窗（app 外查词浮窗 + 剪贴板面板共用这份实现）。
const String _runnerOverlayPath = 'windows/runner/global_lookup_window.cpp';

/// 取出顶层函数 [signature] 的函数体源码（到下一个顶层 `}` 为止）。
/// 在 main() 顶层调用，故不能用 expect（那是 OutsideTestException），直接抛。
String _topLevelBody(String src, String signature, String path) {
  final int start = src.indexOf(signature);
  if (start < 0) {
    throw StateError('$path 里必须有 `$signature`（守卫依赖它作为锚点）');
  }
  final int end = src.indexOf('\n}', start + signature.length);
  return src.substring(start, end == -1 ? src.length : end);
}

void main() {
  late String rootPubspec;
  late String overlay;

  setUpAll(() {
    rootPubspec = File(_rootPubspecPath).readAsStringSync();
    overlay = File(_runnerOverlayPath).readAsStringSync();
  });

  group('① permission_handler 不再进入 Windows 构建', () {
    test('根 pubspec 不再 override permission_handler_windows', () {
      expect(
        rootPubspec.contains('permission_handler'),
        isFalse,
        reason: 'permission_handler 只服务移动端存储/相机权限；Windows-only 后它已从'
            '依赖中移除，不应再出现 override——没有插件注册就绝不会开定位会话',
      );
    });

    test('Windows 插件注册表不注册 PermissionHandlerWindowsPlugin', () {
      final String registrant = File(
        'windows/flutter/generated_plugin_registrant.cc',
      ).readAsStringSync();
      expect(
        registrant.contains('PermissionHandlerWindowsPlugin'),
        isFalse,
        reason: '插件一旦重新注册，构造函数里的 Geolocator 订阅会让 Windows 从启动'
            '到退出一直记「正在使用定位」（BUG-1887）；Windows-only 构建不应再有它',
      );
    });
  });

  group('② 原生浮窗拒绝网页发起的权限请求', () {
    test('ConfigureWebView 装了 PermissionRequested 门并 DENY', () {
      final String configure = _topLevelBody(
        overlay,
        'void GlobalLookupWindow::ConfigureWebView()',
        _runnerOverlayPath,
      );
      expect(
        configure.contains('add_PermissionRequested'),
        isTrue,
        reason: 'ConfigureWebView 是两条创建路径（composition / windowed）+ '
            'BUG-693 自愈重建的唯一漏斗；不在这里装门，WebView2 的默认行为是'
            '弹系统权限提示条，而这个窗是无边框置顶浮窗还开了防截屏',
      );
      expect(
        configure.contains('COREWEBVIEW2_PERMISSION_STATE_DENY'),
        isTrue,
        reason: '装了 handler 却不 put_State(DENY) 等于什么都没做',
      );
    });

    test('in-app fork 侧的既有兜底没被删', () {
      final String fork = File(
        '../packages/flutter_inappwebview_windows/windows/in_app_webview/'
        'in_app_webview.cpp',
      ).readAsStringSync();
      expect(
        fork.contains('add_PermissionRequested'),
        isTrue,
        reason: 'fork 这道门比 BUG-1887 早就存在（Dart 不接管时 put_State(DENY)），'
            '是 app 内阅读器/词典 WebView 的兜底',
      );
    });
  });
}
