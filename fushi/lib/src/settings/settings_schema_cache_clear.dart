import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart'
    show LocalSourceArchiveReaderSession, kLocalSourceArchiveCacheDirName;
import 'package:fushi/src/media/manga/mihon/online_manga_reader_session.dart'
    show OnlineMangaReaderSession, kMangaStreamCacheDirName;
import 'package:fushi/src/settings/settings_actions.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/manga_cache_clear_service.dart';
import 'package:fushi/src/storage/manga_webview_cache_clear.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// 设置 →「存储与下载」→「数据存储位置」的「清除缓存」动作行（ticket 11）。
///
/// 复用现有设置状态行、对话框壳与进度指示器（ADR 0008）；动作只清显式缓存
/// 目录，保留下载库、本地图源（含 `cover.jpg`）、History / Reading progress /
/// 数据库与图源登录态。WebView / HTTP 缓存是 ticket 12，本文件通过
/// [MangaCacheClearStep] 列表预留了扩展位。
///
/// 副标题的占用是异步测出来的：分组渲染时（[SettingsSection.liveListenable]）
/// 触发一次，结果写进 [mangaCacheUsageBytes] 并只重建本分组。内存缓存不计入。
final ValueNotifier<int?> mangaCacheUsageBytes = ValueNotifier<int?>(null);

bool _measurementInFlight = false;
DateTime? _lastMeasuredAt;
int _usageGeneration = 0;

/// 测试缝：替换整棵清缓存步骤（页面测试不碰真实文件系统）。
@visibleForTesting
MangaCacheClearService Function(SettingsContext context)?
debugBuildMangaCacheClearService;

/// 测试缝：替换副标题占用测量（确认框仍走服务自己的 measure）。
@visibleForTesting
Future<int> Function(SettingsContext context)? debugMeasureMangaCacheBytes;

/// 测试缝：清掉模块级占用缓存，避免用例之间互相污染。
@visibleForTesting
void debugResetMangaCacheUsage() {
  _measurementInFlight = false;
  _lastMeasuredAt = null;
  _usageGeneration++;
  mangaCacheUsageBytes.value = null;
}

/// 「清除缓存」行。放在两个存储位置行之后，由 [buildContentRootsSection] 接入。
SettingsStatusItem buildClearCacheSettingsItem() {
  return SettingsStatusItem(
    id: 'storage.clear_cache',
    title: t.cache_clear_title,
    icon: FushiIcons.deleteSweep,
    subtitleBuilder: (SettingsContext context) {
      final int? bytes = mangaCacheUsageBytes.value;
      return bytes == null
          ? t.cache_clear_subtitle_measuring
          : t.cache_clear_subtitle_usage(size: FushiByteFormat.bytes(bytes));
    },
    actionLabel: t.cache_clear_button,
    onAction: clearMangaCache,
  );
}

/// 分组渲染时触发一次占用测量；30 秒内的重复渲染不再扫描磁盘。
///
/// 运行期 [AppPaths] 尚未注入（纯 Dart 测试 / 启动极早期）且没有测试缝时直接
/// 跳过：副标题短暂显示「正在计算」比在设置页构建期抛异常安全。
void ensureMangaCacheUsageMeasured(SettingsContext context) {
  if (_measurementInFlight) return;
  if (debugMeasureMangaCacheBytes == null &&
      context.appModel.appPathsOrNull == null) {
    return;
  }
  final DateTime now = DateTime.now();
  final DateTime? last = _lastMeasuredAt;
  if (last != null && now.difference(last) < const Duration(seconds: 30)) {
    return;
  }
  _measurementInFlight = true;
  final int generation = ++_usageGeneration;
  unawaited(() async {
    int? bytes;
    try {
      bytes = await (debugMeasureMangaCacheBytes ?? _measureMangaCacheBytes)(
        context,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaCacheClear.measure', error, stack);
    } finally {
      _measurementInFlight = false;
      _lastMeasuredAt = DateTime.now();
    }
    // 清理动作会推进 generation：测量期间用户已经清过缓存时，旧读数不能再
    // 覆盖清理后的新占用。
    if (bytes != null && generation == _usageGeneration) {
      mangaCacheUsageBytes.value = bytes;
    }
  }());
}

Future<int> _measureMangaCacheBytes(SettingsContext context) {
  final MangaCacheClearService service =
      (debugBuildMangaCacheClearService ?? _buildDefaultMangaCacheClearService)(
        context,
      );
  return service.measureTotalBytes();
}

/// 清理入口：确认（显示占用）→ 进度框 → 完成后 toast 释放量；不重启。
Future<void> clearMangaCache(SettingsContext settings) async {
  final MangaCacheClearService service;
  try {
    service =
        (debugBuildMangaCacheClearService ??
        _buildDefaultMangaCacheClearService)(settings);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaCacheClear.build', error, stack);
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.cache_clear_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
    }
    return;
  }

  int measuredBytes = 0;
  try {
    measuredBytes = await service.measureTotalBytes();
  } on Object {
    // 大小只是确认框展示：测不到也允许清，步骤自身仍会容错。
  }
  if (!settings.context.mounted) return;

  final bool confirmed = await showSettingsConfirmationDialog(
    settings,
    title: t.cache_clear_confirm_title,
    body: t.cache_clear_confirm_body(
      size: FushiByteFormat.bytes(measuredBytes),
    ),
    confirmLabel: t.cache_clear_button,
  );
  if (!confirmed || !settings.context.mounted) return;

  final ValueNotifier<MangaCacheClearProgress?> progressNotifier =
      ValueNotifier<MangaCacheClearProgress?>(null);
  bool progressDialogOpen = true;
  unawaited(
    showAppDialog<void>(
      context: settings.context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => PopScope(
        canPop: false,
        child: MangaCacheClearProgressDialog(
          progressNotifier: progressNotifier,
        ),
      ),
    ).whenComplete(() => progressDialogOpen = false),
  );

  final MangaCacheClearReport report;
  try {
    report = await service.run(
      onProgress: (MangaCacheClearProgress progress) =>
          progressNotifier.value = progress,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log('MangaCacheClear.run', error, stack);
    if (progressDialogOpen && settings.context.mounted) {
      Navigator.of(settings.context).pop();
    }
    progressNotifier.dispose();
    if (settings.context.mounted) {
      FushiToast.show(
        msg: t.cache_clear_failed(message: '$error'),
        severity: ToastSeverity.error,
      );
    }
    return;
  }

  if (progressDialogOpen && settings.context.mounted) {
    Navigator.of(settings.context).pop();
  }
  progressNotifier.dispose();

  // 刷新副标题：用同一套显式缓存目录重新测量（活跃会话目录仍在，不能拿
  // 「清理前 - 释放量」硬减；缓存管理器磁盘也不计入显示值）。
  _usageGeneration++;
  try {
    final int remaining = await service.measureTotalBytes();
    mangaCacheUsageBytes.value = remaining;
    _lastMeasuredAt = DateTime.now();
  } on Object {
    mangaCacheUsageBytes.value = null;
    _lastMeasuredAt = null;
  }

  if (!settings.context.mounted) return;
  final String freed = FushiByteFormat.bytes(report.freedBytes);
  if (report.hasFailures) {
    FushiToast.show(
      msg: t.cache_clear_partial(size: freed),
      severity: ToastSeverity.warning,
    );
    return;
  }
  FushiToast.show(
    msg: t.cache_clear_done(size: freed),
    severity: ToastSeverity.success,
  );
}

/// 生产环境的默认步骤列表。ticket 12 在这里追加 WebView / HTTP 缓存步骤。
MangaCacheClearService _buildDefaultMangaCacheClearService(
  SettingsContext settings,
) {
  final AppPaths? paths = settings.appModel.appPathsOrNull;
  if (paths == null) {
    throw StateError('App paths are not ready');
  }
  final AppImageCacheManager imageCacheManager = AppImageCacheManager();
  return MangaCacheClearService(
    steps: <MangaCacheClearStep>[
      MangaCacheDirectoryClearStep(
        id: 'mihon_covers',
        label: t.cache_clear_step_mihon_covers,
        // 只清 Mihon 的封面子目录；mihon/ 下的 cookies / 扩展数据不动。
        roots: <Directory>[
          Directory(p.join(paths.stateRoot.path, 'mihon', 'cache', 'covers')),
        ],
      ),
      MangaCacheActiveDirectoryClearStep(
        id: 'stream_pages',
        label: t.cache_clear_step_stream,
        root: Directory(p.join(paths.cacheRoot.path, kMangaStreamCacheDirName)),
        pruneInactive: OnlineMangaReaderSession.pruneStaleStreamCaches,
      ),
      MangaCacheActiveDirectoryClearStep(
        id: 'archive_pages',
        label: t.cache_clear_step_archive,
        root: Directory(
          p.join(paths.cacheRoot.path, kLocalSourceArchiveCacheDirName),
        ),
        pruneInactive:
            LocalSourceArchiveReaderSession.pruneStaleLocalSourceArchiveCaches,
      ),
      MangaCacheDirectoryClearStep(
        id: 'remote_covers',
        label: t.cache_clear_step_remote_covers,
        roots: <Directory>[
          Directory(p.join(paths.cacheRoot.path, 'remote_cover_cache')),
        ],
      ),
      MangaCacheDirectoryClearStep(
        id: 'thumbnails',
        label: t.cache_clear_step_thumbnails,
        roots: <Directory>[
          Directory(p.join(paths.cacheRoot.path, 'thumbnails')),
        ],
      ),
      MangaCacheManagerClearStep(
        id: 'image_manager',
        label: t.cache_clear_step_image_manager,
        measureManagerBytes: imageCacheManager.store.getCacheSize,
        emptyManager: imageCacheManager.emptyCache,
      ),
      // Ticket 12：只清默认与漫画 WebView profile 的 HTTP cache；WebView2 数据
      // 目录（cookies / localStorage / IndexedDB / Preferences）不动。
      if (Platform.isWindows)
        MangaWebViewCacheClearStep(
          id: 'webview_http',
          label: t.cache_clear_step_webview,
          profiles: buildMangaWebViewCacheProfiles(),
        ),
      MangaMemoryImageCacheClearStep(
        id: 'memory_images',
        label: t.cache_clear_step_memory_images,
      ),
    ],
  );
}

/// 清缓存进度框：线性进度 + 当前步骤名。视觉复用重建下载索引的进度框。
class MangaCacheClearProgressDialog extends StatelessWidget {
  const MangaCacheClearProgressDialog({
    required this.progressNotifier,
    super.key,
  });

  final ValueNotifier<MangaCacheClearProgress?> progressNotifier;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.72,
      scrollable: false,
      child: FushiModalSheetFrame(
        title: t.cache_clear_progress_title,
        leadingIcon: FushiIcons.deleteSweep,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: ValueListenableBuilder<MangaCacheClearProgress?>(
          valueListenable: progressNotifier,
          builder:
              (
                BuildContext context,
                MangaCacheClearProgress? progress,
                Widget? _,
              ) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FushiLinearProgressIndicator(value: progress?.fraction),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      progress?.currentLabel ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.type.listSubtitle,
                    ),
                  ],
                );
              },
        ),
      ),
    );
  }
}
