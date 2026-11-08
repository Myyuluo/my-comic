/// 封面网格浏览页（在线源浏览页与本地图源页）共用的骨架 / 占位 / 网格参数。
///
/// 两页的正文结构本来就同形：加载时画与结果网格同轮廓的骨架，空态 / 错误态
/// 统一用 [FushiPlaceholderMessage]。2026-11-08 审查发现本地图源独立页把这套
/// 机械结构整段复制了一份；这里只抽两边完全一致的简单件，页面自己的取数、
/// 筛选与动作仍各自持有（不把在线页的列表 / 分页逻辑拖进本地页）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_placeholder_message.dart';

/// 封面网格列数：按可用宽每 180 逻辑像素一列，夹在 2~8 列。
int coverGridColumnsFor(double maxWidth) => (maxWidth / 180).floor().clamp(2, 8);

/// 封面网格的统一参数（两页的卡片尺寸与间距必须一致，ADR 0008）。
SliverGridDelegateWithFixedCrossAxisCount coverGridDelegateFor(double maxWidth) =>
    SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: coverGridColumnsFor(maxWidth),
      childAspectRatio: 0.62,
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
    );

/// 首屏加载骨架：与结果网格同列数、同比例的封面块 + 两条标题条，整组共享
/// 一道有界闪光。
class FushiCoverGridSkeleton extends StatelessWidget {
  const FushiCoverGridSkeleton({
    required this.keyPrefix,
    required this.padding,
    super.key,
  });

  /// 控件 key 前缀：骨架 GridView 的 key 为 `<prefix>_skeleton`。
  final String keyPrefix;

  /// 网格内边距（在线源页要额外让开悬浮页头，本地图源页的页头在正文之外）。
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = coverGridColumnsFor(constraints.maxWidth);
        return FushiSkeletonShimmer(
          child: GridView.builder(
            key: ValueKey<String>('${keyPrefix}_skeleton'),
            primary: false,
            physics: const NeverScrollableScrollPhysics(),
            padding: padding,
            gridDelegate: coverGridDelegateFor(constraints.maxWidth),
            itemCount: columns * 3,
            itemBuilder: (BuildContext context, int index) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                  child: FushiSkeleton(borderRadius: FushiM3eShape.cardRadius),
                ),
                const SizedBox(height: 10),
                FushiSkeleton.line(widthFactor: 0.9),
                const SizedBox(height: 6),
                FushiSkeleton.line(widthFactor: 0.5),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 封面网格的空态 / 错误态占位：统一 SafeArea(bottom: false) 与占位组件。
class FushiCoverBrowsePlaceholder extends StatelessWidget {
  const FushiCoverBrowsePlaceholder({
    required this.icon,
    required this.message,
    this.messageKey,
    this.error = false,
    this.action,
    super.key,
  });

  final IconData icon;
  final String message;
  final Key? messageKey;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: FushiPlaceholderMessage(
        key: messageKey,
        icon: icon,
        tone: error ? FushiPlaceholderTone.error : FushiPlaceholderTone.neutral,
        message: message,
        action: action,
      ),
    );
  }
}
