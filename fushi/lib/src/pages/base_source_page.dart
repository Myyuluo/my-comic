import 'package:material_ui/material_ui.dart';

import 'package:fushi/media.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/external_media_navigation.dart';
import 'package:fushi/src/utils/misc/exit_after_persist.dart';
import 'package:fushi/utils.dart';

/// A page template which assumes use of [BaseSourcePageState] by which all
/// pages in the app that are used for when using a certain source will
/// conveniently share base functionality.
///
/// Ticket 04：查词弹窗 / 制卡 / 听书 / 设备互联已随非漫画域删除；本基类只保留
/// 媒体页退出（落盘后出栈）、外部导航登记与漫画阅读器的焦点/退出钩子。
abstract class BaseSourcePage extends BasePage {
  const BaseSourcePage({
    required this.item,
    super.key,
  });

  /// The media item pertaining to this usage instance of the source.
  final MediaItem? item;

  @override
  BaseSourcePageState<BaseSourcePage> createState();
}

abstract class BaseSourcePageState<T extends BaseSourcePage>
    extends BasePageState<T> {
  @override
  void initState() {
    super.initState();
    ExternalMediaNavigation.instance.register(
      this,
      _closeForSourceReturn,
      ownsRoute: (Route<dynamic> route) =>
          mounted && identical(ModalRoute.of(context), route),
    );
  }

  @override
  void dispose() {
    ExternalMediaNavigation.instance.unregister(this);
    super.dispose();
  }

  /// Handles leaving a source page. All sources should wrap their [build]
  /// function with a [PopScope] and call this from its `onPopInvoked`.
  Future<bool> onWillPop() async {
    final MediaSource? mediaSource = appModel.currentMediaSource;
    final MediaItem? item = widget.item;
    await onSourcePagePop();
    if (mediaSource != null) {
      await appModel.closeMedia(
        ref: ref,
        mediaSource: mediaSource,
        item: item,
      );
    }
    return true;
  }

  bool _sourceExitClaimed = false;

  /// 退出单飞门：页内退出（PopScope 回调 / 退出按钮）与外部导航收页
  /// （[_closeForSourceReturn]，经 [ExternalMediaNavigation.closeActive]）共用。
  /// 返回 false = 已经有一条退出在跑，调用方不得再跑第二遍。
  @protected
  bool claimSourceExit() {
    if (_sourceExitClaimed) return false;
    _sourceExitClaimed = true;
    return true;
  }

  Future<bool> _closeForSourceReturn() async {
    if (!mounted) return true;
    final ModalRoute<dynamic>? route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    if (!claimSourceExit()) {
      await route.completed;
      return true;
    }
    final NavigatorState navigator = Navigator.of(context);
    // BUG-2119：同步发起落库后立即出栈，不 await onWillPop——drift 写请求已排队，
    // 而无上界的 await 会把外部导航队列卡死。
    exitAfterPersist(
      persist: onWillPop,
      exit: navigator.pop,
      onPersistError: (Object error, StackTrace stack) => ErrorLogService
          .instance
          .log('BaseSourcePage.externalClose', error, stack),
    );
    await route.completed;
    return true;
  }

  /// Action to perform within the source page upon closing the media.
  Future<void> onSourcePagePop() async {}

  /// 漫画阅读器的焦点回收判据：查词弹窗已删除，恒为 false。
  bool get isDictionaryShown => false;

  /// 漫画阅读器的「关闭查词」输入动作：查词弹窗已删除，no-op。
  void clearDictionaryResult() {}
}
