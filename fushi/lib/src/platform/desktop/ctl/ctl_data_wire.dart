/// data 域控制通道的纯函数部分：把 app 里的模型转成应答 JSON、解析 CLI 传来的
/// 参数。不碰 [AppModel]、不做 IO，便于单测（路由本体见 `ctl_data_routes.dart`）。
///
/// 这里的每个 `*ToWire` 都是**白名单**式的：只挑出明确可以出现在终端里的字段。
/// 令牌、密码、证书私钥、OAuth refresh token 一律不在白名单里——新增字段时也要
/// 按这个口径挑，别图省事整个对象 `toJson()` 出去。
library;

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart'
    show FushiClientUrl, MediaSourceRow, VideoDownloadJobLifecycle;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';



import 'package:fushi_engine/sync/interconnect_host_addresses.dart'
    show InterconnectHostAddress;
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:path/path.dart' as p;



import 'package:fushi/src/sync/backup_service.dart';

import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show interconnectPeerRepresentatives;
import 'package:fushi/src/sync/sync_activity.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show SyncAssetChannelScope, SyncChannel, syncAssetChannelScopeOf;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show BackupImportMode, BackupImportPreset, backupImportSelectableCategories;

/// 错误信息里可能夹带的凭据（媒体服务器 URL 上的 `api_key` / `X-Plex-Token`、
/// `Authorization` 头回显等）统一抹掉后才回给终端。
final RegExp _secretQueryPattern = RegExp(
  r'((?:api_key|apikey|access_token|token|x-plex-token|x-emby-token|password|passwd|secret)=)[^&\s"]+',
  caseSensitive: false,
);
final RegExp _bearerPattern = RegExp(
  r'((?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]+',
  caseSensitive: false,
);

String redactCtlSecrets(String message) => message
    .replaceAllMapped(_secretQueryPattern, (Match m) => '${m.group(1)}***')
    .replaceAllMapped(_bearerPattern, (Match m) => '${m.group(1)}***');

// ── 备份 ─────────────────────────────────────────────────────────────

/// `--category` 名单 → 分类集合。空名单返回 null（交给调用方用默认集）；认不出的
/// 名字抛 400，并把合法取值列出来。
Set<BackupCategory>? parseBackupCategories(List<String> names) {
  if (names.isEmpty) return null;
  final Set<BackupCategory> out = <BackupCategory>{};
  for (final String raw in names) {
    for (final String name in raw.split(',')) {
      final String trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      final BackupCategory? category = BackupCategory.values
          .where((BackupCategory c) => c.name == trimmed)
          .firstOrNull;
      if (category == null) {
        throw CtlFailure.badRequest(
          '未知的备份分类：$trimmed（可选：'
          '${BackupCategory.values.map((BackupCategory c) => c.name).join(', ')}）',
        );
      }
      out.add(category);
    }
  }
  return out.isEmpty ? null : out;
}

/// 备份输出路径：给的是已存在的目录就在里面用默认文件名，否则当文件路径用。
/// 只接受绝对路径（CLI 侧已经按 shell 的工作目录转好了）。
String resolveBackupOutputPath(
  String output, {
  required bool isDirectory,
  required String defaultFilename,
}) {
  if (!p.isAbsolute(output)) {
    throw CtlFailure.badRequest('输出路径必须是绝对路径：$output');
  }
  return isDirectory ? p.join(output, defaultFilename) : output;
}

Map<String, Object?> backupMetaToWire(BackupMeta meta) => <String, Object?>{
  'appVersion': meta.appVersion,
  'schemaVersion': meta.schemaVersion,
  'createdAt': meta.createdAt.millisecondsSinceEpoch,
  'bookCount': meta.bookCount,
  'statsCount': meta.statsCount,
  if (meta.videoBookCount != null) 'videoCount': meta.videoBookCount,
  if (meta.audiobookCount != null) 'audiobookCount': meta.audiobookCount,
  if (meta.gameCount != null) 'gameCount': meta.gameCount,
  'excludedCategories': meta.excludedCategories.toList()..sort(),
};

/// `backup restore` 的预设：[mode] 为 null（CLI 没给 --merge / --replace）→ 返回
/// null，走 app 确认框；给了模式就组预设，分类只认该模式下确认框里**可勾选**的
/// 那些（其余分类恒恢复，指定它们没有意义，直接 400 说清楚）。
BackupImportPreset? parseBackupImportPreset({
  required String? mode,
  required List<String> categories,
  required bool importSettings,
}) {
  if (mode == null) {
    if (categories.isNotEmpty || importSettings) {
      throw const CtlFailure.badRequest(
        '--category / --import-settings 要和 --merge 或 --replace 一起用',
      );
    }
    return null;
  }
  final BackupImportMode importMode = switch (mode) {
    'merge' => BackupImportMode.merge,
    'replace' || 'overwrite' => BackupImportMode.overwrite,
    _ => throw CtlFailure.badRequest('未知的恢复模式：$mode（只认 merge / replace）'),
  };
  if (importSettings && importMode != BackupImportMode.overwrite) {
    throw const CtlFailure.badRequest(
      '--import-settings 只用于 --replace（合并恒保留本机设置）',
    );
  }
  final Set<BackupCategory>? selected = parseBackupCategories(categories);
  if (selected != null) {
    final Set<BackupCategory> selectable = backupImportSelectableCategories(
      importMode,
    );
    final List<BackupCategory> fixed = <BackupCategory>[
      for (final BackupCategory c in selected)
        if (!selectable.contains(c)) c,
    ];
    if (fixed.isNotEmpty) {
      throw CtlFailure.badRequest(
        '这些分类恢复时恒包含、不能挑选：'
        '${fixed.map((BackupCategory c) => c.name).join(', ')}（可挑选：'
        '${selectable.map((BackupCategory c) => c.name).join(', ')}）',
      );
    }
  }
  return BackupImportPreset(
    mode: importMode,
    categories: selected,
    importSettings: importSettings,
  );
}

Map<String, Object?> backupSummaryToWire(BackupContentSummary summary) =>
    <String, Object?>{
      for (final MapEntry<BackupCategory, int> e in summary.counts.entries)
        e.key.name: e.value,
    };

// ── 云同步 ───────────────────────────────────────────────────────────

/// 一种同步后端在本机的状态（**只有**是否配置 / 是否选中，不含任何凭据）。
Map<String, Object?> syncBackendToWire({
  required SyncBackendType type,
  required bool selected,
  required bool configured,
}) => <String, Object?>{
  'id': type.name,
  'selected': selected,
  'configured': configured,
};

/// 一条已启用的同步通道：通道名（`sync run <通道>` 认的就是它）+ 它解析自哪个后端。
Map<String, Object?> syncChannelToWire(SyncChannel channel) =>
    <String, Object?>{
      'id': syncAssetChannelScopeOf(channel).name,
      'backend': channel.type.name,
    };

/// `sync run [<通道>...]` 的通道名 → 过滤集合。空名单 = null（全部已启用通道）；
/// 认不出的名字 400，并列出合法取值。
Set<SyncAssetChannelScope>? parseSyncChannelScopes(List<String> names) {
  final Set<SyncAssetChannelScope> out = <SyncAssetChannelScope>{};
  for (final String raw in names) {
    for (final String name in raw.split(',')) {
      final String trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      final SyncAssetChannelScope? scope = SyncAssetChannelScope.values
          .where((SyncAssetChannelScope s) => s.name == trimmed)
          .firstOrNull;
      if (scope == null) {
        throw CtlFailure.badRequest(
          '未知的同步通道：$trimmed（可选：'
          '${SyncAssetChannelScope.values.map((SyncAssetChannelScope s) => s.name).join(', ')}）',
        );
      }
      out.add(scope);
    }
  }
  return out.isEmpty ? null : out;
}

Map<String, Object?>? syncOutcomeToWire(SyncRunOutcome? outcome) =>
    outcome == null
    ? null
    : <String, Object?>{
        'kind': outcome.kind.name,
        'reason': outcome.reason.name,
        'channelsRun': outcome.channelsRun,
        'finishedAt': outcome.finishedAt,
      };

// ── 互联 ─────────────────────────────────────────────────────────────

/// 本机作为 client 记住的一条 host 地址。`token` 只报「有没有」，绝不回值。
Map<String, Object?> peerHostUrlToWire(FushiClientUrl url) => <String, Object?>{
  'url': url.url,
  'enabled': url.enabled,
  if (url.deviceName != null) 'deviceName': url.deviceName,
  if (url.hostId != null) 'hostId': url.hostId,
  if (url.addressKind != null) 'addressKind': url.addressKind,
  'learned': url.learned,
  'paired': url.token?.isNotEmpty ?? false,
  'pinned': url.fingerprintSha256?.isNotEmpty ?? false,
};

// ── 下载 ─────────────────────────────────────────────────────────────

/// `dl add` 的目标分型。
enum CtlDownloadTargetKind { magnet, torrentFile, url }

CtlDownloadTargetKind classifyDownloadTarget(String target) {
  final String lower = target.trim().toLowerCase();
  if (lower.startsWith('magnet:?')) return CtlDownloadTargetKind.magnet;
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return CtlDownloadTargetKind.url;
  }
  if (lower.endsWith('.torrent')) return CtlDownloadTargetKind.torrentFile;
  throw const CtlFailure.badRequest('只认磁力链接（magnet:?…）或 .torrent 文件');
}

/// 直链任务在控制通道上的 id 前缀：视频下载任务的 id 是持久化字符串，直链队列的
/// 任务 id 是进程内自增整数，加前缀避免两边撞号。
const String kCtlDirectDownloadIdPrefix = 'direct:';

/// `direct:<n>` → n；不是直链任务 id 返回 null。
int? parseDirectDownloadTaskId(String id) =>
    id.startsWith(kCtlDirectDownloadIdPrefix)
    ? int.tryParse(id.substring(kCtlDirectDownloadIdPrefix.length))
    : null;

/// `dl add <url> --kind` 的直链内容类型（决定下完后自动入哪个库）。
DiscoveryMediaKind parseDirectDownloadKind(String? kind) {
  for (final DiscoveryMediaKind k in DiscoveryMediaKind.values) {
    if (k.name == kind) return k;
  }
  throw CtlFailure.badRequest(
    'http 直链要用 --kind 指定内容类型（'
    '${DiscoveryMediaKind.values.map((DiscoveryMediaKind k) => k.name).join(' / ')}），'
    '下完按它自动入库',
  );
}

/// 直链队列里的一个任务。地址不出（签名 URL 常带令牌），只报主机名；错误信息先抹凭据。
Map<String, Object?> directDownloadTaskToWire(DiscoveryDownloadTask task) {
  final DiscoveryPayload? payload = task.item.payload;
  final String? host = payload is DiscoveryHttpPayload
      ? Uri.tryParse(payload.url)?.host
      : null;
  final int? total = task.totalBytes;
  return <String, Object?>{
    'jobId': '$kCtlDirectDownloadIdPrefix${task.taskId}',
    'title': task.item.title,
    'kind': task.item.kind.name,
    'source': task.item.sourceId,
    if (host != null && host.isNotEmpty) 'host': host,
    'lifecycle': task.status.name,
    'stage': 'direct',
    'receivedBytes': task.receivedBytes,
    if (total != null) 'totalBytes': total,
    if (total != null && total > 0)
      'stageProgress': (task.receivedBytes / total).clamp(0.0, 1.0),
    'createdAt': task.createdAt,
    if (task.error != null) 'lastError': redactCtlSecrets(task.error!),
    if (task.filePath != null) 'filePath': task.filePath,
    if (task.importOutcome?.summary != null)
      'imported': task.importOutcome!.summary,
  };
}

/// 磁链任务的标题：显式给的优先，否则取磁链里的 `dn`（显示名）。都没有返回 null。
String? magnetTaskTitle(String magnet, String? explicitTitle) {
  final String? given = explicitTitle?.trim();
  if (given != null && given.isNotEmpty) return given;
  final Uri? uri = Uri.tryParse(magnet.trim());
  final String? dn = uri?.queryParameters['dn']?.trim();
  return (dn == null || dn.isEmpty) ? null : dn;
}

// ── 互联（第二轮）───────────────────────────────────────────────────

/// `peer forget <hostId|url|设备名>` → 要删的那一行 URL 与它的 hostId（有 hostId 时
/// 整台 host 的地址一起删，见 [withoutInterconnectHost]）。按 hostId 认优先：同一台
/// host 的地址会随它换 IP 被自动增删，URL 不是稳定身份。
({String url, String? hostId}) resolveForgetHost(
  List<FushiClientUrl> urls,
  String selector,
) {
  for (final FushiClientUrl u in urls) {
    if (u.hostId != null && u.hostId == selector) {
      return (url: u.url, hostId: u.hostId);
    }
  }
  for (final FushiClientUrl u in urls) {
    if (u.url == selector) return (url: u.url, hostId: u.hostId);
  }
  final List<FushiClientUrl> byName = <FushiClientUrl>[
    for (final FushiClientUrl u in interconnectPeerRepresentatives(urls))
      if (u.deviceName == selector) u,
  ];
  if (byName.length > 1) {
    throw CtlFailure.conflict('有多台 host 叫「$selector」，请改用 hostId（peer ls 查看）');
  }
  if (byName.isEmpty) {
    throw CtlFailure.notFound('没有这台 host：$selector（peer ls 查看）');
  }
  return (url: byName.single.url, hostId: byName.single.hostId);
}

/// 配对链接里的一条地址（公开值：二维码里本来就有）。
Map<String, Object?> pairLinkAddressToWire(InterconnectHostAddress address) =>
    <String, Object?>{'url': address.url, 'kind': address.kind.name};
