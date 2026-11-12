import 'package:flutter/foundation.dart';

/// 进程级「Download library 映射 / 关联可能变化」信号（manga-library-membership
/// 票 12）。
///
/// Rebuild download index 是全量扫描入口：它可能在页面打开期间把 `extractDir`、
/// `manga_chapter_dirs` 或 `local` 里的 manifest 关联写进库。已打开的作品详情页
/// 监听本信号，让 manifest 扫描缓存失效并重算已下载状态，不需要用户重新进入。
///
/// 信号不携带数据，监听方自行查询数据库与磁盘；只在重建结束后发一次（取消时
/// 也发：已写入的部分结果同样需要展示）。
class DownloadLibraryChanges extends ChangeNotifier {
  DownloadLibraryChanges._();

  static final DownloadLibraryChanges instance = DownloadLibraryChanges._();

  int _revision = 0;

  /// 递增的重建版本号（测试 / 诊断观察用）。
  int get revision => _revision;

  /// 通知所有已打开页面：下载索引可能变了。
  void notifyChanged() {
    _revision++;
    notifyListeners();
  }
}
