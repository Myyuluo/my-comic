import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_renewal.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_revision.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/trimmed_text.dart';

/// 按 runtime 解析在线书架服务；null = 该运行时不可用。
typedef OnlineMangaServiceResolver =
    OnlineMangaLibraryService? Function(OnlineMangaRuntimeKind runtime);

/// 来源当前是否可解析（已安装且扩展与源都启用）。
///
/// 书架封面展示与「重建预热是否可用远程封面」共用这一份判据；调用方不必为了
/// 借这个 predicate 构造一个完整的 [MangaShelfCoverService]。只读数据库、不
/// 联网。
Future<bool> isOnlineMangaSourceAvailable({
  required OnlineMangaServiceResolver serviceFor,
  required OnlineMangaLibraryEntry entry,
}) async {
  final OnlineMangaLibraryService? service;
  try {
    service = serviceFor(entry.runtime);
  } on Object catch (error, stack) {
    ErrorLogService.instance.log(
      'MangaShelfCoverService.service',
      error,
      stack,
    );
    return false;
  }
  if (service == null) return false;
  final OnlineMangaRuntimeAdapter adapter = service.adapter;
  if (!adapter.isSupportedOnThisPlatform) return false;
  if (adapter is! OnlineMangaSourceAvailability) return true;
  try {
    return await (adapter as OnlineMangaSourceAvailability).isSourceAvailable(
      entry,
    );
  } on Object catch (error, stack) {
    ErrorLogService.instance.log(
      'MangaShelfCoverService.availability',
      error,
      stack,
    );
    return false;
  }
}

/// 书架封面解析 / 后台刷新编排。
///
/// 解析顺序由调用方（书架数据管线）负责；本服务提供三件事：
/// - 命中按 bookKey 的持久字节缓存；
/// - 按描述符里的当前封面 URL，经 Extension runtime 后台刷新字节；
/// - 字节获取失败时做一次受节流的详情-only 续签（票 04），拿源侧的当前封面
///   URL 后刷新字节，让签名过期不再必须等用户手动「刷新漫画」。
///
/// 刷新是**尽力而为**：来源未安装 / 停用、平台不支持、网络失败或扩展报错时
/// 一律保留旧缓存，绝不删除已有封面。真正取字节走
/// [OnlineMangaRuntimeAdapter.fetchCover]，即扩展自己的网络栈（headers、cookies
/// 与站点鉴权都由扩展处理），不经过应用的裸 HTTP 客户端。
class MangaShelfCoverService {
  MangaShelfCoverService({required this.cache, required this.serviceFor});

  final MangaShelfCoverCache cache;

  /// 按 runtime 解析在线书架服务；null = 该运行时不可用。
  final OnlineMangaServiceResolver serviceFor;

  /// 一次书架解析内按来源缓存可用性。`isSourceAvailable` 只读数据库、不联网，
  /// 但同一来源下几十本书没必要各自重读一遍 Source / Extension 表。
  final Map<String, Future<bool>> _availabilityBySource =
      <String, Future<bool>>{};

  /// 持久缓存里这本书的封面文件 URL；没有命中返回 null。
  Future<String?> cachedCoverUrl(String bookKey) => cache.coverUrlFor(bookKey);

  /// 来源当前是否可解析（已安装且扩展与源都启用）。
  ///
  /// 书架封面展示也用它决定能否回退到 `series.coverUrl`：来源缺失 / 停用时
  /// 远程 URL 多半也取不到，直接交给占位。适配器没有该能力时按旧行为视为可用
  /// （例如互联对端没有本地来源表）；运行时服务解析失败则视为不可用。
  Future<bool> isSourceAvailable(OnlineMangaLibraryEntry entry) {
    final String key = <String>[
      entry.runtime.wireValue,
      entry.extensionPackage,
      entry.sourceId,
    ].join('\u0000');
    return _availabilityBySource.putIfAbsent(
      key,
      () => _resolveSourceAvailability(entry),
    );
  }

  Future<bool> _resolveSourceAvailability(OnlineMangaLibraryEntry entry) =>
      isOnlineMangaSourceAvailable(serviceFor: serviceFor, entry: entry);

  OnlineMangaLibraryService? _serviceFor(OnlineMangaLibraryEntry entry) {
    try {
      return serviceFor(entry.runtime);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaShelfCoverService.service',
        error,
        stack,
      );
      return null;
    }
  }

  /// 若当前源 URL 与缓存来源不一致（或还没有缓存），后台取一份新字节。
  ///
  /// 返回 true 仅表示**本次真的写入了新的持久封面字节**；无缓存需要刷新、
  /// 来源不可用、运行时解析失败、取字节失败或空字节都返回 false。失败不抛出：
  /// 书架展示必须等得起，也不能因为刷新失败清掉旧封面。
  ///
  /// 成功写入后 bump [MangaShelfCoverRevision]：书架 provider 据此重新解析
  /// `MediaItem`，卡片立即改用新的持久缓存封面。无新字节时保持静默，避免
  /// 无意义的 provider 重建。
  ///
  /// 字节获取失败（403 / 404 / 5xx / 签名过期 / 解码失败）且来源可用时，额外
  /// 走一次**详情-only 自动续签**（[_renewCoverUrl]）：签名 URL 在源侧轮换后，
  /// 书架不必等用户手动「刷新漫画」也能自愈。
  Future<bool> refreshIfNeeded(
    OnlineMangaLibraryEntry entry,
    String bookKey,
  ) async {
    final String? url = trimmedOrNull(entry.series.coverUrl);
    if (url == null) return false;
    if (!await cache.needsRefresh(bookKey: bookKey, sourceUrl: url)) {
      return false;
    }
    // 来源未安装 / 未启用时不做运行时抓取：已有字节（若有）原样保留。
    if (!await isSourceAvailable(entry)) return false;
    final OnlineMangaLibraryService? service = _serviceFor(entry);
    if (service == null) return false;

    final _CoverFetchOutcome fetched = await _fetchAndStore(
      service: service,
      entry: entry,
      bookKey: bookKey,
      sourceUrl: url,
    );
    if (fetched.stored) return true;
    return _renewCoverUrl(
      entry: entry,
      bookKey: bookKey,
      failedUrl: url,
      service: service,
    );
  }

  /// 失败驱动的自动续签：向源重新读一次详情，拿当前封面 URL 后再取一次字节。
  ///
  /// 只要求**详情成功**：章节列表失败 / 为空都沿用
  /// [OnlineMangaLibraryService.refreshFromSource] 的既有语义——新的系列描述与
  /// `series.coverUrl` 落库，旧章节原样保留。新 URL 与失败 URL 相同时不重复
  /// 请求；续签失败只记日志，旧缓存 / 占位保持不变。
  ///
  /// 节流（每次启动最多一次 + 24 小时冷却）由
  /// [MangaShelfCoverRenewalThrottle.tryAcquire] 保证；本方法只负责「真的续签」。
  /// 只有源站给出真实结果才持久化冷却：离线 / 连接失败释放本次启动名额，
  /// 网络恢复后仍可续签一次。
  Future<bool> _renewCoverUrl({
    required OnlineMangaLibraryEntry entry,
    required String bookKey,
    required String failedUrl,
    required OnlineMangaLibraryService service,
  }) async {
    final MangaShelfCoverRenewalPermit? permit =
        await MangaShelfCoverRenewalThrottle.tryAcquire(
          cache: cache,
          bookKey: bookKey,
        );
    if (permit == null) return false;
    try {
      // 票 04：详情成功即落库（章节失败也带 series）。不要求章节刷新成功。
      final OnlineMangaRefreshOutcome outcome = await service.refreshFromSource(
        bookKey: bookKey,
        entry: entry,
      );
      final String? renewedUrl = trimmedOrNull(outcome.entry.series.coverUrl);
      if (renewedUrl == null || renewedUrl == failedUrl) {
        // 源站确实回了详情、只是没有新 URL：真实失败，计入冷却。
        await permit.recordAttempt();
        ErrorLogService.instance.logDiagnostic(
          'MangaShelfCoverService.renew',
          'no new cover URL for $bookKey (source still returns the failed URL)',
        );
        return false;
      }
      final _CoverFetchOutcome fetched = await _fetchAndStore(
        service: service,
        entry: outcome.entry,
        bookKey: bookKey,
        sourceUrl: renewedUrl,
      );
      if (fetched.stored) {
        await permit.recordAttempt();
        ErrorLogService.instance.logDiagnostic(
          'MangaShelfCoverService.renew',
          'renewed cover URL for $bookKey',
        );
        return true;
      }
      await _settleRenewalPermit(permit, fetched.error, bookKey);
      return false;
    } on Object catch (error, stack) {
      // 详情也没拿到（网络不可用 / 源被停用 / 平台不支持）：保留旧缓存或占位。
      await _settleRenewalPermit(permit, error, bookKey);
      ErrorLogService.instance.log(
        'MangaShelfCoverService.renew',
        error,
        stack,
      );
      return false;
    }
  }

  /// 续签尝试失败后决定是否消耗冷却：离线 / 连接失败释放名额且不落盘，
  /// 其余（403/500、解码失败、源被停用等）计入 24 小时冷却。
  Future<void> _settleRenewalPermit(
    MangaShelfCoverRenewalPermit permit,
    Object? error,
    String bookKey,
  ) async {
    if (MangaShelfCoverRenewalThrottle.isOfflineFailure(error)) {
      permit.release();
      ErrorLogService.instance.logDiagnostic(
        'MangaShelfCoverService.renew',
        'offline / connection failure for $bookKey; cooldown not persisted',
      );
      return;
    }
    await permit.recordAttempt();
  }

  /// 按 [sourceUrl] 经 Extension runtime 取字节并写入持久缓存。
  ///
  /// 成功写入才 bump revision；取字节异常、空字节与不可解码字节都只记日志并
  /// 返回失败原因（写侧 `MediaCoverService.applyCoverBytes` 的完整性校验拒绝
  /// 写入）。续签路径需要知道失败是否属于离线，因此不把异常完全吞掉。
  Future<_CoverFetchOutcome> _fetchAndStore({
    required OnlineMangaLibraryService service,
    required OnlineMangaLibraryEntry entry,
    required String bookKey,
    required String sourceUrl,
  }) async {
    try {
      final List<int> bytes = await service.adapter.fetchCover(
        entry,
        sourceUrl,
      );
      final bool stored = await cache.store(
        bookKey: bookKey,
        sourceUrl: sourceUrl,
        bytes: bytes,
      );
      if (stored) {
        MangaShelfCoverRevision.bump();
        return const _CoverFetchOutcome.stored();
      }
      ErrorLogService.instance.logDiagnostic(
        'MangaShelfCoverService.store',
        'cover bytes for $bookKey were empty or not a decodable image',
      );
      return const _CoverFetchOutcome.failed(null);
    } on Object catch (error, stack) {
      // 保留旧缓存：签名过期、Cloudflare、临时断网都不该让书架变空。
      ErrorLogService.instance.log(
        'MangaShelfCoverService.refresh',
        error,
        stack,
      );
      return _CoverFetchOutcome.failed(error);
    }
  }
}

/// 一次封面字节获取的结局；[error] 供续签路径判断是否离线。
class _CoverFetchOutcome {
  const _CoverFetchOutcome.stored() : stored = true, error = null;

  const _CoverFetchOutcome.failed(this.error) : stored = false;

  final bool stored;

  /// 取字节 / 写盘失败时的原始异常；空字节 / 不可解码时为 null。
  final Object? error;
}
