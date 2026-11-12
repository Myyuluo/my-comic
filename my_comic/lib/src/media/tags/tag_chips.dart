/// 标签 chip 的共享 M3 Expressive 形态（书架 / 漫画库 / 视频库 / 游戏库、标签选择器、
/// 标签管理、合集详情共用同一件）。
///
/// - [MyComicTagToggleChip]：**filter chip**。三态（未选 / 部分 / 全选）——批量给多个
///   条目打标签时，「部分已有」要能和「全都有 / 全没有」区分开。M3E：未选是淡淡的
///   标签色调底 + 前置色点、全胶囊；选中铺满饱和的标签色 + 勾号，外形由弹簧从胶囊
///   形变成圆角方（[MyComicMorphBorder]），按压回弹（[MyComicPressScale]）。
/// - [MyComicTagInputChip]：**input chip**（已选标签行）。饱和标签色 + 行尾 ×。
///
/// Apple 设计系统两者都委托给既有的 [MyComicTagChip]（液态玻璃胶囊 + 色点），不铺
/// 饱和色块；墨水屏一律实心反色、不做形变。
library;

import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/components/my_comic_press_scale.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_icon.dart';
import 'package:my_comic/utils.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';

/// 一个标签相对于一组目标的勾选状态。
enum TagCheckState {
  /// 没有任何目标带这个标签。
  none,

  /// 部分目标带（只出现在多目标批量里）。
  partial,

  /// 全部目标都带。
  all,
}

/// 标签色上的前景色：亮色标签配深字、暗色标签配白字（WCAG 粗判，标签色是用户
/// 内容、可能是任意色）。
Color myComicTagOnColor(Color color) =>
    color.computeLuminance() > 0.45 ? const Color(0xDD000000) : Colors.white;

/// 未选中 chip 的淡标签色调底：标签色 16%（暗色 22%）叠在容器色上。
Color myComicTagTonalColor(BuildContext context, Color color) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final bool dark = scheme.brightness == Brightness.dark;
  return Color.alphaBlend(
    color.withValues(alpha: dark ? 0.22 : 0.16),
    scheme.surfaceContainerLow,
  );
}

/// M3E 标签 filter chip（见库注释）。
class MyComicTagToggleChip extends StatefulWidget {
  const MyComicTagToggleChip({
    required this.label,
    required this.color,
    required this.state,
    super.key,
    this.onTap,
    this.onLongPress,
    this.count,
    this.dimmed = false,
    this.tooltip,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final Color color;
  final TagCheckState state;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 行尾计数（如筛选命中数 / 标签下条目数），null = 不显示。
  final int? count;

  /// 拖拽悬停的目标位、不可用等弱化态。
  final bool dimmed;
  final String? tooltip;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  State<MyComicTagToggleChip> createState() => _MyComicTagToggleChipState();
}

class _MyComicTagToggleChipState extends State<MyComicTagToggleChip>
    with SingleTickerProviderStateMixin {
  late final MyComicSpring _select = MyComicSpring(
    vsync: this,
    initial: widget.state == TagCheckState.none ? 0 : 1,
    spring: myComicExpressiveDefaultSpatial,
  );

  @override
  void initState() {
    super.initState();
    // initState 里建好弹簧（见 MyComicPressMorph 的同款说明：懒建会在 dispose 时
    // 于已停用元素上 createTicker）。
    _select;
  }

  @override
  void didUpdateWidget(MyComicTagToggleChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _select.animateTo(
        widget.state == TagCheckState.none ? 0 : 1,
        animate: myComicExpressiveMotionEnabled(context),
      );
    }
  }

  @override
  void dispose() {
    _select.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return MyComicTagChip(
        label: widget.state == TagCheckState.partial
            ? '${widget.label} · ${_partialMark()}'
            : widget.count == null
                ? widget.label
                : '${widget.label}  ${widget.count}',
        color: widget.color,
        selected: widget.state != TagCheckState.none,
        dimmed: widget.dimmed,
        tone: MyComicTagChipTone.surface,
        onTap: widget.onTap,
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final TagCheckState state = widget.state;
    final Color fill = switch (state) {
      TagCheckState.all => eink ? scheme.onSurface : widget.color,
      TagCheckState.partial => eink
          ? scheme.surface
          : Color.alphaBlend(
              widget.color.withValues(alpha: 0.42),
              scheme.surfaceContainerLow,
            ),
      TagCheckState.none =>
        eink ? scheme.surface : myComicTagTonalColor(context, widget.color),
    };
    final Color foreground = switch (state) {
      TagCheckState.all =>
        eink ? scheme.surface : myComicTagOnColor(widget.color),
      TagCheckState.partial || TagCheckState.none => scheme.onSurface,
    };
    final Widget leading = AnimatedSwitcher(
      duration: myComicMotionDuration(context, MyComicMotion.short),
      switchInCurve: MyComicMotion.enter,
      switchOutCurve: MyComicMotion.exit,
      transitionBuilder: (Widget child, Animation<double> a) =>
          ScaleTransition(scale: a, child: child),
      child: switch (state) {
        TagCheckState.all => MyComicIcon(
            MyComicIcons.check,
            key: const ValueKey<String>('all'),
            size: 18,
            color: foreground,
          ),
        TagCheckState.partial => MyComicIcon(
            MyComicIcons.remove,
            key: const ValueKey<String>('partial'),
            size: 18,
            color: foreground,
          ),
        TagCheckState.none => DecoratedBox(
            key: const ValueKey<String>('none'),
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              border: eink ? Border.all(color: scheme.onSurface) : null,
            ),
            child: const SizedBox(width: 10, height: 10),
          ),
      },
    );
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(width: 18, height: 18, child: Center(child: leading)),
        SizedBox(width: tokens.spacing.gap * 0.75),
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: (Theme.of(context).textTheme.labelLarge ?? const TextStyle())
                .copyWith(
              color: foreground,
              fontWeight: state == TagCheckState.none
                  ? FontWeight.w500
                  : FontWeight.w600,
            ),
          ),
        ),
        if (widget.count != null) ...<Widget>[
          SizedBox(width: tokens.spacing.gap * 0.75),
          Text(
            '${widget.count}',
            style: tokens.type.metadata.copyWith(
              color: foreground.withValues(alpha: 0.72),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
    final BorderSide side = state == TagCheckState.partial
        ? BorderSide(color: eink ? scheme.onSurface : widget.color, width: 1.5)
        : eink && state == TagCheckState.none
            ? BorderSide(color: scheme.outline)
            : BorderSide.none;
    Widget chip = AnimatedBuilder(
      animation: _select.animation,
      builder: (BuildContext context, Widget? child) {
        // 0 = 全胶囊（未选），1 = 圆角 10 的圆角方（选中）。
        final double pill = (1 - _select.value).clamp(0.0, 1.0);
        final OutlinedBorder shape = MyComicMorphBorder(
          radius: 10,
          startPill: pill,
          endPill: pill,
          side: side,
        );
        return Material(
          color: fill,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            autofocus: widget.autofocus,
            focusNode: widget.focusNode,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: child,
          ),
        );
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 36),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(
            tokens.spacing.gap * 1.25,
            6,
            tokens.spacing.gap * 1.75,
            6,
          ),
          child: content,
        ),
      ),
    );
    chip = AnimatedOpacity(
      opacity: widget.dimmed && !eink ? 0.5 : 1,
      duration: myComicMotionDuration(context, MyComicMotion.short),
      child: chip,
    );
    chip = MyComicPressScale(
      enabled: widget.onTap != null,
      scale: 0.94,
      child: chip,
    );
    final String? tooltip = widget.tooltip ??
        (state == TagCheckState.partial ? _partialMark() : null);
    if (tooltip != null) chip = MyComicTooltip(message: tooltip, child: chip);
    return Semantics(selected: state == TagCheckState.all, child: chip);
  }

  String _partialMark() => Translations.of(context).tag_picker_partial_state;
}

/// M3E 标签 input chip：饱和标签色 + 行尾 ×（已选标签行）。
class MyComicTagInputChip extends StatelessWidget {
  const MyComicTagInputChip({
    required this.label,
    required this.color,
    required this.onDeleted,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return MyComicTagChip(
        label: label,
        color: color,
        selected: true,
        tone: MyComicTagChipTone.surface,
        onDeleted: onDeleted,
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Color fill = eink ? scheme.onSurface : color;
    final Color foreground = eink ? scheme.surface : myComicTagOnColor(color);
    const OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
    );
    return Material(
      color: fill,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: tokens.spacing.gap * 1.25),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (Theme.of(context).textTheme.labelLarge ??
                          const TextStyle())
                      .copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              InkWell(
                customBorder: const CircleBorder(),
                onTap: onDeleted,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: MyComicIcon(
                    MyComicIcons.close,
                    size: 16,
                    color: foreground,
                    semanticLabel:
                        MaterialLocalizations.of(context).deleteButtonTooltip,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 标签栏首尾的动作 chip（「管理」「清除」）：M3E 是 secondaryContainer 色块的
/// 圆角方 chip（小形状档 [MyComicM3eShape.smallRadius]，与 [MyComicTagToggleChip] 的
/// 胶囊一眼区分），Apple 是玻璃胶囊（委托 [MyComicTagChip]），墨水屏页面底 + 描边。
///
/// 与 [MyComicTagToggleChip] 同高（M3 chip 容器 36 / 前置图标 18），图标与文字间距、
/// 内边距走 [MyComicSpacingTokens]。
class MyComicTagActionChip extends StatelessWidget {
  const MyComicTagActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    super.key,
  });

  /// M3 chip 前置图标边长（与 [MyComicTagToggleChip] 的勾号同档）。
  static const double iconSize = 18;

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context)) {
      return MyComicTagChip(label: label, onTap: onTap);
    }
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool eink = isEinkTheme(context);
    final double gap = tokens.spacing.gap;
    final Color fill = eink ? scheme.surface : scheme.secondaryContainer;
    final Color fg = eink ? scheme.onSurface : scheme.onSecondaryContainer;
    final OutlinedBorder shape = RoundedRectangleBorder(
      borderRadius: MyComicM3eShape.smallRadius,
      side: eink ? BorderSide(color: scheme.outline) : BorderSide.none,
    );
    return MyComicPressScale(
      scale: 0.94,
      child: Material(
        color: fill,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: tokens.density.compactControlHeight,
            ),
            child: Padding(
              padding: EdgeInsetsDirectional.fromSTEB(
                gap * 1.25,
                gap * 0.75,
                gap * 1.75,
                gap * 0.75,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MyComicIcon(icon, size: iconSize, color: fg),
                  SizedBox(width: gap * 0.75),
                  Text(
                    label,
                    style: tokens.type.controlLabel.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
