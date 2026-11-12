import 'dart:convert';

import 'package:my_comic/src/utils/misc/platform_updater.dart';

/// 更新检查的发布源仓库标识。
///
/// 缓存条目随结果一起记录它来自哪个更新源；读取时按当前源校验。旧版上游
/// `Myyuluo/my-comic` 的缓存没有这个字段（或值不同），一律视为无缓存——否则
/// my-comic 1.0.0 会在联网检查前就显示上游 3.x「有新版本」。
const String kUpdateCheckSourceRepository = 'Myyuluo/my-comic';

/// TODO-1024 / BUG-479：app 自更新「检查更新」的**结果缓存**。
///
/// 根因：旧 `UpdateChecker._check` 每次都冷查 GitHub（新建 `HttpClient`、对直连 + 镜像
/// 竞速），**没有任何检查结果缓存**——既无上次检查时间戳、也无缓存的最新 tag，故耗时
/// 完全取决于当次直连 GitHub 的 DNS/TLS/限流状态，网络没变也「时快时慢」。
///
/// 修复对齐 Hoshi-Reader-Android「缓存优先 + 后台静默刷新」：检查时**先读缓存乐观决定/
/// 显示**（不等网络，恒快），网络刷新在后台跑完再写回缓存、必要时弹窗。
///
/// 本类是承载缓存的**纯数据结构** + 纯 `encode`/`decode`，落在 Drift `preferences` 表的
/// 单个 key（[updateCheckCachePrefKey]）下，不动 schema。所有 IO/网络由调用方注入，本文件
/// 零副作用、可纯单测。
class UpdateCheckCacheEntry {
  const UpdateCheckCacheEntry({
    required this.lastCheckEpochMs,
    required this.latestTag,
    required this.htmlUrl,
    required this.channel,
    this.repository = kUpdateCheckSourceRepository,
  });

  /// 上次成功完成网络检查的时刻（毫秒 epoch，UTC）。
  final int lastCheckEpochMs;

  /// 上次检查拿到的最新 release tag（如 `v1.2.3` / `1.2.3-beta.4`）。
  final String latestTag;

  /// 该 release 的发布页 URL（fallback「打开发布页」用；可空）。
  final String htmlUrl;

  /// 该缓存条目所属的更新通道（stable/beta/debug）——通道不同结果不同，必须分流。
  final UpdateChannel channel;

  /// 产生该结果的更新源仓库（如 `Myyuluo/my-comic`）。
  ///
  /// 旧版缓存缺这个字段；[decode] 直接按无缓存处理，避免上游发布线串入 fork。
  final String repository;

  /// 上次检查时刻（本地时区 [DateTime]）。
  DateTime get lastCheckTime =>
      DateTime.fromMillisecondsSinceEpoch(lastCheckEpochMs, isUtc: true)
          .toLocal();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lastCheckEpochMs': lastCheckEpochMs,
        'latestTag': latestTag,
        'htmlUrl': htmlUrl,
        'channel': channel.name,
        'repository': repository,
      };

  /// 编码成可落 `preferences` 表的 JSON 字符串。
  String encode() => jsonEncode(toJson());

  /// **纯函数**：从 `preferences` 读出的原始字符串解码成强类型条目。
  ///
  /// 任意畸形（空串 / 非 JSON / 非对象 / 缺 `latestTag` / 通道不识别）→ 返 `null`，
  /// 调用方据此当作「无缓存」安全回退到网络检查，绝不抛错。
  static UpdateCheckCacheEntry? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;

    final Object? tagRaw = decoded['latestTag'];
    if (tagRaw is! String || tagRaw.isEmpty) return null;

    final Object? channelRaw = decoded['channel'];
    final UpdateChannel? channel = _channelFromName(channelRaw);
    if (channel == null) return null;

    // 旧版 / 上游缓存没有 repository（或值为空）：按无缓存处理，绝不把上游
    // 3.x 的检查结果当成 fork 的当前版本。
    final Object? repoRaw = decoded['repository'];
    if (repoRaw is! String || repoRaw.isEmpty) return null;

    final Object? epochRaw = decoded['lastCheckEpochMs'];
    final int epoch = epochRaw is int
        ? epochRaw
        : epochRaw is num
            ? epochRaw.toInt()
            : 0;

    final Object? htmlRaw = decoded['htmlUrl'];
    final String html = htmlRaw is String ? htmlRaw : '';

    return UpdateCheckCacheEntry(
      lastCheckEpochMs: epoch,
      latestTag: tagRaw,
      htmlUrl: html,
      channel: channel,
      repository: repoRaw,
    );
  }

  static UpdateChannel? _channelFromName(Object? name) {
    if (name is! String) return null;
    for (final UpdateChannel c in UpdateChannel.values) {
      if (c.name == name) return c;
    }
    return null;
  }
}

/// `preferences` 表里承载更新检查缓存的 key（通道全部落同一 key，条目自带 `channel`
/// 字段——读时按当前通道比对，通道不匹配等价「无缓存」，绝不跨通道误用）。
const String updateCheckCachePrefKey = 'update_check_cache';

/// **纯函数**：读出的缓存条目是否可用于「当前通道 + 当前更新源」的乐观决定/显示。
///
/// 条目通道 ≠ 当前查询通道、或产生条目的仓库 ≠ 当前更新源时返回 `null`（视作
/// 无缓存），避免把 stable 的缓存误当 beta 用，也避免旧上游发布线串入 fork。
UpdateCheckCacheEntry? cachedEntryForChannel(
  UpdateCheckCacheEntry? entry,
  UpdateChannel channel, {
  String repository = kUpdateCheckSourceRepository,
}) {
  if (entry == null) return null;
  if (entry.channel != channel) return null;
  if (entry.repository != repository) return null;
  return entry;
}

/// 把一次成功网络检查的结果写回缓存。由调用方（持有 `preferences` 的 [AppModel]）注入，
/// [UpdateChecker] 不直接持有 DB。乐观「读缓存」由调用方直接读 `appModel.updateCheckCache`。
typedef UpdateCheckCacheWriter = Future<void> Function(
    UpdateCheckCacheEntry entry);
