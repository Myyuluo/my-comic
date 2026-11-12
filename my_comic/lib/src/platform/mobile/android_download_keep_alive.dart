/// 下载保活的唯一 Dart 门面（my-comic Windows-only）。
///
/// Android 上曾用前台服务在用户切走后保活下载；平台裁剪后 Windows 桌面进程
/// 不需要这层保活，[createDownloadKeepAlive] 恒返回 [NoopDownloadKeepAlive]。
/// 保留接口与租约汇总逻辑，调用方（漫画下载、更新检查）无需感知平台。
///
/// 所有下载结束（完成 / 失败 / 取消）后必须 [DownloadKeepAlive.stop]。
library;

import 'dart:async';
import 'package:flutter/foundation.dart';

/// 通知进度条的「不确定」取值（原生侧画转圈而不是进度条）。
const int kDownloadKeepAliveIndeterminate = -1;

/// 进度更新的默认最小间隔：下载进度回调可能每个分块一次，全部过通道没有意义。
const Duration kDownloadKeepAliveMinInterval = Duration(milliseconds: 500);

/// 下载保活门面。
abstract interface class DownloadKeepAlive {
  /// 开始（尚未保活时）或更新保活通知。[percent] 为 null / 越界时显示不确定进度。
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  });

  /// 结束保活并移除通知。未在保活时是 no-op。
  Future<void> stop();
}

/// my-comic 是 Windows-only：没有 Android 前台服务，恒用 no-op 实现。
DownloadKeepAlive createDownloadKeepAlive() => const NoopDownloadKeepAlive();

/// Windows 实现：什么也不做，也不发任何通道调用。
class NoopDownloadKeepAlive implements DownloadKeepAlive {
  const NoopDownloadKeepAlive();

  @override
  Future<void> update({
    required String title,
    required String text,
    int? percent,
  }) async {}

  @override
  Future<void> stop() async {}
}

/// 一次要显示的通知状态。[percent] 已归一化：`0..100` 或
/// [kDownloadKeepAliveIndeterminate]。
@immutable
class DownloadKeepAliveState {
  const DownloadKeepAliveState({
    required this.title,
    required this.text,
    required this.percent,
  });

  /// 归一化构造：null / 越界 / 负数一律当作不确定进度。
  factory DownloadKeepAliveState.normalized({
    required String title,
    required String text,
    int? percent,
  }) {
    final int value = percent == null || percent < 0 || percent > 100
        ? kDownloadKeepAliveIndeterminate
        : percent;
    return DownloadKeepAliveState(title: title, text: text, percent: value);
  }

  final String title;
  final String text;
  final int percent;

  @override
  bool operator ==(Object other) =>
      other is DownloadKeepAliveState &&
      other.title == title &&
      other.text == text &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(title, text, percent);

  @override
  String toString() =>
      'DownloadKeepAliveState($title, $text, percent: $percent)';
}

/// [DownloadKeepAliveThrottle.onUpdate] 的裁决。
enum DownloadKeepAliveAction {
  /// 立刻发。
  send,

  /// 先不发，[DownloadKeepAliveDecision.delay] 之后再发最新状态。
  defer,

  /// 与已发出的状态相同，不必发。
  skip,
}

/// 一次裁决：动作 + （仅 defer 时有意义的）延迟。
@immutable
class DownloadKeepAliveDecision {
  const DownloadKeepAliveDecision(this.action, [this.delay = Duration.zero]);

  final DownloadKeepAliveAction action;
  final Duration delay;

  @override
  bool operator ==(Object other) =>
      other is DownloadKeepAliveDecision &&
      other.action == action &&
      other.delay == delay;

  @override
  int get hashCode => Object.hash(action, delay);

  @override
  String toString() => 'DownloadKeepAliveDecision($action, $delay)';
}

/// 去重 + 节流的纯逻辑（无通道、无定时器，时钟可注入）。
///
/// 规则：
/// * 与上一次发出的状态相同 → skip；
/// * 未在保活（启动）→ 立即 send，不受节流约束；
/// * 距上一次发送不足 [minInterval] → defer 到间隔满；否则 send；
/// * stop 只在保活中时才需要发，发完回到未保活。
class DownloadKeepAliveThrottle {
  DownloadKeepAliveThrottle({
    DateTime Function()? now,
    this.minInterval = kDownloadKeepAliveMinInterval,
  }) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration minInterval;

  DownloadKeepAliveState? _lastSent;
  DateTime? _lastSentAt;

  /// 是否在保活中（已发出过 update 且之后没有 stop）。
  bool get isActive => _lastSent != null;

  /// 最近一次发出的状态。
  DownloadKeepAliveState? get lastSent => _lastSent;

  /// 对一条新状态做裁决。不改内部状态；真正发出后调用 [markSent]。
  DownloadKeepAliveDecision onUpdate(DownloadKeepAliveState state) {
    final DownloadKeepAliveState? last = _lastSent;
    if (last == null) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.send);
    }
    if (last == state) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.skip);
    }
    final Duration elapsed = _now().difference(_lastSentAt ?? _now());
    if (elapsed >= minInterval) {
      return const DownloadKeepAliveDecision(DownloadKeepAliveAction.send);
    }
    return DownloadKeepAliveDecision(
      DownloadKeepAliveAction.defer,
      minInterval - elapsed,
    );
  }

  /// 记录一次已发出的 update。
  void markSent(DownloadKeepAliveState state) {
    _lastSent = state;
    _lastSentAt = _now();
  }

  /// 处理 stop：返回是否需要发 stop（保活中才需要），并回到未保活。
  bool onStop() {
    final bool wasActive = _lastSent != null;
    _lastSent = null;
    _lastSentAt = null;
    return wasActive;
  }
}
