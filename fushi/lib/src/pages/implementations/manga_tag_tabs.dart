import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 漫画页标签页签的当前选择：null = 「书架」（没有任何用户标签的漫画）。
///
/// 只在漫画页使用，与共享的彩色多选 `selectedTagIdsProvider` 完全独立——其他媒体
/// 库（书籍 / 视频 / 游戏）仍保持多选筛选语义。State 活在 app 级 ProviderScope
/// 里：应用运行期间保留当前页签，进程重启（ProviderScope 重建）回到「书架」。
final StateProvider<int?> mangaTagTabSelectionProvider = StateProvider<int?>(
  (_) => null,
);

/// 「书架」页签在 [FushiAdjustableSegmented] 里的占位值。
///
/// [FushiAdjustableSegmented] 的泛型要求 `T extends Object`（不接受可空值），而
/// 页签值用 null 表示「书架」更贴近数据模型；两者之间用这个哨兵互转。
/// 标签 id 来自 SQLite 自增主键（恒为正），不会与它冲突。
const int _kShelfTabValue = -1;

/// 统计漫画页每个页签当前会显示的条目数。
///
/// 归属是排他的：没有任何用户标签的条目只计入「书架」（key `null`）；有标签的
/// 条目只算进它自己的每个标签（多标签条目在每个标签下都出现，故各页签数量之和
/// 可以大于书架总数）。
///
/// [visible] 是当前搜索 / 阅读状态（ticket 06 起再叠加漫画下载状态）过滤后的
/// 判据——页面实际渲染与数量共用同一批谓词，切换页签或改筛选时两边不会分叉。
Map<int?, int> countMangaTagTabItems(
  Iterable<MediaItem> items, {
  required String? Function(MediaItem item) bookKeyOf,
  required Map<String, List<BookTagRow>> tagMap,
  required Set<int> tagIds,
  required bool Function(MediaItem item) visible,
}) {
  final Map<int?, int> counts = <int?, int>{null: 0};
  for (final int tagId in tagIds) {
    counts[tagId] = 0;
  }
  for (final MediaItem item in items) {
    if (!visible(item)) continue;
    final String? bookKey = bookKeyOf(item);
    final List<BookTagRow>? tags = bookKey == null ? null : tagMap[bookKey];
    if (tags == null || tags.isEmpty) {
      counts[null] = counts[null]! + 1;
      continue;
    }
    final Set<int> counted = <int>{};
    for (final BookTagRow tag in tags) {
      if (!tagIds.contains(tag.id) || !counted.add(tag.id)) continue;
      counts[tag.id] = counts[tag.id]! + 1;
    }
  }
  return counts;
}

/// 漫画页标签栏：浏览页「图源 / 发现」同款浮动分段胶囊。
///
/// 首项「书架」固定在最左（不随标签区横滚），其后按标签管理页维护的顺序排列
/// 用户标签；放不下时只有标签区在胶囊内横向滚动。整排单选，选中段是
/// secondaryContainer 填充的胶囊，标签自身的颜色不参与呈现。每段右侧显示当前
/// 搜索 / 阅读状态筛选下该段会显示的漫画数（始终显示，包括 0）；标签名过长时
/// 截断，数字不截断。
class MangaTagTabBar extends StatelessWidget {
  const MangaTagTabBar({
    required this.tags,
    required this.selectedTagId,
    required this.counts,
    required this.onSelected,
    this.inline = false,
    super.key,
  });

  /// 用户标签，按标签管理页维护的顺序排列。
  final List<BookTagRow> tags;

  /// 当前选中的标签 id；null = 「书架」。
  final int? selectedTagId;

  /// 每个页签的数量（key null = 「书架」），见 [countMangaTagTabItems]。
  final Map<int?, int> counts;

  final ValueChanged<int?> onSelected;

  /// 嵌在浮动 chrome 页签位时为 true：不再加页面横向留白（chrome 行已有）。
  final bool inline;

  /// 段高：胶囊（56）减去上下各 4 的胶囊内边距。Apple 设计系统的浮动胶囊更矮，
  /// 实际高度由 [LayoutBuilder] 从约束里读，这里只是无约束时的兜底。
  static const double _fallbackSegmentHeight = 48;

  /// 单段左右内边距（与库页页签的 label padding 同值）。
  static const double _segmentPadding = 16;

  /// 标签名最大宽度：数字始终跟随可见，长名在这里截断。
  static const double _labelMaxWidth = 160;

  /// 相邻段之间的呼吸位。
  static const double _segmentGap = 4;

  @override
  Widget build(BuildContext context) {
    final Translations t = Translations.of(context);
    final List<_MangaTagTabData> entries = <_MangaTagTabData>[
      _MangaTagTabData(
        tagId: null,
        label: t.library_view_shelf,
        keySuffix: 'shelf',
      ),
      for (final BookTagRow tag in tags)
        _MangaTagTabData(
          tagId: tag.id,
          label: tag.name,
          keySuffix: '${tag.id}',
        ),
    ];
    final List<int> values = <int>[
      _kShelfTabValue,
      for (final BookTagRow tag in tags) tag.id,
    ];
    final Widget bar = FushiAdjustableSegmented<int>(
      values: values,
      selected: selectedTagId ?? _kShelfTabValue,
      onChanged: (int value) =>
          onSelected(value == _kShelfTabValue ? null : value),
      focusIdPrefix: 'manga-tag-tabs',
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool bounded = constraints.maxWidth.isFinite;
          final Widget capsule = FushiFloatingToolbarSurface(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints inner) {
                final double segmentHeight = inner.maxHeight.isFinite
                    ? inner.maxHeight
                    : _fallbackSegmentHeight;
                return _buildStrip(
                  context,
                  entries,
                  segmentHeight: segmentHeight,
                  bounded: bounded,
                );
              },
            ),
          );
          return Align(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: bounded ? null : 1,
            child: capsule,
          );
        },
      ),
    );
    if (inline) return bar;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        tokens.spacing.page,
        tokens.spacing.gap * 0.75,
        tokens.spacing.page,
        tokens.spacing.gap * 0.75,
      ),
      child: bar,
    );
  }

  Widget _buildStrip(
    BuildContext context,
    List<_MangaTagTabData> entries, {
    required double segmentHeight,
    required bool bounded,
  }) {
    Widget segmentAt(int index) => _MangaTagTabSegment(
      key: ValueKey<String>('manga_tag_tab_${entries[index].keySuffix}'),
      label: entries[index].label,
      count: counts[entries[index].tagId] ?? 0,
      selected: entries[index].tagId == selectedTagId,
      height: segmentHeight,
      keySuffix: entries[index].keySuffix,
      onTap: () => onSelected(entries[index].tagId),
    );
    if (entries.length == 1) return segmentAt(0);
    final Widget tagSegments = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 1; i < entries.length; i++) ...<Widget>[
          if (i > 1) const SizedBox(width: _segmentGap),
          segmentAt(i),
        ],
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // 「书架」固定在最左：它不在下面这段横滚区里，任何滚动位置都能点到。
        segmentAt(0),
        const SizedBox(width: _segmentGap),
        if (bounded)
          Flexible(
            child: HorizontalDragScrollable(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: tagSegments,
              ),
            ),
          )
        else
          tagSegments,
      ],
    );
  }
}

@immutable
class _MangaTagTabData {
  const _MangaTagTabData({
    required this.tagId,
    required this.label,
    required this.keySuffix,
  });

  final int? tagId;
  final String label;

  /// 页签稳定 key 的后缀：`shelf` 或标签 id（测试按它定位，不依赖文案）。
  final String keySuffix;
}

/// 单个页签：中性胶囊，选中只靠 secondaryContainer 填充；名称可截断，数量
/// 始终完整显示。
class _MangaTagTabSegment extends StatelessWidget {
  const _MangaTagTabSegment({
    required this.label,
    required this.count,
    required this.selected,
    required this.height,
    required this.keySuffix,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool selected;
  final double height;
  final String keySuffix;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final Color foreground = selected
        ? cs.onSecondaryContainer
        : cs.onSurfaceVariant;
    final TextStyle labelStyle =
        (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: foreground,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
    final TextStyle countStyle = tokens.type.metadata.copyWith(
      color: foreground,
      fontWeight: FontWeight.w500,
    );
    final OutlinedBorder shape = StadiumBorder(
      side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
    );
    final Color fill = selected
        ? cs.secondaryContainer
        : cs.secondaryContainer.withValues(alpha: 0);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        type: MaterialType.transparency,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: AnimatedContainer(
            duration: fushiMotionDuration(context, FushiMotion.short),
            curve: FushiMotion.standard,
            height: height,
            padding: const EdgeInsets.symmetric(
              horizontal: MangaTagTabBar._segmentPadding,
            ),
            decoration: ShapeDecoration(color: fill, shape: shape),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: MangaTagTabBar._labelMaxWidth,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$count',
                  key: ValueKey<String>('manga_tag_tab_count_$keySuffix'),
                  maxLines: 1,
                  softWrap: false,
                  style: countStyle,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
