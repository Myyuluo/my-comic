import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Route;

/// 当前媒体页（漫画阅读器 / PDF 阅读器）拥有自己的关闭流程。外部导航必须等它
/// 关闭完成，而不是先把路由弹出、让落盘/关书写入半途而废。
///
/// Ticket 04 从已删除的 Anki source-review 模块中抽出并裁掉查词/复习相关字段；
/// 只保留漫画阅读器退出所需的登记、单飞关闭与共享导航队列。
class ExternalMediaNavigation {
  ExternalMediaNavigation._();
  static final ExternalMediaNavigation instance = ExternalMediaNavigation._();

  /// 测试专用的独立实例（单例的导航队列跨 testWidgets 存活会串 zone）。
  @visibleForTesting
  ExternalMediaNavigation.forTesting();

  Object? _owner;
  Future<bool> Function()? _close;
  bool Function(Route<dynamic> route)? _ownsRoute;
  Future<void> _navigation = Future<void>.value();
  Future<bool>? _closing;

  /// [route] 是不是当前登记的媒体页自己的路由。
  bool ownsRoute(Route<dynamic> route) => _ownsRoute?.call(route) ?? false;

  void register(
    Object owner,
    Future<bool> Function() close, {
    bool Function(Route<dynamic> route)? ownsRoute,
  }) {
    _owner = owner;
    _close = close;
    _ownsRoute = ownsRoute;
  }

  void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _close = null;
    _ownsRoute = null;
  }

  Future<bool> closeActive() async {
    final Future<bool>? pending = _closing;
    if (pending != null) return pending;
    final Future<bool> closing = _close?.call() ?? Future<bool>.value(true);
    _closing = closing;
    try {
      return await closing;
    } finally {
      if (identical(_closing, closing)) _closing = null;
    }
  }

  /// URL 打开与返回按钮共用一条队列，避免两次路由切换都去恢复同一个媒体页。
  Future<void> navigate(Future<void> Function() action) async {
    final Future<void> previous = _navigation;
    final Completer<void> finished = Completer<void>();
    _navigation = finished.future;
    await previous;
    try {
      await action();
    } finally {
      finished.complete();
    }
  }
}
