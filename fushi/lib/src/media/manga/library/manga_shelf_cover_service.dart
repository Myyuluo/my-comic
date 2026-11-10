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

  /// 持久缓存里这本书的封面文件 URL；没有命中返回 null。
  Future<String?> cachedCoverUrl(String bookKey) => cache.coverUrlFor(bookKey);

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

    final OnlineMangaLibraryService? service;
    try {
      service = serviceFor(entry.runtime);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaShelfCoverService.service',
        error,
        stack,
      );
      return;
    }
    if (service == null) return;
    final OnlineMangaRuntimeAdapter adapter = service.adapter;
    if (!adapter.isSupportedOnThisPlatform) return;
    // 来源未安装 / 未启用时不做运行时抓取：已有字节（若有）原样保留。
    if (adapter is OnlineMangaSourceAvailability) {
      final bool available;
      try {
        available = await (adapter as OnlineMangaSourceAvailability)
            .isSourceAvailable(entry);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaShelfCoverService.availability',
          error,
          stack,
        );
        return;
      }
      if (!available) return;
    }

    try {
      final List<int> bytes = await adapter.fetchCover(entry, url);
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
