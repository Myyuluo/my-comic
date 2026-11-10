import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/trimmed_text.dart';

/// 书架封面解析 / 后台刷新编排。
///
/// 解析顺序由调用方（书架数据管线）负责；本服务只提供两件事：
/// - 命中按 bookKey 的持久字节缓存；
/// - 按描述符里的当前封面 URL，经 Extension runtime 后台刷新字节。
///
/// 刷新是**尽力而为**：来源未安装 / 停用、平台不支持、网络失败或扩展报错时
/// 一律保留旧缓存，绝不删除已有封面。真正取字节走
/// [OnlineMangaRuntimeAdapter.fetchCover]，即扩展自己的网络栈（headers、cookies
/// 与站点鉴权都由扩展处理），不经过应用的裸 HTTP 客户端。
class MangaShelfCoverService {
  MangaShelfCoverService({required this.cache, required this.serviceFor});

  final MangaShelfCoverCache cache;

  /// 按 runtime 解析在线书架服务；null = 该运行时不可用。
  final OnlineMangaLibraryService? Function(OnlineMangaRuntimeKind runtime)
  serviceFor;

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

  Future<bool> _resolveSourceAvailability(OnlineMangaLibraryEntry entry) async {
    final OnlineMangaLibraryService? service = _serviceFor(entry);
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
  /// 失败不抛出：书架展示必须等得起，也不能因为刷新失败清掉旧封面。
  Future<void> refreshIfNeeded(
    OnlineMangaLibraryEntry entry,
    String bookKey,
  ) async {
    final String? url = trimmedOrNull(entry.series.coverUrl);
    if (url == null) return;
    if (!await cache.needsRefresh(bookKey: bookKey, sourceUrl: url)) return;
    // 来源未安装 / 未启用时不做运行时抓取：已有字节（若有）原样保留。
    if (!await isSourceAvailable(entry)) return;
    final OnlineMangaLibraryService? service = _serviceFor(entry);
    if (service == null) return;

    try {
      final List<int> bytes = await service.adapter.fetchCover(entry, url);
      await cache.store(bookKey: bookKey, sourceUrl: url, bytes: bytes);
    } on Object catch (error, stack) {
      // 保留旧缓存：签名过期、Cloudflare、临时断网都不该让书架变空。
      ErrorLogService.instance.log(
        'MangaShelfCoverService.refresh',
        error,
        stack,
      );
    }
  }
}
