import 'dart:async';

import 'package:flutter/foundation.dart';

/// 进程级书架封面 revision：持久封面字节成功写入后递增。
///
/// 书架卡片的封面 URL 来自 `MediaItem`，而 `MediaItem` 由
/// `ReaderFushiSource.getBooksFromDb` 在 provider 里解析。后台封面字节写入
/// Program state 缓存（`MangaShelfCoverCache`）后，旧的 `MediaItem` 仍然指向
/// 远程 URL / 占位；`MangaShelfCoverService` 通过本 revision 通知书架 provider
/// 重新解析，卡片随即命中新的持久缓存封面，无需重启或切换页面。
///
/// 用进程级 broadcast 流而不是 Riverpod `StateProvider`：封面服务在数据管线里
/// 构造，没有 `Ref`；书架 provider 订阅 [events] 即可。服务只在**成功写入新
/// 字节**后调用 [bump]，失败或空字节保持静默，不产生无意义的 provider 重建。
class MangaShelfCoverRevision {
  MangaShelfCoverRevision._();

  static final StreamController<int> _controller =
      StreamController<int>.broadcast(sync: true);

  static int _value = 0;

  /// 已成功写入持久封面的次数（单调递增）。
  static int get value => _value;

  /// revision 变化事件；订阅者收到递增后的新值。
  static Stream<int> get events => _controller.stream;

  /// 成功写入一份新的持久封面字节后调用。
  static void bump() {
    _value++;
    if (!_controller.isClosed) _controller.add(_value);
  }

  /// 测试缝：避免进程内其他用例的写入影响断言。
  @visibleForTesting
  static void debugReset() => _value = 0;
}
