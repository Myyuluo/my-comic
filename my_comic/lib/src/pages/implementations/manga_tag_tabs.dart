import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/media.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_design_tokens.dart';
import 'package:my_comic/src/utils/components/my_comic_floating_toolbar.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_apple_palette.dart';
import 'package:my_comic/src/utils/components/library_section_tabs.dart';
import 'package:my_comic/src/utils/components/settings_shared.dart';
import 'package:my_comic/src/utils/misc/platform_utils.dart';
import 'package:my_comic_core/my_comic_core.dart';

/// 漫画页标签页签的当前选择。
///
/// 只在漫画页使用，与共享的彩色多选 `selectedTagIdsProvider` 完全独立——其他媒体
/// 库（书籍 / 视频 / 游戏）仍保持多选筛选语义。State 活在 app 级 ProviderScope
/// 里：应用运行期间保留当前页签，进程重启（ProviderScope 重建）回到「书架」。
///
/// 用值类型而不是 `int?` + 哨兵：页签的两种语义（书架 / 某个标签）在类型上
/// 互斥，分派页签位与筛选谓词都不再依赖「负数 id 不会出现」这条隐含约定。
final StateProvider<MangaTabSelection> mangaTagTabSelectionProvider =
    StateProvider<MangaTabSelection>((_) => const MangaShelfTabSelection());

/// 漫画页标签页签：书架或某个用户标签。
sealed class MangaTabSelection {
  const MangaTabSelection();
}

/// 「书架」页签：没有任何用户标签的漫画。
final class MangaShelfTabSelection extends MangaTabSelection {
  const MangaShelfTabSelection();

  @override
  bool operator ==(Object other) => other is MangaShelfTabSelection;

  @override
  int get hashCode => (MangaShelfTabSelection).hashCode;

  @override
  String toString() => 'MangaShelfTabSelection()';
}

/// 某个用户标签页签。标签 id 来自 SQLite 自增主键（恒为正）。
final class MangaTagTabSelection extends MangaTabSelection {
  const MangaTagTabSelection(this.tagId);

  final int tagId;

  @override
  bool operator ==(Object other) =>
      other is MangaTagTabSelection && other.tagId == tagId;

  @override
  int get hashCode => Object.hash(MangaTagTabSelection, tagId);

  @override
  String toString() => 'MangaTagTabSelection($tagId)';
}

/// 一本漫画是否属于某个页签（排他归属，页签数量与实际渲染共用这一条判据）。
///
/// 「书架」= 没有任何用户标签；标签页签 = 带该标签（多标签漫画在每个对应标签
/// 下都出现）。
bool mangaBookBelongsToTab(
  List<BookTagRow>? tags,
  MangaTabSelection selection,
) => switch (selection) {
  MangaShelfTabSelection() => tags == null || tags.isEmpty,
  MangaTagTabSelection(:final int tagId) =>
    tags?.any((BookTagRow tag) => tag.id == tagId) ?? false,
};

/// 统计漫画页每个页签当前会显示的条目数。
///
/// 归属是排他的（见 [mangaBookBelongsToTab]）：多标签条目在每个标签下都计数，
/// 故各页签数量之和可以大于书架总数。
///
/// [visible] 是当前搜索 / 阅读状态 / 漫画下载状态过滤后的判据——页面实际渲染
/// 与数量共用同一批谓词，切换页签或改筛选时两边不会分叉。
Map<MangaTabSelection, int> countMangaTagTabItems(
  Iterable<MediaItem> items, {
  required String? Function(MediaItem item) bookKeyOf,
  required Map<String, List<BookTagRow>> tagMap,
  required Iterable<int> tagIds,
  required bool Function(MediaItem item) visible,
}) {
  final List<MangaTabSelection> tabs = <MangaTabSelection>[
    const MangaShelfTabSelection(),
    for (final int tagId in tagIds) MangaTagTabSelection(tagId),
  ];
  final Map<MangaTabSelection, int> counts = <MangaTabSelection, int>{
    for (final MangaTabSelection tab in tabs) tab: 0,
  };
  for (final MediaItem item in items) {
    if (!visible(item)) continue;
    final String? bookKey = bookKeyOf(item);
    final List<BookTagRow>? tags = bookKey == null ? null : tagMap[bookKey];
    for (final MangaTabSelection tab in tabs) {
      if (!mangaBookBelongsToTab(tags, tab)) continue;
      counts[tab] = counts[tab]! + 1;
    }
  }
  return counts;
}

/// 漫画页标签栏：标题 / 动作行下方的二级内容域分段胶囊。
///
/// 首项「书架」固定在最左（不随标签区横滚），其后按标签管理页维护的顺序排列
/// 用户标签；放不下时只有标签区在胶囊内横向滚动。整排单选，选中段是
/// secondaryContainer 填充的胶囊（Apple 设计系统 = 强调色文字、不铺底），标签
/// 自身的颜色不参与呈现。每段右侧显示当前搜索 / 阅读状态筛选下该段会显示的
/// 漫画数（始终显示，包括 0）；数量是更轻的次要色小号数字，标签名过长时截断，
/// 数字不截断。
///
/// 视觉与库页二级内容域的分段胶囊一致（`LibrarySectionTabs(secondary: true,
/// floating: true)`）：Material 是一条扁平的 surfaceContainerHigh 全胶囊、贴合
/// 内容宽、无一级工具栏投影；Apple 设计系统不画底，只按内容宽排二级文字页签。
class MangaTagTabBar extends StatelessWidget {
  const MangaTagTabBar({
    required this.tags,
    required this.selection,
    required this.counts,
    required this.onSelected,
    this.inline = false,
    super.key,
  });

  /// 用户标签，按标签管理页维护的顺序排列。
  final List<BookTagRow> tags;

  /// 当前选中的页签。
  final MangaTabSelection selection;

  /// 每个页签的数量（key = 页签），见 [countMangaTagTabItems]。
  final Map<MangaTabSelection, int> counts;

  final ValueChanged<MangaTabSelection> onSelected;

  /// 由壳的二级浮动行画出时为 true：不再加页面横向留白（二级行已有页边与
  /// 上下间距）。独立使用（无壳、页头下方自成一行）时为 false。
  final bool inline;

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
        selection: const MangaShelfTabSelection(),
        label: t.library_view_shelf,
        keySuffix: 'shelf',
      ),
      for (final BookTagRow tag in tags)
        _MangaTagTabData(
          selection: MangaTagTabSelection(tag.id),
          label: tag.name,
          keySuffix: '${tag.id}',
        ),
    ];
    final Widget bar = MyComicAdjustableSegmented<MangaTabSelection>(
      values: <MangaTabSelection>[
        for (final _MangaTagTabData entry in entries) entry.selection,
      ],
      selected: selection,
      onChanged: onSelected,
      focusIdPrefix: 'manga-tag-tabs',
      // 胶囊按内容宽贴左（摆不下时吃满可用宽、标签区在里面横滑），复用库页
      // 二级内容域的外框（`LibrarySectionTabs(secondary: true, floating: true)`
      // 同一尺寸与配色；Apple 设计系统不画底）。
      child: MyComicCompactSecondaryTabsFrame(
        key: const ValueKey<String>('manga_tag_tab_capsule'),
        height: MyComicCompactSecondaryTabsFrame.compactHeight,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints inner) {
            final bool bounded = inner.maxWidth.isFinite;
            final double segmentHeight = inner.maxHeight.isFinite
                ? inner.maxHeight
                : MyComicCompactSecondaryTabsFrame.compactHeight -
                      MyComicCompactSecondaryTabsFrame.padding * 2;
            return _buildStrip(
              context,
              entries,
              segmentHeight: segmentHeight,
              bounded: bounded,
            );
          },
        ),
      ),
    );
    if (inline) return bar;
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
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
      count: counts[entries[index].selection] ?? 0,
      selected: entries[index].selection == selection,
      height: segmentHeight,
      keySuffix: entries[index].keySuffix,
      onTap: () => onSelected(entries[index].selection),
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
    required this.selection,
    required this.label,
    required this.keySuffix,
  });

  final MangaTabSelection selection;
  final String label;

  /// 页签稳定 key 的后缀：`shelf` 或标签 id（测试按它定位，不依赖文案）。
  final String keySuffix;
}

/// 单个页签：中性胶囊，选中只靠 secondaryContainer 填充（Apple = 强调色文字、
/// 不铺底）；名称可截断，数量始终完整显示。按压 / 悬停动效与工具栏 inline
/// 胶囊共用 [MyComicCapsuleSegment]。
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
    final MyComicDesignTokens tokens = MyComicDesignTokens.of(context);
    final bool eink = isEinkTheme(context);
    final bool apple = isGlassDesign(context);
    final Color foreground = apple
        ? (selected
              ? appleColorsOf(context).accent
              : appleColorsOf(context).secondaryLabel)
        : (selected ? cs.onSecondaryContainer : cs.onSurfaceVariant);
    final TextStyle labelStyle =
        (theme.textTheme.titleSmall ?? const TextStyle()).copyWith(
          color: foreground,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        );
    // 数量是次要信息：用与标签名同一个前景色、但压到更轻的半透明，字号取
    // metadata 小号（始终完整显示，见下方 Text 的 softWrap / maxLines）。
    final TextStyle countStyle = tokens.type.metadata.copyWith(
      color: foreground.withValues(alpha: 0.7),
      fontWeight: FontWeight.w500,
    );
    final OutlinedBorder shape = StadiumBorder(
      side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
    );
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: MyComicCapsuleSegment(
        selected: selected,
        onTap: onTap,
        height: height,
        padding: const EdgeInsets.symmetric(
          horizontal: MangaTagTabBar._segmentPadding,
        ),
        shape: shape,
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
    );
  }
}
