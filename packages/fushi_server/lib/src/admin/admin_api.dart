/// `/api/admin/*`：WebUI 的 JSON 面。鉴权在 [AdminServer] 的 middleware。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/anki_sync/anki_box_landing.dart';
import 'package:fushi_engine/anki_sync/anki_sync_session.dart';








import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/host_jobs/host_job.dart';


import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/anki_landing.dart';
import 'package:fushi_server/src/admin/upload_store.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/library_scanner.dart';
import 'package:fushi_server/src/profile_hub.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;

shelf.Response _json(Object body, {int status = 200}) => shelf.Response(
      status,
      body: jsonEncode(body),
      headers: const <String, String>{'Content-Type': 'application/json; charset=utf-8'},
    );

shelf.Response _err(int status, String message) =>
    _json(<String, Object?>{'error': message}, status: status);

Future<Map<String, dynamic>> _body(shelf.Request request) async {
  final String text = await request.readAsString();
  if (text.isEmpty) return <String, dynamic>{};
  final Object? decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('JSON object body required');
  return Map<String, dynamic>.from(decoded);
}

class AdminApi {
  AdminApi(this.ctx)
      : uploads = UploadStore(
          ledgerFile: File(p.join(ctx.paths.support.path, 'upload_ledger.json')),
          quotaBytes: ctx.config.uploadQuotaBytes,
        );

  final AdminContext ctx;
  final UploadStore uploads;

  Future<shelf.Response> handle(shelf.Request request) async {
    final String method = request.method.toUpperCase();
    final String path = '/${request.url.path}';
    try {
      // `return await`：async 函数里 `return future` 的错误不归外层 try 管。
      return await _route(method, path, request);
    } on FormatException catch (e) {
      return _err(400, e.message);
    } on ArgumentError catch (e) {
      return _err(400, '${e.message}');
    } on UploadRejected catch (e) {
      return _err(e.status, e.message);
    } catch (e, stack) {
      ctx.log.log('AdminApi $method $path', e, stack);
      return _err(500, '$e');
    }
  }

  Future<shelf.Response> _route(String method, String path, shelf.Request request) async {
    switch ((method, path)) {
      case ('GET', '/api/admin/status'):
        return _status();
      case ('GET', '/api/admin/logs'):
        return _json(<String, Object?>{'lines': ctx.log.recent});
      case ('GET', '/api/admin/pairing'):
        return _pairing();
      case ('DELETE', _) when path.startsWith('/api/admin/pairing/peers/'):
        return _revokePeer(Uri.decodeComponent(path.substring('/api/admin/pairing/peers/'.length)));
      case ('GET', '/api/admin/libraries'):
        return _libraries();
      case ('POST', '/api/admin/libraries'):
        return _addLibrary(await _body(request));
      case ('DELETE', _) when path.startsWith('/api/admin/libraries/'):
        return _removeLibrary(
          Uri.decodeComponent(path.substring('/api/admin/libraries/'.length)),
        );
      case ('POST', '/api/admin/scan'):
        return _scan(await _body(request));
      case ('GET', '/api/admin/jobs'):
        return _jobs();
      case ('DELETE', _) when path.startsWith('/api/admin/jobs/'):
        await ctx.host.jobs?.delete(path.substring('/api/admin/jobs/'.length));
        return _json(const <String, Object?>{'ok': true});
      case ('GET', '/api/admin/models'):
        return _models();
      case ('POST', '/api/admin/models/pull'):
        return _pullModel(await _body(request));
      case ('GET', '/api/admin/settings'):
        return _settings();
      case ('PUT', '/api/admin/settings'):
        return _putSettings(await _body(request));
      case ('GET', '/api/admin/anki'):
        return _anki();
      case ('POST', '/api/admin/anki/login'):
        return _ankiLogin(await _body(request));
      case ('POST', '/api/admin/anki/logout'):
        final Map<String, dynamic> body = await _body(request);
        try {
          await _ankiSession().signOut(discardUnsynced: body['discardUnsynced'] == true);
        } on AnkiSyncHasUnsyncedNotes catch (e) {
          return _err(409, 'unsynced:${e.count}');
        }
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/sync'):
        final AnkiSyncState synced = await _ankiSession().syncNow();
        return _json(<String, Object?>{'phase': synced.phase.name});
      case ('POST', '/api/admin/anki/refresh'):
        return _json(<String, Object?>{'ok': await _ankiLanding().refreshMeta()});
      case ('PUT', '/api/admin/anki/settings'):
        return _putAnkiSettings(await _body(request));
      case ('POST', '/api/admin/anki/landing'):
        final Map<String, dynamic> body = await _body(request);
        await _ankiLanding().setLandingEnabled(body['enabled'] == true);
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/run'):
        await _ankiLanding().runNow();
        return _json(const <String, Object?>{'ok': true});
      case ('POST', '/api/admin/anki/retry'):
        return _json(<String, Object?>{'retried': await _ankiLanding().retryFailed()});
      case ('GET', '/api/admin/profiles'):
        return _profiles();
      case ('POST', _) when path.startsWith('/api/admin/profiles/') && path.endsWith('/share'):
        return _profileAction(_segment(path, '/api/admin/profiles/', '/share'), ctx.host.profiles.pin);
      case ('DELETE', _) when path.startsWith('/api/admin/profiles/'):
        return _profileAction(Uri.decodeComponent(path.substring('/api/admin/profiles/'.length)), ctx.host.profiles.delete);
      case ('GET', '/api/admin/p2p'):
        return _json(ctx.host.p2pStatus());
      case ('GET', '/api/admin/upload'):
        return _uploadStatus(request);
      case ('PUT', '/api/admin/upload'):
        return _upload(request);
      case (_, _) when path.startsWith(_hostProxyPrefix):
        return _hostProxy(request, path.substring(_hostProxyPrefix.length));
    }
    return _err(404, 'unknown admin route $method $path');
  }

  static const String _hostProxyPrefix = '/api/admin/host/';

  /// `/api/admin/host/<rest>` → 互联的 `/api/<rest>`，以 host 身份进程内调用。
  ///
  /// 互联的库 / 刮削 / 进度 / 任务等接口只对已配对 peer 开放，管理员自己反而没有
  /// 入口；这里让 `fushi_server ctl` 与 WebUI 直接复用那一套，而不是在 admin 面
  /// 另写同功能路由（两份实现必然漂移）。管理员凭据已由 [AdminServer] 验过。
  ///
  /// 配对路由依赖对端地址与人工确认，代调没有意义也不安全，一律拒绝。
  Future<shelf.Response> _hostProxy(shelf.Request request, String rest) async {
    if (rest == 'pair' || rest.startsWith('pair/')) {
      return _err(403, 'pairing routes are not available through the admin proxy');
    }
    final FushiSyncServer? server = ctx.host.syncServer;
    if (server == null) return _err(503, 'the interconnect host is not running');
    final Uri target = Uri(
      scheme: 'http',
      host: 'localhost',
      path: '/api/$rest',
      query: request.requestedUri.hasQuery ? request.requestedUri.query : null,
    );
    final Map<String, String> headers = <String, String>{
      for (final MapEntry<String, String> e in request.headers.entries)
        if (e.key.toLowerCase() != 'authorization' && e.key.toLowerCase() != 'cookie') e.key: e.value,
    };
    return server.handleInProcess(shelf.Request(request.method, target, headers: headers, body: request.read()));
  }

  String _segment(String path, String prefix, String suffix) =>
      Uri.decodeComponent(path.substring(prefix.length, path.length - suffix.length));

  // ── 状态 ─────────────────────────────────────────────────────────────

  Future<shelf.Response> _status() async {
    final List<FushiPairedPeerRow> peers = await ctx.db.getPairedPeers();
    final int books = (await ctx.db.getAllEpubBooks()).length;
    return _json(<String, Object?>{
      'deviceName': ctx.config.deviceName,
      'deviceId': ctx.identity.deviceId,
      'listen': '${ctx.config.bind}:${ctx.host.port}',
      'tls': ctx.config.tls,
      'fingerprint': ctx.host.hostFingerprint,
      'startedAt': ctx.startedAt.toIso8601String(),
      'uptimeSeconds': DateTime.now().difference(ctx.startedAt).inSeconds,
      'dataDir': ctx.config.dataDir,
      'books': books,
      'peers': peers.length,
      'libraries': ctx.config.libraries.length,
      'scanning': ctx.scanning,
      'lastScan': ctx.lastScan?.toString(),
      'lastScanNotes': ctx.lastScan?.pruneNotes ?? const <String>[],
      'lastScanAt': ctx.lastScanAt?.toIso8601String(),
      'uploadUsedBytes': await uploads.used(),
      'uploadQuotaBytes': ctx.config.uploadQuotaBytes,
      'p2p': ctx.host.p2pStatus(),
    });
  }

  // ── 配对 ─────────────────────────────────────────────────────────────

  Future<shelf.Response> _pairing() async {
    final PendingPairing? pending = ctx.host.pendingPairing;
    final List<FushiPairedPeerRow> peers = await ctx.db.getPairedPeers();
    return _json(<String, Object?>{
      'pending': pending == null
          ? null
          : <String, Object?>{
              'pin': pending.pin,
              'deviceName': pending.deviceName,
              'remoteAddress': pending.remoteAddress,
              'createdAt': pending.createdAt.toIso8601String(),
            },
      'peers': <Object?>[
        for (final FushiPairedPeerRow peer in peers)
          <String, Object?>{
            'peerId': peer.peerId,
            'deviceName': peer.deviceName,
            'lastSeenIp': peer.lastSeenIp,
            'pairedAtMs': peer.pairedAtMs,
          },
      ],
    });
  }

  Future<shelf.Response> _revokePeer(String peerId) async {
    final int n = await ctx.db.revokePairedPeer(peerId);
    ctx.host.invalidatePeerTokens();
    return _json(<String, Object?>{'ok': n > 0});
  }

  // ── 库 ─────────────────────────────────────────────────────────────

  shelf.Response _libraries() => _json(_librariesJson());

  Map<String, Object?> _librariesJson() => <String, Object?>{
        'libraries': <Object?>[
          for (final LibraryRootConfig lib in ctx.config.libraries)
            <String, Object?>{
              ...lib.toYamlMap(),
              'exists': Directory(lib.path).existsSync(),
            },
        ],
      };

  Future<shelf.Response> _addLibrary(Map<String, dynamic> body) async {
    final String path = (body['path'] ?? '').toString().trim();
    if (path.isEmpty) throw const FormatException('path required');
    final String kind = (body['kind'] ?? 'book').toString();
    if (kind != 'book' && kind != 'manga') {
      throw const FormatException('kind must be book or manga');
    }
    final String id = (body['id'] ?? '').toString().trim().isEmpty
        ? 'lib${DateTime.now().millisecondsSinceEpoch}'
        : body['id'].toString().trim();
    if (ctx.config.libraries.any((LibraryRootConfig l) => l.id == id)) {
      throw FormatException('library id "$id" already exists');
    }
    await Directory(path).create(recursive: true);
    await ctx.updateConfig(ctx.config.copyWith(libraries: <LibraryRootConfig>[
      ...ctx.config.libraries,
      LibraryRootConfig(id: id, path: p.normalize(p.absolute(path)), kind: kind),
    ]));
    return _libraries();
  }

  /// 移除一个库根（只改配置，不删用户文件）。
  Future<shelf.Response> _removeLibrary(String id) async {
    final LibraryRootConfig? library = ctx.config.libraries
        .cast<LibraryRootConfig?>()
        .firstWhere((LibraryRootConfig? l) => l!.id == id, orElse: () => null);
    if (library == null) return _err(404, 'unknown library $id');
    await ctx.updateConfig(ctx.config.copyWith(
      libraries: ctx.config.libraries.where((LibraryRootConfig l) => l.id != id).toList(),
    ));
    return _json(_librariesJson());
  }

  shelf.Response _scan(Map<String, dynamic> body) {
    final Object? raw = body['prune'];
    if (raw != null && raw is! bool) {
      throw const FormatException('prune must be a boolean');
    }
    if (ctx.scanning) return _json(const <String, Object?>{'started': false, 'scanning': true});
    // 不 await：扫描可能很久，WebUI 轮询 status 看结果。
    ctx.scanLibraries(prune: raw as bool?).catchError((Object e, StackTrace st) {
      ctx.log.log('AdminApi.scan', e, st);
      return ScanSummary();
    });
    return _json(const <String, Object?>{'started': true, 'scanning': true});
  }

  // ── 任务 / 下载 ─────────────────────────────────────────────────────

  shelf.Response _jobs() => _json(<String, Object?>{
        'jobs': ctx.host.jobs?.list().map((HostJobRecord r) => r.toWireJson()).toList() ?? const <Object?>[],
      });


  Map<String, Object?>? _modelsCache;
  DateTime _modelsCacheAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<shelf.Response> _models() async {
    // plan() 每种语言都要探一次 ORT provider；WebUI 2.5s 轮询下别每次都探。
    final bool fresh = DateTime.now().difference(_modelsCacheAt) < const Duration(seconds: 5);
    if (_modelsCache != null && fresh && _pulling.isEmpty) return _json(_modelsCache!);
    final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
    final List<Object?> asrModels = <Object?>[];
    for (final asr.AsrLanguage language in asr.AsrLanguage.registered) {
      try {
        final asr.AsrTranscribePlan plan =
            await service.plan(language: language, preference: asr.AsrAccelerationPreference.auto);
        asrModels.add(<String, Object?>{
          'tag': language.tag,
          'name': language.nativeName,
          'ready': plan.modelReady,
          'variant': plan.variant.name,
          'provider': plan.expectedProvider.name,
          'obtainedBytes': plan.modelStatus.obtainedBytes,
          'totalBytes': plan.modelStatus.totalBytes,
          'pulling': _pulling.contains(language.tag),
        });
      } catch (e) {
        asrModels.add(<String, Object?>{'tag': language.tag, 'name': language.nativeName, 'error': '$e'});
      }
    }
    _modelsCacheAt = DateTime.now();
    return _json(_modelsCache = <String, Object?>{'asr': asrModels});
  }

  final Set<String> _pulling = <String>{};

  Future<shelf.Response> _pullModel(Map<String, dynamic> body) async {
    final String which = (body['model'] ?? '').toString();
    if (which.isEmpty) throw const FormatException('model required (asr language tag)');
    if (_pulling.contains(which)) return _json(const <String, Object?>{'started': false, 'pulling': true});
    _pulling.add(which);
    Future<void> run() async {
      try {
        final asr.AsrLanguage? language = asr.AsrLanguage.fromTag(which);
        if (language == null) throw FormatException('unknown language $which');
        final asr.AsrTranscriptionService service = createServerAsrTranscriptionService();
        final asr.AsrTranscribePlan plan =
            await service.plan(language: language, preference: asr.AsrAccelerationPreference.auto);
        await for (final asr.ModelDownloadEvent _
            in service.downloadModel(language: language, variant: plan.variant)) {}
        ctx.log.info('model pull done: $which');
      } catch (e, st) {
        ctx.log.log('AdminApi.pullModel($which)', e, st);
      } finally {
        _pulling.remove(which);
      }
    }

    // 后台跑，WebUI 轮询 /models 看 obtainedBytes。
    run();
    return _json(const <String, Object?>{'started': true, 'pulling': true});
  }

  // ── 互联配置文件寄存 ─────────────────────────────────────────────────

  /// 寄存的配置方案 + 开关状态。`reachable` = 对端此刻能不能用这条端点（开关开着
  /// 且 host 跑在 TLS 上；端点在明文下一律 403）。
  Future<shelf.Response> _profiles() async => _json(<String, Object?>{
        'enabled': ctx.config.profileTransfer,
        'tls': ctx.config.tls,
        'reachable': ctx.config.profileTransfer && ctx.config.tls,
        'profiles': <Map<String, Object?>>[
          for (final ServerProfileSummary s in await ctx.host.profiles.list()) s.toJson(),
        ],
      });

  Future<shelf.Response> _profileAction(String rawId, Future<bool> Function(int id) action) async {
    final int? id = int.tryParse(rawId);
    if (id == null) throw FormatException('invalid profile id "$rawId"');
    if (!await action(id)) return _err(404, 'profile $id not found');
    return _profiles();
  }

  // ── 设置 ─────────────────────────────────────────────────────────────

  shelf.Response _settings() => _json(<String, Object?>{
        'deviceName': ctx.config.deviceName,
        'port': ctx.config.port,
        'bind': ctx.config.bind,
        'tls': ctx.config.tls,
        'lanRequiresPin': ctx.config.lanRequiresPin,
        'subtitleLanguage': ctx.config.subtitleLanguage,
        'metadataLocale': ctx.config.metadataLocale,
        'scanPrune': ctx.config.scanPrune,
        'profileTransfer': ctx.config.profileTransfer,
        'ffmpeg': ctx.config.ffmpegPath,
        'ffprobe': ctx.config.ffprobePath,
        'onnxruntimeLibrary': ctx.config.ortLibraryPath,
        'uploadQuotaBytes': ctx.config.uploadQuotaBytes,
        'adminPort': ctx.config.adminPort,
        // 远程可达三项：保存即生效，不在 restartRequiredKeys 里。
        'publicUrls': ctx.config.publicUrls,
        'p2p': ctx.config.p2p,
        'p2pRelays': ctx.config.p2pRelays,
        'p2pStatus': ctx.host.p2pStatus(),
        'restartRequiredKeys': const <String>['port', 'bind', 'tls', 'adminPort', 'onnxruntimeLibrary', 'ffmpeg', 'ffprobe', 'metadataLocale'],
      });

  Future<shelf.Response> _putSettings(Map<String, dynamic> body) async {
    final List<String>? publicUrls = _remoteUrls(body, 'publicUrls');
    final List<String>? p2pRelays = _remoteUrls(body, 'p2pRelays');
    final Object? p2pRaw = body['p2p'];
    if (p2pRaw != null && p2pRaw is! bool) throw const FormatException('p2p must be a boolean');
    final bool? p2p = p2pRaw as bool?;
    for (final String key in const <String>['scanPrune', 'profileTransfer']) {
      if (body[key] != null && body[key] is! bool) throw FormatException('$key must be a boolean');
    }
    // 只拦「从关到开」：原本就开着（手写 yaml）时照常能保存别的项、也能关掉。
    if (p2p == true && !ctx.config.p2p && !ctx.host.p2pAvailable) {
      return _json(<String, Object?>{
        'error': 'P2P 隧道不可用：没找到 libfushi_p2p（放在 bin/../lib/ 或设 FUSHI_P2P_LIB）',
        'reason': 'p2p_unavailable',
      }, status: 409);
    }
    final ServerConfig next = ctx.config.copyWith(
      deviceName: body['deviceName']?.toString(),
      port: body['port'] is num ? (body['port'] as num).toInt() : null,
      bind: body['bind']?.toString(),
      tls: body['tls'] is bool ? body['tls'] as bool : null,
      lanRequiresPin: body['lanRequiresPin'] is bool ? body['lanRequiresPin'] as bool : null,
      subtitleLanguage: body['subtitleLanguage']?.toString(),
      metadataLocale: body['metadataLocale']?.toString(),
      ffmpegPath: body['ffmpeg']?.toString(),
      ffprobePath: body['ffprobe']?.toString(),
      ortLibraryPath: body['onnxruntimeLibrary']?.toString(),
      uploadQuotaBytes: body['uploadQuotaBytes'] is num ? (body['uploadQuotaBytes'] as num).toInt() : null,
      adminPort: body['adminPort'] is num ? (body['adminPort'] as num).toInt() : null,
      publicUrls: publicUrls,
      p2p: p2p,
      p2pRelays: p2pRelays,
      scanPrune: body['scanPrune'] as bool?,
      profileTransfer: body['profileTransfer'] as bool?,
    );
    await ctx.updateConfig(next);
    return _settings();
  }

  /// `ai`：缺省 = 不改。`preset` 为空 / null = 关掉（删掉 `ai:` 段）；缺 `preset` 键 =
  /// 沿用当前预设。`protocol` / `baseUrl` / `model` 空 = 跟随预设；`apiKey` 空 = 不改
  /// （与 qBittorrent 密码同口径：表单不回显旧值）。配出来不能用（未知预设、地址
  /// 非法、非 HTTPS 又没放行明文…）整个请求 400，不落半截；只缺 key / 模型的「没配全」
  /// 照存（能力位报 no_provider），用户可以分两次填。
  static ({ServerAiConfig? ai, bool clear})? _aiFromBody(Object? raw, ServerAiConfig? current) {
    if (raw == null) return null;
    if (raw is! Map) throw const FormatException('ai must be an object');
    final Map<String, Object?> m = <String, Object?>{for (final MapEntry<Object?, Object?> e in raw.entries) '${e.key}': e.value};
    String? text(String key) {
      final Object? v = m[key];
      if (v != null && v is! String) throw FormatException('ai.$key must be a string');
      final String t = (v as String? ?? '').trim();
      return t.isEmpty ? null : t;
    }

    bool? flag(String key) {
      final Object? v = m[key];
      if (v != null && v is! bool) throw FormatException('ai.$key must be a boolean');
      return v as bool?;
    }

    final String? preset = m.containsKey('preset') ? text('preset') : current?.preset;
    if (preset == null) return (ai: null, clear: true);
    final String? protocolKey = text('protocol');
    AiWireProtocol? protocol;
    if (protocolKey != null) {
      protocol = AiWireProtocol.values.where((AiWireProtocol p) => p.storageKey == protocolKey).firstOrNull;
      if (protocol == null) throw FormatException('ai.protocol "$protocolKey" is not a known protocol');
    }
    final String? effort = text('reasoningEffort');
    if (effort != null && !AiReasoningEffort.values.any((AiReasoningEffort e) => e.storageKey == effort)) {
      throw FormatException('ai.reasoningEffort "$effort" is not one of none / low / medium / high');
    }
    final ServerAiConfig base = current ?? ServerAiConfig(preset: preset);
    final ServerAiConfig next = base.copyWith(
      preset: preset,
      protocol: protocol,
      clearProtocol: protocol == null && m.containsKey('protocol'),
      baseUrl: text('baseUrl'),
      clearBaseUrl: text('baseUrl') == null && m.containsKey('baseUrl'),
      model: text('model'),
      clearModel: text('model') == null && m.containsKey('model'),
      apiKey: text('apiKey'),
      reasoningEffort: effort == null ? null : AiReasoningEffort.fromStorageKey(effort),
      allowInsecureHttp: flag('allowInsecureHttp'),
      webKnowledge: flag('webKnowledge'),
    );
    // 只缺 key / 模型算「没配全」，照存；地址 / 预设层面的错误直接拒。
    final String? invalid = next.invalidReason();
    if (invalid != null) throw FormatException('ai: $invalid');
    return (ai: next, clear: false);
  }

  /// `publicUrls` / `p2pRelays`：缺省 = 不改；否则必须是字符串数组，逐条去空白、
  /// 去空行、去重，任一条不合法整个请求 400（不落半截）。
  static List<String>? _remoteUrls(Map<String, dynamic> body, String key) {
    final Object? raw = body[key];
    if (raw == null) return null;
    if (raw is! List) throw FormatException('$key must be an array of URLs');
    final List<String> urls = <String>[];
    for (final Object? item in raw) {
      if (item is! String) throw FormatException('$key must be an array of URLs');
      final String url = item.trim();
      if (url.isEmpty || urls.contains(url)) continue;
      final String? problem = ServerConfig.remoteUrlProblem(url);
      if (problem != null) throw FormatException('$key: "$url" $problem');
      urls.add(url);
    }
    return urls;
  }

  // ── 上传 ─────────────────────────────────────────────────────────────

  LibraryRootConfig _libraryFor(shelf.Request request) {
    final String? id = request.url.queryParameters['library'];
    final LibraryRootConfig? lib = ctx.config.libraries
        .cast<LibraryRootConfig?>()
        .firstWhere((LibraryRootConfig? l) => l!.id == id, orElse: () => null);
    if (lib == null) throw const UploadRejected(404, 'unknown library');
    return lib;
  }

  Future<shelf.Response> _uploadStatus(shelf.Request request) async {
    final LibraryRootConfig lib = _libraryFor(request);
    final String target = UploadStore.resolveTarget(lib, request.url.queryParameters['path'] ?? '');
    return _json(<String, Object?>{'received': await uploads.received(target)});
  }

  Future<shelf.Response> _upload(shelf.Request request) async {
    final LibraryRootConfig lib = _libraryFor(request);
    final String target = UploadStore.resolveTarget(lib, request.url.queryParameters['path'] ?? '');
    final ({int start, int? total})? range = parseContentRange(request.headers['content-range']);
    final ({int received, bool complete}) r = await uploads.putChunk(
      target: target,
      body: request.read(),
      rangeStart: range?.start,
      total: range?.total,
      declaredLength: request.contentLength ?? 0,
    );
    if (r.complete) ctx.log.info('upload complete: $target');
    return _json(<String, Object?>{'received': r.received, 'complete': r.complete});
  }

  // ── Anki 落地 ─────────────────────────────────────────────────────

  ServerAnkiLanding _ankiLanding() {
    final ServerAnkiLanding? anki = ctx.host.anki;
    if (anki == null) throw const FormatException('the interconnect host is not running');
    return anki;
  }

  AnkiSyncSession _ankiSession() {
    final AnkiSyncSession? session = _ankiLanding().session;
    if (session == null) {
      throw const FormatException('fushi-anki-sync is not bundled with this server');
    }
    return session;
  }

  Future<shelf.Response> _anki() async {
    final ServerAnkiLanding anki = _ankiLanding();
    final AnkiSyncSession? session = anki.session;
    final AnkiSyncAccount? account = await session?.account();
    final AnkiSyncState? state = session == null ? null : await session.refresh();
    final AnkiSettings s = anki.settings;
    final AnkiNoteType? noteType = s.availableNoteTypes
        .where((AnkiNoteType t) => t.name == s.selectedNoteTypeName)
        .firstOrNull;
    int pending = 0;
    int failed = 0;
    for (final PendingMineRow row in await anki.store.all()) {
      if (row.status == PendingMineStatus.failed) {
        failed++;
      } else {
        pending++;
      }
    }
    final AnkiBoxLandingReport? r = anki.lastReport;
    return _json(<String, Object?>{
      'available': anki.available,
      'account': account == null
          ? null
          : <String, Object?>{
              'server': account.server,
              'endpoint': account.endpoint,
              'username': account.username,
            },
      'sync': state == null
          ? null
          : <String, Object?>{
              'phase': state.phase.name,
              'unsynced': state.unsynced,
              'failing': state.failing,
              'lastError': state.lastError,
              'lastSyncAt': state.lastSyncAt,
              'message': state.message,
            },
      'landing': <String, Object?>{
        'enabled': anki.landingEnabled,
        'pending': pending,
        'failed': failed,
        'lastRunAt': anki.lastRunAt,
        'lastError': anki.lastError,
        'lastReport': r == null
            ? null
            : <String, Object?>{
                'received': r.received,
                'delivered': r.delivered,
                'failed': r.failed,
                'waiting': r.waiting,
              },
      },
      'settings': <String, Object?>{
        'decks': <String>[for (final AnkiDeck d in s.availableDecks) d.name],
        'noteTypes': <String>[for (final AnkiNoteType t in s.availableNoteTypes) t.name],
        'deck': s.selectedDeckName,
        'noteType': s.selectedNoteTypeName,
        'fields': noteType?.fields ?? const <String>[],
        'fieldMappings': s.fieldMappings,
        'tags': s.tags,
      },
      'placeholders': AnkiHandlebarOptions.coreOptions,
    });
  }

  Future<shelf.Response> _ankiLogin(Map<String, dynamic> body) async {
    final String server = (body['endpoint'] as String? ?? '').trim();
    final String username = (body['username'] as String? ?? '').trim();
    final String password = body['password'] as String? ?? '';
    if (username.isEmpty || password.isEmpty) {
      throw const FormatException('username and password are required');
    }
    // AnkiWeb 的条款只允许官方客户端；WebUI 先让用户确认风险再带上这一位。
    if (server.isEmpty && body['acceptAnkiWeb'] != true) {
      throw const FormatException('confirm the AnkiWeb risk first');
    }
    try {
      await _ankiSession().signIn(
        endpoint: server.isEmpty ? null : server,
        username: username,
        password: password,
      );
    } on AnkiSyncHasUnsyncedNotes catch (e) {
      return _err(409, '${e.count} card(s) have not synced yet; sync them before switching account');
    }
    await _ankiLanding().refreshMeta();
    return _json(const <String, Object?>{'ok': true});
  }

  Future<shelf.Response> _putAnkiSettings(Map<String, dynamic> body) async {
    final ServerAnkiLanding anki = _ankiLanding();
    final AnkiSettings current = anki.settings;
    AnkiSettings next = current;
    final Object? deck = body['deck'];
    if (deck is String) {
      final AnkiDeck? d = current.availableDecks.where((AnkiDeck x) => x.name == deck).firstOrNull;
      if (d == null) throw FormatException('unknown deck $deck');
      next = next.copyWith(selectedDeckId: d.id, selectedDeckName: d.name);
    }
    final Object? noteType = body['noteType'];
    if (noteType is String) {
      final AnkiNoteType? t =
          current.availableNoteTypes.where((AnkiNoteType x) => x.name == noteType).firstOrNull;
      if (t == null) throw FormatException('unknown note type $noteType');
      next = next.copyWith(
        selectedNoteTypeId: t.id,
        selectedNoteTypeName: t.name,
        // 换了笔记类型：只保留新类型里还有的字段的映射，旧字段名不带过去。
        fieldMappings: <String, String>{
          for (final MapEntry<String, String> e in next.fieldMappings.entries)
            if (t.fields.contains(e.key)) e.key: e.value,
        },
      );
    }
    final Object? mappings = body['fieldMappings'];
    if (mappings is Map) {
      next = next.copyWith(
        fieldMappings: <String, String>{
          for (final MapEntry<Object?, Object?> e in mappings.entries)
            if (e.key is String && e.value is String) e.key! as String: e.value! as String,
        },
      );
    }
    final Object? tags = body['tags'];
    if (tags is String) next = next.copyWith(tags: tags);
    await anki.saveSettings(next);
    // 刚配好：等着的卡立刻落一轮。
    unawaited(anki.runNow());
    return _json(const <String, Object?>{'ok': true});
  }
}
