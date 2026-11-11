import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';

/// 自动续签尝试时间的持久化存储（票 04 的 24 小时冷却）。
///
/// 与书架封面字节缓存（[MangaShelfCoverCache]）同目录、同按 bookKey 的 sha256
/// 摘要命名，但**归本文件所有**：缓存只负责字节与容量淘汰。`clear()` 删除整个
/// Program state 缓存目录时 `.renew` 侧车一并清除，用户主动清缓存后允许重新
/// 尝试续签。
class MangaShelfCoverRenewalStore {
  const MangaShelfCoverRenewalStore(this.directory);

  /// Program state 的 shelf cover 缓存目录。
  final Directory directory;

  File attemptPathFor(String bookKey) =>
      File(p.join(directory.path, '${_keyOf(bookKey)}.renew'));

  /// 上次自动续签尝试时刻；没有记录、记录损坏或读盘失败返回 null。
  Future<DateTime?> lastAttempt(String bookKey) async {
    try {
      final File file = attemptPathFor(bookKey);
      if (!await file.exists()) return null;
      final int? millis = int.tryParse((await file.readAsString()).trim());
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } on FileSystemException {
      return null;
    }
  }

  /// 记录一次自动续签尝试（源站真实失败或成功），跨启动维持 24 小时冷却。
  ///
  /// 写盘失败按「没有冷却记录」处理：宁可下次启动多试一次，也不阻断封面自愈。
  Future<void> recordAttempt(String bookKey, DateTime at) async {
    try {
      await directory.create(recursive: true);
      await attemptPathFor(
        bookKey,
      ).writeAsString('${at.millisecondsSinceEpoch}', flush: true);
    } on FileSystemException {
      // 尽力而为。
    }
  }

  static String _keyOf(String bookKey) =>
      sha256.convert(utf8.encode(bookKey)).toString();
}

/// 一次已获准的自动续签尝试。
///
/// 拿到 permit 只代表「本次启动还没试过 + 不在 24 小时冷却窗内」；尝试时间
/// **不在获准时落盘**：只有源站给出了真实结果（成功，或 403/500 这类真实失败）
/// 才 [recordAttempt]。网络不可用 / 连接失败调用 [release]，把本次启动的
/// in-process 名额还回去——网络恢复后同一本书仍能在本次启动续签一次。
class MangaShelfCoverRenewalPermit {
  const MangaShelfCoverRenewalPermit._({
    required this.bookKey,
    required this.store,
    required this.attemptedAt,
  });

  final String bookKey;
  final MangaShelfCoverRenewalStore store;
  final DateTime attemptedAt;

  /// 持久化这次尝试（成功或源站真实失败都算），写入 24 小时冷却。
  Future<void> recordAttempt() => store.recordAttempt(bookKey, attemptedAt);

  /// 网络不可用 / 连接失败：不写冷却，并释放在本次启动占用的续签名额。
  void release() => MangaShelfCoverRenewalThrottle._release(bookKey);
}

/// 封面 URL 失败驱动自动续签的节流器。
///
/// 两道闸一起用：
/// - **每次应用启动最多一次**：进程级集合，防止书架每次重算 / 同一轮多次失败
///   回调把坏 Source 打成请求循环。书架每次解析都会新建
///   `MangaShelfCoverService`，所以状态必须放在进程级而不是服务实例上。
/// - **24 小时冷却**：尝试时间写在 Program state 封面缓存目录的 `.renew` 侧车
///   （按 bookKey 摘要命名），跨启动仍然生效。
///
/// 离线（网络不可用 / 连接失败）**不消耗**这两道闸：不落盘冷却，并释放本次
/// 启动名额，网络恢复后还能再试一次。源站真实失败（403/500 等）与成功按既有
/// 策略计入冷却。
class MangaShelfCoverRenewalThrottle {
  MangaShelfCoverRenewalThrottle._();

  /// 同一本书两次自动续签尝试之间的最小间隔。
  static const Duration cooldown = Duration(hours: 24);

  static final Set<String> _attemptedThisLaunch = <String>{};

  /// 是否允许为 [bookKey] 发起一次自动续签；允许时返回 permit，调用方必须
  /// 根据结果 [MangaShelfCoverRenewalPermit.recordAttempt] 或
  /// [MangaShelfCoverRenewalPermit.release]。返回 null = 本次启动已试过，或
  /// 距上次尝试不足 [cooldown]。
  ///
  /// 不抛异常：节流存储不可用按「没有冷却记录」处理，仍允许这一次（宁可多试
  /// 一次也不让封面永远无法自愈）；[debugReset] 供测试隔离进程级状态。
  static Future<MangaShelfCoverRenewalPermit?> tryAcquire({
    required MangaShelfCoverCache cache,
    required String bookKey,
    DateTime? now,
  }) async {
    // 先同步占位：并发的重复失败回调不得发出第二个续签请求。
    if (!_attemptedThisLaunch.add(bookKey)) return null;
    final DateTime attemptedAt = now ?? DateTime.now();
    final MangaShelfCoverRenewalStore store = MangaShelfCoverRenewalStore(
      cache.directory,
    );
    try {
      final DateTime? last = await store.lastAttempt(bookKey);
      if (last != null &&
          attemptedAt.difference(last) < cooldown &&
          !attemptedAt.isBefore(last)) {
        // 冷却窗内：保留本次启动的占位，后续调用直接短路（不读盘、不请求）。
        return null;
      }
    } on Object {
      // 冷却存储不可用：按「没有冷却记录」处理，本次启动仍只尝试这一次。
    }
    return MangaShelfCoverRenewalPermit._(
      bookKey: bookKey,
      store: store,
      attemptedAt: attemptedAt,
    );
  }

  /// 网络不可用 / 连接失败（或连接级超时）——不是源站给出的真实失败。
  ///
  /// 只认传输层错误与明确的连接失败文本；403 / 500 等 HTTP 失败不在此列，
  /// 仍按既有策略计入 24 小时冷却。
  static bool isOfflineFailure(Object? error) => _isOffline(error, 0);

  static bool _isOffline(Object? error, int depth) {
    if (error == null || depth > 4) return false;
    if (error is SocketException ||
        error is HandshakeException ||
        error is TimeoutException) {
      return true;
    }
    if (error is OnlineMangaUnavailable) {
      return _isOffline(error.cause, depth + 1) ||
          _hasOfflineMarker(error.message);
    }
    return _hasOfflineMarker('$error');
  }

  static bool _hasOfflineMarker(String text) {
    final String lower = text.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('host lookup failed') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('connection closed') ||
        lower.contains('network is unreachable') ||
        lower.contains('network unreachable') ||
        lower.contains('network is down') ||
        lower.contains('broken pipe') ||
        lower.contains('handshake failed');
  }

  static void _release(String bookKey) => _attemptedThisLaunch.remove(bookKey);

  /// 测试缝：避免进程内其它用例的续签尝试影响断言。
  @visibleForTesting
  static void debugReset() => _attemptedThisLaunch.clear();
}
