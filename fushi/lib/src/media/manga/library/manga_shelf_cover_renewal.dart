import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';

/// 封面 URL 失败驱动自动续签的节流器。
///
/// 两道闸一起用：
/// - **每次应用启动最多一次**：进程级集合，防止书架每次重算 / 同一轮多次失败
///   回调把坏 Source 打成请求循环。书架每次解析都会新建
///   `MangaShelfCoverService`，所以状态必须放在进程级而不是服务实例上。
/// - **24 小时冷却**：尝试时间写在 Program state 封面缓存目录的 `.renew` 侧车
///   （按 bookKey 摘要命名），跨启动仍然生效；失败也算一次尝试。清除封面缓存
///   会一并清掉它，用户主动清缓存后允许重新尝试。
///
/// 先占住本次启动名额、再读持久冷却、最后**在发请求前**写尝试时间：即使请求
/// 途中进程退出或网络失败，冷却也已落盘，不会在下一轮重复打同一个源。
class MangaShelfCoverRenewalThrottle {
  MangaShelfCoverRenewalThrottle._();

  /// 同一本书两次自动续签尝试之间的最小间隔。
  static const Duration cooldown = Duration(hours: 24);

  static final Set<String> _attemptedThisLaunch = <String>{};

  /// 是否允许为 [bookKey] 发起一次自动续签；允许时立即登记这次尝试。
  ///
  /// 返回 false = 本次启动已试过，或距上次尝试不足 [cooldown]。不抛异常：
  /// 节流存储不可用按「允许一次、但本次启动不再重试」处理的风险更低——宁可
  /// 多试一次也不让封面永远无法自愈；[debugReset] 供测试隔离进程级状态。
  static Future<bool> tryAcquire({
    required MangaShelfCoverCache cache,
    required String bookKey,
    DateTime? now,
  }) async {
    // 先同步占位：并发的重复失败回调不得发出第二个续签请求。
    if (!_attemptedThisLaunch.add(bookKey)) return false;
    final DateTime attemptedAt = now ?? DateTime.now();
    try {
      final DateTime? last = await cache.lastRenewalAttempt(bookKey);
      if (last != null &&
          attemptedAt.difference(last) < cooldown &&
          !attemptedAt.isBefore(last)) {
        return false;
      }
      await cache.markRenewalAttempt(bookKey, attemptedAt);
    } on Object {
      // 冷却存储不可用：按「没有冷却记录」处理，本次启动仍只尝试这一次。
    }
    return true;
  }

  /// 测试缝：避免进程内其它用例的续签尝试影响断言。
  @visibleForTesting
  static void debugReset() => _attemptedThisLaunch.clear();
}
