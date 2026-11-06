import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:fushi_core/fushi_core.dart'
    show
        EpubBookRow,
        FushiPairedPeerRow,
        kLegacySchemaBridgeAppVersion,
        kLegacySchemaBridgeReleaseUrl,
        kMinSupportedSchemaVersion,
        VideoBookRow,
        VideoDownloadJobRow;
import 'package:fushi_engine/media/discovery/discovery_download_queue.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';



import 'package:fushi_engine/sync/interconnect_device_name.dart'
    show resolveInterconnectDeviceName;
import 'package:fushi_engine/sync/pairing/fushi_pair_link.dart';
import 'package:fushi_engine/sync/sync_backend_type.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/discovery/direct_link_download.dart';


import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';

import 'package:fushi/src/platform/desktop/ctl/ctl_data_wire.dart';

import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/storage_usage_service.dart';
import 'package:fushi/src/sync/backup_service.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';

import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show withoutInterconnectHost;
import 'package:fushi/src/sync/manual_sync_ui.dart'
    show runManualSyncWithFeedback;
import 'package:fushi/src/sync/sync_auto_trigger.dart'
    show
        ManualSyncOutcome,
        SyncAssetChannelScope,
        SyncChannel,
        enabledSyncChannelBackends,
        lastFullSweepOutcome,
        syncAssetChannelScopeOf,
        syncInProgress;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        // 设置页导出的默认分类集是唯一真相源，CLI 复用而不抄一份。
        // ignore: invalid_use_of_visible_for_testing_member
        defaultBackupExportCategories,
        BackupImportMode,
        BackupImportPreset,
        DataRootMigrationPlan,
        DataRootMigrationPrecheckFailure,
        DataRootMigrationRunOutcome,
        interconnectPairFailureMessage,
        planDataRootMigration,
        runBackupImportFlowForFile,
        runDataRootMigration,
        runInterconnectLinkPairingFlow;

/// data 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/data_commands.dart`）。
///
/// 每条路由只做「门控 + 参数解析 + 调 app 既有入口 + 白名单出参」，业务都在
/// 原服务里：备份 [BackupService] / [BackupRestoreService]、同步
/// [runManualSyncWithFeedback]、下载 [AppModel.appDownloadHost] 与下载管线 / 直链队列
/// [AppModel.discoveryDownloadQueue]、媒体
/// 服务器 [MediaServerConfig.buildBrowser]、互联 [FushiSyncServerController]、存储
/// [StorageUsageService]。
List<CtlRoute> buildDataCtlRoutes(DesktopCtlContext context) {
  final _CtlDataTasks tasks = _CtlDataTasks();
  return <CtlRoute>[
    // my-comic：`.fushi.zip` 备份导入/导出路由已移除（ticket 05）。
    ..._syncRoutes(context),
    ..._peerRoutes(context),
    ..._storageRoutes(context, tasks),
  ];
}

/// 控制通道发起、在后台跑的长任务的最近一次结局（`backup status` /
/// `storage migrate-status` 读）。进度本身在 [AppModel] 上（与 app 内遮罩 / 进度条同一
/// 真相源），这里只补「终端发起的那一次最后怎样了」——任务结束后 app 侧状态会被清掉。
class _CtlDataTasks {
  Map<String, Object?>? lastBackup;
  Map<String, Object?>? lastMigration;
}

/// 破坏性动作在 app 侧的第二道门：body / query 必须带 `confirm: true`。
void _requireConfirm(CtlCall call, String what) {
  if (call.optBool('confirm') != true) {
    throw CtlFailure.badRequest('$what 需要确认（confirm: true）');
  }
}

/// 需要界面（确认框 / 提示）的动作：主窗口带到前台，返回全局 navigator 的 context。
Future<BuildContext> _uiContext(DesktopCtlContext context) async {
  await context.focusMainWindow();
  final BuildContext? ui = context.navigator?.context;
  if (ui == null || !ui.mounted) {
    throw const CtlFailure.conflict('主界面还没就绪，稍后再试');
  }
  return ui;
}

/// 不能 await 的界面流程（等用户点确认）：在后台跑，异常只进日志，不让它变成
/// 未捕获错误。
void _runDetached(String label, Future<Object?> Function() body) {
  unawaited(
    Future<Object?>.sync(body).catchError((Object error, StackTrace stack) {
      debugPrint('ctl[$label] failed: $error\n$stack');
      return null;
    }),
  );
}

// ── 备份 ─────────────────────────────────────────────────────────────

/// 与设置页「导出备份」同一份构造（`backup.part.dart` 的 `_export`）：数据根下的
/// 书 / 有声书 / 字体 / 游戏封面树一起打包。
BackupService _backupServiceFor(AppModel appModel) => BackupService(
  db: appModel.database,
  dbDirectory: appModel.databaseDirectory.path,
  dictionaryResourceDirectory: appModel.dictionaryResourceDirectory.path,
  appVersion: appModel.packageInfo.version,
  booksRootDirectory: p.join(appModel.appDirectory.path, 'fushi_books'),
  audiobooksRootDirectory: p.join(appModel.appDirectory.path, 'audiobooks'),
  fontsRootDirectory: p.join(appModel.appDirectory.path, 'custom_fonts'),
  gameCoversRootDirectory: p.join(appModel.appDirectory.path, 'game_covers'),
);

Future<Map<String, Object?>> _backupFileToWire(File file) async {
  final BackupMeta? meta = await BackupRestoreService.validateBackup(file.path);
  return <String, Object?>{
    'path': file.path,
    'name': p.basename(file.path),
    'bytes': await file.length(),
    'valid': meta != null,
    if (meta != null) ...backupMetaToWire(meta),
  };
}

List<CtlRoute> _syncRoutes(DesktopCtlContext context) => <CtlRoute>[
  CtlRoute.get('/api/admin/sync', (CtlCall call) async {
    final SyncRepository repo = SyncRepository(context.appModel.database);
    final SyncBackendType selected = await repo.getBackendType();
    return <String, Object?>{
      'autoSync': await repo.isAutoSyncEnabled(),
      'interconnectEnabled': await repo.isInterconnectEnabled(),
      'running': syncInProgress.value,
      'lastFullSweep': syncOutcomeToWire(lastFullSweepOutcome.value),
      // 「立即同步」会跑的通道（与同步编排同一份枚举），`sync run <通道>` 认这些名。
      'channels': (await enabledSyncChannelBackends(
        repo,
      )).map(syncChannelToWire).toList(),
      'backends': <Map<String, Object?>>[
        for (final SyncBackendType type in SyncBackendType.values)
          syncBackendToWire(
            type: type,
            selected: type == selected,
            configured: await repo.hasStoredBackendConfig(type),
          ),
      ],
    };
  }),
  // 与设置页「立即同步」同一入口：缺省云通道 + 互联通道一起跑；`channels` 只跑
  // 指定的通道（[runManualFullSync] 的 onlyChannels）。冲突 / 鉴权失效的交互与
  // 提示都在 app 里出现。
  CtlRoute.post('/api/admin/sync/run', (CtlCall call) async {
    final Set<SyncAssetChannelScope>? only = parseSyncChannelScopes(
      call.stringList('channels'),
    );
    if (syncInProgress.value) {
      throw const CtlFailure.conflict('已有同步在进行中');
    }
    final AppModel appModel = context.appModel;
    if (only != null) {
      // 指定了没启用的通道：说清楚，而不是让它静默以「没配置」收场。
      final Set<SyncAssetChannelScope> enabled = <SyncAssetChannelScope>{
        for (final SyncChannel channel in await enabledSyncChannelBackends(
          SyncRepository(appModel.database),
        ))
          syncAssetChannelScopeOf(channel),
      };
      final List<String> missing = <String>[
        for (final SyncAssetChannelScope s in only)
          if (!enabled.contains(s)) s.name,
      ];
      if (missing.isNotEmpty) {
        throw CtlFailure.rejected(
          '这些通道没有启用：${missing.join(', ')}（sync ls 查看可用通道）',
        );
      }
    }
    final BuildContext ui = await _uiContext(context);
    if (!ui.mounted) throw const CtlFailure.conflict('主界面还没就绪，稍后再试');
    final Future<ManualSyncOutcome> run = runManualSyncWithFeedback(
      context: ui,
      appModel: appModel,
      onlyChannels: only,
    );
    if (call.optBool('wait') != true) {
      _runDetached('sync.run', () => run);
      return const <String, Object?>{'ok': true, 'started': true};
    }
    final ManualSyncOutcome outcome = await run;
    return <String, Object?>{
      'ok': outcome == ManualSyncOutcome.completed,
      'outcome': outcome.name,
      'lastFullSweep': syncOutcomeToWire(lastFullSweepOutcome.value),
    };
  }),
];

// ── 下载 ─────────────────────────────────────────────────────────────

/// 下载中心的门：合规门（iOS 无下载中心）+「浏览」模块开关（下载页签挂在它下面）。
void _requireDownloads(AppModel appModel) {
  if (!StoreRestrictedCapability.downloads.isAvailable) {
    throw const CtlFailure.unsupported('本平台不提供下载中心');
  }
  if (!appModel.moduleVisibility.isEnabled(ModuleId.browse)) {
    throw const CtlFailure.rejected('「浏览」模块已关闭（设置 › 功能模块）');
  }
}

Future<VideoDownloadJobRow> _requireJob(AppModel appModel, String id) async {
  final VideoDownloadJobRow? job = await appModel.database.getVideoDownloadJob(
    id,
  );
  if (job == null) throw CtlFailure.notFound('没有这个下载任务：$id');
  return job;
}

// ── 互联 ─────────────────────────────────────────────────────────────

Future<Map<String, Object?>> _hostStatus(AppModel appModel) async {
  final FushiSyncServerController controller = appModel.syncServerController;
  final SyncRepository repo = SyncRepository(appModel.database);
  return <String, Object?>{
    'running': controller.isRunning,
    'enabled': await repo.isServerEnabled(),
    'port': controller.boundPort ?? await repo.getServerPort(),
    'pairedPeers': (await appModel.database.getPairedPeers()).length,
  };
}

List<CtlRoute> _peerRoutes(DesktopCtlContext context) => <CtlRoute>[
  // 两个方向的对端：本机作为 client 记住的 host 地址，以及已配对到本机 host 的
  // 设备。令牌 / 证书只报「有没有」。
  CtlRoute.get('/api/admin/peers', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    final SyncRepository repo = SyncRepository(appModel.database);
    final List<FushiPairedPeerRow> paired = await appModel.database
        .getPairedPeers();
    return <String, Object?>{
      'hosts': (await repo.getFushiClientUrls())
          .map(peerHostUrlToWire)
          .toList(),
      'clients': <Map<String, Object?>>[
        for (final FushiPairedPeerRow row in paired)
          <String, Object?>{
            'peerId': row.peerId,
            if (row.deviceName != null) 'deviceName': row.deviceName,
            'pairedAt': row.pairedAtMs,
            if (row.lastSeenIp != null) 'lastSeenIp': row.lastSeenIp,
          },
      ],
    };
  }),
  CtlRoute.get('/api/admin/peers/host', (CtlCall call) async {
    return _hostStatus(context.appModel);
  }),
  // 与设置页「启用主机服务」开关同一序列：首次启用的 TLS 默认 → controller.start()。
  CtlRoute.post('/api/admin/peers/host/start', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    final SyncRepository repo = SyncRepository(appModel.database);
    // 角色锁（设置页 `lockedByClient`）：本机已作为 client 连着别的 host 时不能
    // 同时当 host。
    if (!await repo.isServerEnabled() &&
        (await repo.getFushiClientUrls()).isNotEmpty) {
      throw const CtlFailure.rejected('本机已作为客户端连接了 host，不能同时当 host');
    }
    await repo.applyFirstHostingTlsDefault();
    final FushiServerStartOutcome outcome = await appModel.syncServerController
        .start();
    switch (outcome) {
      case FushiServerStarted():
        return _hostStatus(appModel);
      case FushiServerPortInUse(:final int port):
        throw CtlFailure.conflict('端口 $port 已被占用');
      case FushiServerStartError(:final String message):
        throw CtlFailure.rejected(redactCtlSecrets(message));
    }
  }),
  CtlRoute.post('/api/admin/peers/host/stop', (CtlCall call) async {
    final AppModel appModel = context.appModel;
    await appModel.syncServerController.stop(persistDisabled: true);
    return _hostStatus(appModel);
  }),
  // 配对链接。缺省经 app 的确认框（链接可能来自任何网页）：拉起
  // [runInterconnectLinkPairingFlow]，结果在 app 里提示。带 `confirm: true`（CLI
  // `--yes`，本机持令牌的操作者已核对过链接）时跳过确认框，直接走同一个
  // [pairWithInterconnectLink] 并把结果回给终端；不带票据、要 PIN 的链接终端输不了
  // PIN，如实报错让用户回 app 配。
  CtlRoute.post('/api/admin/peers/pair', (CtlCall call) async {
    final String raw = call.requireString('link');
    final FushiPairLink? link = FushiPairLink.tryParse(raw);
    if (link == null) {
      throw const CtlFailure.badRequest('不是有效的 fushi://pair 配对链接');
    }
    final AppModel appModel = context.appModel;
    if (call.optBool('confirm') == true) {
      final SyncRepository repo = SyncRepository(appModel.database);
      final InterconnectLinkPairingResult result =
          await pairWithInterconnectLink(
            repo: repo,
            link: link,
            localDeviceName: await resolveInterconnectDeviceName(
              appModel.platformServices.deviceInfo,
            ),
            pinProvider: () async => null,
          );
      switch (result) {
        case InterconnectLinkPaired(
          :final String baseUrl,
          :final String? deviceName,
        ):
          return <String, Object?>{
            'ok': true,
            'paired': true,
            'url': baseUrl,
            'hostId': link.hostId,
            'deviceName': ?(deviceName ?? link.deviceName),
            'message': '已配对：${deviceName ?? link.deviceName ?? baseUrl}',
          };
        case InterconnectLinkPairingFailed(:final String reason):
          if (reason == 'cancelled' || reason == 'pin') {
            throw const CtlFailure.rejected(
              '这个链接不带一次性票据，host 要求输入 PIN；终端无法输入，去掉 --yes 在 app 里配对',
            );
          }
          throw CtlFailure.rejected(
            '配对失败（$reason）：${interconnectPairFailureMessage(reason)}',
          );
      }
    }
    final BuildContext ui = await _uiContext(context);
    _runDetached(
      'peers.pair',
      () => runInterconnectLinkPairingFlow(ui, appModel, link),
    );
    return <String, Object?>{
      'ok': true,
      if (link.deviceName != null) 'deviceName': link.deviceName,
      'message': '已在 Fushi 里弹出配对确认，请在 app 里确认',
    };
  }),
  // 本机 host 签发一次性配对链接：与设置页「扫码配对」二维码同一入口
  // [FushiSyncServerController.createPairLink]（重新签发即作废上一张票据）。链接
  // 就是要交给对方设备的东西，所以原样回给终端（二维码里本来也是它）。
  CtlRoute.post('/api/admin/peers/pair-link', (CtlCall call) async {
    final FushiSyncServerController controller =
        context.appModel.syncServerController;
    final FushiPairLink? link = await controller.createPairLink();
    if (link == null) {
      throw const CtlFailure.conflict('本机互联 host 没在运行（peer host start）');
    }
    if (link.addresses.isEmpty) {
      // 与二维码窗口同一判据：没有可公布的地址，对方拿到链接也连不上。
      controller.revokePairTicket();
      throw const CtlFailure.rejected(
        '本机 host 没有可公布的地址（只监听本机？在设置 › 互联里开放局域网访问）',
      );
    }
    return <String, Object?>{
      'link': link.toUri(),
      'hostId': link.hostId,
      'deviceName': ?link.deviceName,
      'oneTime': link.hasTicket,
      'addresses': link.addresses.map(pairLinkAddressToWire).toList(),
    };
  }),
  // 作废当前配对票据（= 关掉二维码窗口），凭它开出、还没确认的会话一并作废。
  CtlRoute.delete('/api/admin/peers/pair-link', (CtlCall call) async {
    context.appModel.syncServerController.revokePairTicket();
    return const <String, Object?>{'ok': true, 'revoked': true};
  }),
  // 吊销一台已配对到本机 host 的设备：与设置页「移除已配对设备」同一入口
  // [FushiSyncServerController.revokePeer]（删 per-peer token，下一次请求即 401）。
  CtlRoute.delete('/api/admin/peers/clients/:peerId', (CtlCall call) async {
    _requireConfirm(call, '吊销已配对设备');
    final String peerId = call.params['peerId']!;
    final bool revoked = await context.appModel.syncServerController.revokePeer(
      peerId,
    );
    if (!revoked) throw CtlFailure.notFound('没有这台已配对设备：$peerId（peer ls 查看）');
    return <String, Object?>{'ok': true, 'peerId': peerId};
  }),
  // 忘记本机作为 client 记住的一台 host：与设置页地址行「删除」同一变换
  // [withoutInterconnectHost]，经 [SyncRepository.updateFushiClientUrls] 串行写库
  // （与后台地址学习、链接配对互斥）。按 hostId 认：同一台 host 的全部地址一起删。
  CtlRoute.delete('/api/admin/peers/hosts/:host', (CtlCall call) async {
    _requireConfirm(call, '忘记 host');
    final SyncRepository repo = SyncRepository(context.appModel.database);
    final ({String url, String? hostId}) target = resolveForgetHost(
      await repo.getFushiClientUrls(),
      call.params['host']!,
    );
    int removed = 0;
    final List<FushiClientUrl> after = await repo.updateFushiClientUrls((
      List<FushiClientUrl> current,
    ) {
      final List<FushiClientUrl> next = withoutInterconnectHost(
        current,
        url: target.url,
        hostId: target.hostId,
      );
      removed = current.length - next.length;
      return next;
    });
    return <String, Object?>{
      'ok': true,
      'url': target.url,
      'hostId': ?target.hostId,
      'removedAddresses': removed,
      'remainingAddresses': after.length,
    };
  }),
];

// ── 存储 ─────────────────────────────────────────────────────────────

List<CtlRoute> _storageRoutes(DesktopCtlContext context, _CtlDataTasks tasks) =>
    <CtlRoute>[
      // 数据目录迁移：与设置 › 存储「更改位置」同一套 [planDataRootMigration]（解析 +
      // 触发前校验）→ [runDataRootMigration]（关库 → 搬移 → 写位置 → 自动重启）。
      // `dryRun` 只出解析后的两个落点（= 设置页确认框里列的那两行），不动任何东西。
      // 真迁移要 `confirm: true`；它会关掉数据库并在成功后重启 app，所以在后台跑、
      // 立即返回，进度用 GET 查（重启后控制通道换成新进程的）。
      CtlRoute.post('/api/admin/storage/migrate', (CtlCall call) async {
        final String path = call.requireString('path');
        if (!p.isAbsolute(path)) {
          throw CtlFailure.badRequest('目标目录必须是绝对路径：$path');
        }
        final bool dryRun = call.optBool('dryRun') ?? false;
        if (!dryRun) _requireConfirm(call, '迁移数据目录');
        final AppModel appModel = context.appModel;
        if (appModel.dataRootMigrationActive) {
          throw const CtlFailure.conflict('数据目录迁移已在进行中');
        }
        if (appModel.backupExportActive) {
          throw const CtlFailure.conflict('备份导出进行中，先等它结束');
        }
        final DataRootMigrationPlan plan;
        try {
          plan = await planDataRootMigration(appModel: appModel, picked: path);
        } on DataRootMigrationPrecheckFailure catch (e) {
          throw CtlFailure.rejected(e.message);
        }
        final Map<String, Object?> planWire = <String, Object?>{
          'path': path,
          'documentsRoot': plan.target.documentsRoot.path,
          'supportRoot': plan.target.supportRoot.path,
          'defaultLocation': plan.target.isDefaultLocation,
          'fromDocumentsRoot': plan.oldDocumentsRoot,
          'fromSupportRoot': plan.oldSupportRoot,
        };
        if (dryRun) return <String, Object?>{...planWire, 'dryRun': true};
        tasks.lastMigration = <String, Object?>{
          ...planWire,
          'state': 'running',
          'startedAt': DateTime.now().millisecondsSinceEpoch,
        };
        _runDetached('storage.migrate', () async {
          try {
            final DataRootMigrationRunOutcome outcome =
                await runDataRootMigration(appModel: appModel, plan: plan);
            tasks.lastMigration = <String, Object?>{
              ...planWire,
              'state': outcome.name,
              if (appModel.dataRootMigrationFailure != null)
                'message': appModel.dataRootMigrationFailure,
            };
          } on DataRootMigrationPrecheckFailure catch (e) {
            tasks.lastMigration = <String, Object?>{
              ...planWire,
              'state': 'failed',
              'message': e.message,
            };
          }
          return null;
        });
        return <String, Object?>{
          ...planWire,
          'ok': true,
          'started': true,
          'message':
              '已开始迁移（app 显示迁移遮罩，数据库已关闭）；成功后 app 会自动重启。'
              '用 storage migrate-status 查进度，重启后 storage root 确认新位置',
        };
      }),
      CtlRoute.get('/api/admin/storage/migrate', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final ({int copied, int total})? progress =
            appModel.dataRootMigrationProgress;
        return <String, Object?>{
          'active': appModel.dataRootMigrationActive,
          // 跨盘逐文件复制时才有（已复制文件数 / 总文件数）；同盘 rename 瞬时完成、无进度。
          if (progress != null) 'copiedFiles': progress.copied,
          if (progress != null) 'totalFiles': progress.total,
          'failure': ?appModel.dataRootMigrationFailure,
          'last': ?tasks.lastMigration,
        };
      }),
      CtlRoute.get('/api/admin/storage/root', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final Directory documents = await AppPaths.documentsRootDirectory();
        final Directory defaultDocuments =
            await AppPaths.defaultLocationDocumentsRoot();
        return <String, Object?>{
          'documents': documents.path,
          'support': (await AppPaths.supportRootDirectory()).path,
          'temp': (await AppPaths.tempRootDirectory()).path,
          'database': appModel.databaseDirectory.path,
          'customDataRoot': !p.equals(documents.path, defaultDocuments.path),
        };
      }),
      // 与设置 › 存储页同一个扫描器，只出类目合计（明细行要书目清单，存储页那份
      // 组装逻辑在设置 schema 里，CLI 不复制）。
      CtlRoute.get('/api/admin/storage/usage', (CtlCall call) async {
        final AppModel appModel = context.appModel;
        final List<Map<String, Object?>> categories = <Map<String, Object?>>[];
        int total = 0;
        await for (final StorageCategoryUsage usage
            in StorageUsageService().scanCategories(
              books: const <StorageBookRef>[],
              dictionaryNames: <String>[
                for (final Dictionary dictionary in appModel.dictionaries)
                  dictionary.name,
              ],
            )) {
          total += usage.bytes;
          categories.add(<String, Object?>{
            'id': usage.id.name,
            'bytes': usage.bytes,
          });
        }
        return <String, Object?>{'totalBytes': total, 'categories': categories};
      }),
    ];
