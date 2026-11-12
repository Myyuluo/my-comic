import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_platform.dart';
import 'package:my_comic/src/utils/components/my_comic_glass_surface.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_apple_palette.dart';
import 'package:my_comic/src/utils/components/glass/my_comic_glass_lists.dart'
    show MyComicAppleMetrics, kMyComicMd3CardRadius;

/// 预留文字块高度时统一加的余量（行高取整、字体 metrics 与理论值的零头）。
const double kTextBlockSlack = 4.0;

/// 滚动条 thumb 的粗细（全局主题 + 9 处 [RawScrollbar] 的唯一真相源）。
///
/// BUG-1997：主题此前只给亮色钉了这个值、深色留 `null`，于是深色退回 Material 的
/// 默认 `_kScrollbarThickness = 8`。桌面端 `MaterialScrollBehavior` 给**每个**垂直
/// Scrollable 无条件包一层 `Scrollbar`，加上全局 `thumbVisibility: true`，结果是
/// 深色下每个列表右侧常驻一条 8+2(crossAxisMargin) = 10px 的覆盖式滚动条——它不占
/// 布局，直接盖在内容上，而且默认 `interactive`，**连点击一起吞掉**（字幕面板最右
/// 那颗星就是这么被压住并点不动的）。
const double kMyComicScrollbarThickness = 3.0;

/// 滚动条实际占据的横向宽度 = thumb 粗细 + Material 的 `crossAxisMargin`(2)。
///
/// 需要给滚动条让出独立通道（gutter）的列表按这个值内缩内容，别写死数字——它必须
/// 跟着 [kMyComicScrollbarThickness] 走，否则下次调粗细又会压回内容上。
const double kMyComicScrollbarGutter = kMyComicScrollbarThickness + 2.0;

/// 一行 [style] 文字在当前文字缩放下占的实际高度。
///
/// BUG-1184：有一类布局必须**先给出**「能放下 N 行文字」的固定高度——网格的
/// `mainAxisExtent`、横滑行的 `SizedBox`、卡片封面下方的文字块，Flutter 都要求
/// 高度先于内容确定。此前每个这样的地方各自猜一个行高系数（最常见的错法是硬编码
/// 1.3），而 MD3 排版里 `bodyLarge` 的行高是 1.5、`labelMedium` 是 1.33——猜低了
/// 就竖向溢出，表现为「书名第二行的下半截被切掉」。
///
/// 这里统一读 [TextStyle.height] 的真实值，只有当 style 自己没声明行高时才退回一个
/// 偏保守（宁可高一点）的系数。配合 [kTextBlockSlack] 使用。
double textLineHeight(BuildContext context, TextStyle style) {
  final double fontSize = style.fontSize ?? 14.0;
  final double factor = style.height ?? 1.4;
  return MediaQuery.textScalerOf(context).scale(fontSize) * factor;
}

/// 内容排版（卡面这类字号可由用户调的内容）的字号：取当前设计系统字阶角色 [role]
/// 的字号，再乘内容自己的用户缩放 [scale]。只带字号——字重 / 字族 / 颜色由内容自己定。
/// 字号只能来自字阶角色；界面 chrome 直接用角色本身，不经这里。
TextStyle myComicContentTypeSize(TextStyle role, {double scale = 1}) =>
    TextStyle(fontSize: (role.fontSize ?? MyComicTypeScale.bodyLarge.size) * scale);

class MyComicDesignTokens {
  const MyComicDesignTokens({
    required this.radii,
    required this.surfaces,
    required this.type,
    required this.spacing,
    required this.density,
  });

  final MyComicRadii radii;
  final MyComicSurfaceColors surfaces;
  final MyComicTypeRoles type;
  final MyComicSpacingTokens spacing;
  final MyComicDensityTokens density;

  // HBK-AUDIT-150: `of` is named like an O(1) lookup but used to build a fresh
  // token graph (11 Color reads + 6 TextStyle.copyWith allocations) on every
  // call — i.e. on every build of every component that reads it, several of
  // which call it more than once per build. ColorScheme/TextTheme are immutable
  // and Theme.of returns the same instance until the theme changes, so we
  // memoize by (scheme, textTheme) identity: the graph is rebuilt only when the
  // theme actually changes, and repeat calls within a frame return the cache.
  static ColorScheme? _cachedScheme;
  static TextTheme? _cachedTextTheme;
  static bool? _cachedGlass;
  static MyComicAppleColors? _cachedApple;
  static MyComicDesignTokens? _cached;

  static MyComicDesignTokens of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final TextTheme textTheme = theme.textTheme;
    // 玻璃生效（已扣除墨水屏 / 高对比度 / 降低透明度）时面板色阶半透明。
    final bool glass = glassMaterialOf(context) != MyComicGlassMaterial.off;
    // Apple 设计系统（色板扩展只挂在 Apple 主题上）：面板色阶一律实色。
    final MyComicAppleColors? apple = theme.extension<MyComicAppleColors>();
    final MyComicDesignTokens? cached = _cached;
    if (cached != null &&
        identical(_cachedScheme, scheme) &&
        identical(_cachedTextTheme, textTheme) &&
        identical(_cachedApple, apple) &&
        _cachedGlass == glass) {
      return cached;
    }
    final MyComicDesignTokens tokens = MyComicDesignTokens(
      radii: const MyComicRadii(),
      surfaces: MyComicSurfaceColors.fromScheme(
        scheme,
        glass: glass,
        apple: apple,
      ),
      type: MyComicTypeRoles.fromTheme(theme),
      spacing: const MyComicSpacingTokens(),
      density: const MyComicDensityTokens(),
    );
    _cachedScheme = scheme;
    _cachedTextTheme = textTheme;
    _cachedGlass = glass;
    _cachedApple = apple;
    _cached = tokens;
    return tokens;
  }
}

class MyComicRadii {
  const MyComicRadii({
    this.group = groupValue,
    this.card = cardValue,
    this.control = controlValue,
    this.chip = chipValue,
    this.menu = menuValue,
    this.dialog = dialogValue,
    this.sheet = sheetValue,
  });

  // Single value source for the radii scale (used by both these field defaults
  // and [MyComicBorderRadius]'s const BorderRadius objects).
  // M3E 形状分级（2026-10-05 列表 / 卡片统一，见 MyComicM3eShape）：分组容器 =
  // 卡档 20（与 MyComicCard 同形），card = 小件档 12（历史名：调用点多是卡内的
  // 缩略图 / 小块 / 预览框，与书架封面框 12 同形）。旧编辑刻度是 10 / 10。
  static const double groupValue = 20;
  static const double cardValue = 12;
  static const double controlValue = 12;
  static const double chipValue = 6;
  static const double menuValue = 16; // M3E 菜单容器圆角（large，2026-10-05 浮层统一）
  static const double dialogValue = 28; // MD3 对话框规范圆角（2026-10-04 对话框统一）
  static const double sheetValue = 28; // MD3 底部弹层上两角（2026-10-04 弹层统一）

  /// galgame 竖版海报卡的圆角（对齐 ReinaManager 的圆润卡片观感，比 MyComic 常规
  /// [cardValue] 稍大一档；见 `docs/design/galgame-library-reina-visual-parity.md`）。
  static const double posterValue = 16;

  final double group;
  final double card;
  final double control;
  final double chip;
  final double menu;
  final double dialog;
  final double sheet;

  BorderRadius get groupRadius => BorderRadius.circular(group);
  BorderRadius get cardRadius => BorderRadius.circular(card);
  BorderRadius get controlRadius => BorderRadius.circular(control);
  BorderRadius get chipRadius => BorderRadius.circular(chip);
  BorderRadius get menuRadius => BorderRadius.circular(menu);
  BorderRadius get dialogRadius => BorderRadius.circular(dialog);
  BorderRadius get sheetRadius =>
      BorderRadius.vertical(top: Radius.circular(sheet));
  Radius get chipCorner => Radius.circular(chip);
}

/// Compile-time `const` border radii — the single source for `BorderRadius`
/// across theme config and widget call sites. Radii are theme-independent, so
/// these stay `const`: migrating a hardcoded `BorderRadius.circular(N)` to one
/// of these preserves const-ness at the call site (routing through
/// `MyComicDesignTokens.of(context)` would not). Values come from [MyComicRadii].
abstract final class MyComicBorderRadius {
  static const BorderRadius group =
      BorderRadius.all(Radius.circular(MyComicRadii.groupValue));
  static const BorderRadius card =
      BorderRadius.all(Radius.circular(MyComicRadii.cardValue));
  static const BorderRadius poster =
      BorderRadius.all(Radius.circular(MyComicRadii.posterValue));
  static const BorderRadius control =
      BorderRadius.all(Radius.circular(MyComicRadii.controlValue));
  static const BorderRadius chip =
      BorderRadius.all(Radius.circular(MyComicRadii.chipValue));
  static const BorderRadius menu =
      BorderRadius.all(Radius.circular(MyComicRadii.menuValue));
  static const BorderRadius dialog =
      BorderRadius.all(Radius.circular(MyComicRadii.dialogValue));
  static const BorderRadius sheet =
      BorderRadius.vertical(top: Radius.circular(MyComicRadii.sheetValue));
  static const Radius chipCorner = Radius.circular(MyComicRadii.chipValue);
}

class MyComicSurfaceColors {
  const MyComicSurfaceColors({
    required this.primary,
    required this.primaryContainer,
    required this.page,
    required this.group,
    required this.card,
    required this.selected,
    required this.search,
    required this.overlay,
    required this.outline,
    required this.onSurface,
    required this.onVariant,
  });

  final Color primary;
  final Color primaryContainer;
  final Color page;
  final Color group;
  final Color card;
  final Color selected;
  final Color search;
  final Color overlay;
  final Color outline;
  final Color onSurface;
  final Color onVariant;

  /// [glass] 为 true（玻璃材质生效）时，分组 / 卡片 / 搜索 / 浮层这些
  /// 叠在页面之上的面板色阶改为半透明，透出外壳背后的系统窗口材质
  /// （Windows 11 Mica / macOS vibrancy）与下层内容；[page] 是页面底色本身，
  /// 恒实心（透明了窗口就直接透黑）。
  ///
  /// [apple]（Apple 设计系统的色板）非空时走 Apple 26 规则、优先于 [glass]：
  /// 内容层**一律实色**（玻璃只给浮在内容上的控件层），四档面板各差一级、
  /// 互不相同——分组 / 卡片同色时卡里套卡、卡里的进度轨道整条隐形：
  /// - group = secondarySystemGroupedBackground（MyComicCard 默认底，深 #1C1C1E / 浅 #F2F2F7）；
  /// - card = tertiarySystemGroupedBackground（分组里再嵌一层，深 #2C2C2E / 浅 #E5E5EA）；
  /// - search = surfaceContainerHighest（systemGray5 档，深 #3A3A3C / 浅 #D1D1D6）；
  /// - overlay = systemGray4 档（深 #48484A / 浅 #C7C7CC），最高一阶的占位 / 轨道。
  /// MD3 不变。
  factory MyComicSurfaceColors.fromScheme(
    ColorScheme scheme, {
    bool glass = false,
    MyComicAppleColors? apple,
  }) {
    if (apple != null) {
      final bool dark = scheme.brightness == Brightness.dark;
      return MyComicSurfaceColors(
        primary: scheme.primary,
        primaryContainer: scheme.primaryContainer,
        page: scheme.surface,
        group: apple.secondaryGroupedBackground,
        card: apple.tertiaryGroupedBackground,
        selected: scheme.secondaryContainer,
        search: scheme.surfaceContainerHighest,
        overlay: dark ? const Color(0xFF48484A) : const Color(0xFFC7C7CC),
        outline: scheme.outlineVariant,
        onSurface: scheme.onSurface,
        onVariant: scheme.onSurfaceVariant,
      );
    }
    Color panel(Color color) => glass
        ? color.withValues(
            alpha: myComicGlassContainerOpacity(scheme.brightness),
          )
        : color;
    return MyComicSurfaceColors(
      primary: scheme.primary,
      primaryContainer: scheme.primaryContainer,
      page: scheme.surface,
      group: panel(scheme.surfaceContainerLow),
      card: panel(scheme.surfaceContainer),
      selected: scheme.secondaryContainer,
      search: panel(scheme.surfaceContainerHigh),
      overlay: panel(scheme.surfaceContainerHighest),
      outline: scheme.outlineVariant,
      onSurface: scheme.onSurface,
      onVariant: scheme.onSurfaceVariant,
    );
  }
}

/// MyComicCard 的真实外圆角（拖拽浮层 / 预览框要与卡片同形时用它，别用
/// [MyComicRadii.cardRadius]——那是小件档 12，和卡片实际圆角对不上）：
/// MD3 = [kMyComicMd3CardRadius]（M3E 卡档 20）；Apple = inset grouped 分组圆角
/// （[MyComicAppleMetrics.groupBorderRadius]，iOS 24 / 桌面 12）。
BorderRadius myComicCardBorderRadius(BuildContext context) {
  if (isGlassDesign(context)) {
    return MyComicAppleMetrics.of(context).groupBorderRadius;
  }
  return const BorderRadius.all(Radius.circular(kMyComicMd3CardRadius));
}

class MyComicTypeRoles {
  const MyComicTypeRoles({
    required this.pageTitle,
    required this.listTitle,
    required this.listSubtitle,
    required this.metadata,
    required this.sectionLabel,
    required this.controlLabel,
  });

  final TextStyle pageTitle;
  final TextStyle listTitle;
  final TextStyle listSubtitle;
  final TextStyle metadata;
  final TextStyle sectionLabel;
  final TextStyle controlLabel;

  factory MyComicTypeRoles.fromTheme(ThemeData theme) {
    final TextTheme textTheme = theme.textTheme;
    final ColorScheme scheme = theme.colorScheme;
    final MyComicAppleColors? apple = theme.extension<MyComicAppleColors>();
    return MyComicTypeRoles(
      listTitle: (textTheme.bodyLarge ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: FontWeight.w500,
      ),
      listSubtitle: (textTheme.bodySmall ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      metadata: (textTheme.labelMedium ?? const TextStyle()).copyWith(
        color: scheme.onSurfaceVariant,
      ),
      // 页标题 = M3E headlineSmall Emphasized（24，Medium；Windows/Linux 取整
      // Semibold）。Apple 下 headlineSmall 本身就是 Title 3 粗体。
      pageTitle: (textTheme.headlineSmall ?? const TextStyle()).copyWith(
        color: scheme.onSurface,
        fontWeight: apple != null
            ? null
            : myComicPlatformFontWeight(
                MyComicTypeScale.headlineSmall.emphasizedWeight),
      ),
      // 分组标题（2026-10-04）：MD3 规范的分组标题可以用主色——titleSmall
      // primary Emphasized；Apple 的分组标题是 13 号 semibold 的 secondaryLabel 灰字
      // （主色粗体在 iOS 分组列表里是 MD3 口音）。Apple 色板扩展只在 Apple
      // 设计系统的主题里挂（buildMyComicThemeData），据此分流。
      sectionLabel: apple != null
          ? (textTheme.labelMedium ?? const TextStyle()).copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: apple.secondaryLabel,
            )
          : (textTheme.titleSmall ?? const TextStyle()).copyWith(
              color: scheme.primary,
              // M3E titleSmall Emphasized（Bold）。
              fontWeight: myComicPlatformFontWeight(
                  MyComicTypeScale.titleSmall.emphasizedWeight),
            ),
      controlLabel: textTheme.labelLarge ?? const TextStyle(),
    );
  }
}

class MyComicSpacingTokens {
  const MyComicSpacingTokens({
    this.page = 20,
    this.rowHorizontal = 16,
    this.rowVertical = 12,
    this.card = 20,
    this.gap = 8,
    this.section = 32,
  });

  // Editorial rhythm on an 8/4px grid (was page16/rowV10/card16; rowV10 was
  // off-grid). `section` is new: spacing between major grouped sections.
  final double page;
  final double rowHorizontal;
  final double rowVertical;
  final double card;
  final double gap;
  final double section;
}

class MyComicDensityTokens {
  const MyComicDensityTokens({
    this.listMinHeight = 56,
    this.compactListMinHeight = 44,
    this.controlHeight = 48,
    this.compactControlHeight = 36,
  });

  final double listMinHeight;
  final double compactListMinHeight;
  final double controlHeight;
  final double compactControlHeight;
}

/// One role's type spec (size/weight/line-height/tracking + the M3 Expressive
/// emphasized weight). Applied onto the locale-aware base [TextStyle] so the
/// per-locale fontFamily/fontFeatures/baseline injection is preserved while
/// size/weight/height come from the scale.
class MyComicTypeSpec {
  const MyComicTypeSpec(
    this.size,
    this.weight,
    this.height, [
    this.letterSpacing,
    this.emphasizedWeight = FontWeight.w500,
  ]);

  final double size;
  final FontWeight weight;

  /// Line height as a multiple of [size] (M3 line-height token / size).
  final double height;

  /// Latin tracking in logical px (M3 tracking token). Dropped for CJK UI
  /// locales — positive tracking spaces ideographs apart.
  final double? letterSpacing;

  /// Weight of the M3E "Emphasized" variant of this role.
  final FontWeight emphasizedWeight;

  TextStyle applyTo(TextStyle base) => _apply(base, weight);

  /// The M3E emphasized variant (same size / line height, heavier weight).
  TextStyle applyEmphasizedTo(TextStyle base) => _apply(base, emphasizedWeight);

  TextStyle _apply(TextStyle base, FontWeight w) {
    final bool cjk = myComicTypeIsCjk(base);
    return base.copyWith(
      fontSize: size,
      fontWeight: myComicPlatformFontWeight(w),
      height: cjk && height < kMyComicCjkMinLineHeight && size <= 22
          ? kMyComicCjkMinLineHeight
          : height,
      letterSpacing: cjk ? 0 : (letterSpacing ?? 0),
    );
  }
}

/// CJK UI 正文 / 标签 / 标题的最小行高倍数。M3 的 12/16（1.33）等行高按拉丁字
/// 母设计；汉字与假名是满框字形，M3 对「tall scripts」的指引就是加大行高。
/// 1.4 是旧 editorial 阶梯在 CJK 下验证过的下限。只作用于 ≤22 的字号，大字号
/// 标题 / 数字的紧行高保持规范值。
const double kMyComicCjkMinLineHeight = 1.4;

/// [base] 是否是 CJK UI 文本（`AppModel.textStyle` 对 ja/zh/ko 显示语言注入
/// locale 与 ideographic 基线）。
bool myComicTypeIsCjk(TextStyle base) {
  if (base.textBaseline == TextBaseline.ideographic) return true;
  switch (base.locale?.languageCode) {
    case 'ja':
    case 'zh':
    case 'ko':
      return true;
    default:
      return false;
  }
}

/// 字重按平台系统 UI 字体实际具备的字面取整：Windows / Linux 的系统 UI 字体
/// （Microsoft YaHei UI 只有 Light / Regular / Bold，常见 Noto Sans CJK 发行裁剪
/// 同理）没有 500 Medium 字面，w500 会落回 Regular——M3 的 Medium（title / label
/// 基础字重、大部分 Emphasized 字重）在这两端就与正文无从区分。这里把 w500 升到
/// w600（Segoe UI / Yu Gothic UI 有 Semibold，YaHei 取 Bold），保住层级；
/// Android（Roboto Medium）/ Apple（SF Medium）原样。
FontWeight myComicPlatformFontWeight(FontWeight weight) {
  if (weight != FontWeight.w500) return weight;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
      return FontWeight.w600;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
    case TargetPlatform.fuchsia:
      return weight;
  }
}

/// The app's Material type scale — **M3 Expressive** (2026-10-05): the M3
/// baseline type scale (sizes / line heights / tracking from
/// `material-components-android` typography tokens) plus the M3E emphasized
/// weights (Compose `TypeScaleTokens.*EmphasizedWeight`: display / headline /
/// title-large / body → Medium, title-medium / title-small / label → Bold).
///
/// CJK UI locales drop tracking and get a 1.4 line-height floor on small roles
/// ([MyComicTypeSpec.applyTo]); Windows / Linux snap w500 to w600
/// ([myComicPlatformFontWeight]). The Apple design system maps the same 15 roles
/// to Apple HIG text styles ([MyComicAppleTypeScale]).
abstract final class MyComicTypeScale {
  static const MyComicTypeSpec displayLarge =
      MyComicTypeSpec(57, FontWeight.w400, 64 / 57, -0.25);
  static const MyComicTypeSpec displayMedium =
      MyComicTypeSpec(45, FontWeight.w400, 52 / 45, 0);
  static const MyComicTypeSpec displaySmall =
      MyComicTypeSpec(36, FontWeight.w400, 44 / 36, 0);
  static const MyComicTypeSpec headlineLarge =
      MyComicTypeSpec(32, FontWeight.w400, 40 / 32, 0);
  static const MyComicTypeSpec headlineMedium =
      MyComicTypeSpec(28, FontWeight.w400, 36 / 28, 0);
  static const MyComicTypeSpec headlineSmall =
      MyComicTypeSpec(24, FontWeight.w400, 32 / 24, 0);
  static const MyComicTypeSpec titleLarge =
      MyComicTypeSpec(22, FontWeight.w400, 28 / 22, 0);
  static const MyComicTypeSpec titleMedium =
      MyComicTypeSpec(16, FontWeight.w500, 24 / 16, 0.15, FontWeight.w700);
  static const MyComicTypeSpec titleSmall =
      MyComicTypeSpec(14, FontWeight.w500, 20 / 14, 0.1, FontWeight.w700);
  static const MyComicTypeSpec bodyLarge =
      MyComicTypeSpec(16, FontWeight.w400, 24 / 16, 0.5);
  static const MyComicTypeSpec bodyMedium =
      MyComicTypeSpec(14, FontWeight.w400, 20 / 14, 0.25);
  static const MyComicTypeSpec bodySmall =
      MyComicTypeSpec(12, FontWeight.w400, 16 / 12, 0.4);
  static const MyComicTypeSpec labelLarge =
      MyComicTypeSpec(14, FontWeight.w500, 20 / 14, 0.1, FontWeight.w700);
  static const MyComicTypeSpec labelMedium =
      MyComicTypeSpec(12, FontWeight.w500, 16 / 12, 0.5, FontWeight.w700);
  static const MyComicTypeSpec labelSmall =
      MyComicTypeSpec(11, FontWeight.w500, 16 / 11, 0.5, FontWeight.w700);

  /// The 15 roles in [TextTheme] order (display → label, L → S).
  static const List<MyComicTypeSpec> roles = <MyComicTypeSpec>[
    displayLarge,
    displayMedium,
    displaySmall,
    headlineLarge,
    headlineMedium,
    headlineSmall,
    titleLarge,
    titleMedium,
    titleSmall,
    bodyLarge,
    bodyMedium,
    bodySmall,
    labelLarge,
    labelMedium,
    labelSmall,
  ];

  /// Build the full 15-slot [TextTheme] by applying the scale onto [base]
  /// (the locale-aware app text style). Explicit sizes survive the geometry
  /// application `MaterialApp` performs (verified), so these values win.
  static TextTheme buildTextTheme(TextStyle base) =>
      myComicTextThemeFromRoles(roles, base);
}

/// Apple 设计系统的字阶：Apple HIG 的 iOS 动态字体默认档（Large），映射到
/// 同样的 15 个 Material 角色，组件代码不分设计系统取同一个槽位：
///
/// | 角色 | HIG 样式 | 字号 / 行高 |
/// |---|---|---|
/// | displayLarge / Medium | 大号数字（Health / Fitness 指标） | 48 / 40 |
/// | displaySmall | Large Title | 34 / 41 |
/// | headlineLarge / Medium / Small | Title 1 / 2 / 3 | 28/34 · 22/28 · 20/25 |
/// | titleLarge | Headline | 17 / 22 |
/// | titleMedium / Small | Callout / Subheadline | 16/21 · 15/20 |
/// | bodyLarge / Medium / Small | Body / Subheadline / Footnote | 17/22 · 15/20 · 13/18 |
/// | labelLarge / Medium / Small | Subheadline / Caption 1 / Caption 2 | 15/20 · 12/16 · 11/13 |
///
/// 字重沿用 Apple 设计系统此前的层级（标题粗体、分组标题 semibold），
/// Emphasized = HIG 的 emphasized 变体（升一档）。SF 的 tracking 只在 Apple
/// 平台的拉丁 UI 上加（[buildTextTheme]），CJK 一律 0（[MyComicTypeSpec.applyTo]）。
abstract final class MyComicAppleTypeScale {
  static const MyComicTypeSpec displayLarge =
      MyComicTypeSpec(48, FontWeight.w400, 1.1, 0.35, FontWeight.w700);
  static const MyComicTypeSpec displayMedium =
      MyComicTypeSpec(40, FontWeight.w400, 1.12, 0.37, FontWeight.w700);
  static const MyComicTypeSpec displaySmall =
      MyComicTypeSpec(34, FontWeight.w700, 41 / 34, 0.4, FontWeight.w800);
  static const MyComicTypeSpec headlineLarge =
      MyComicTypeSpec(28, FontWeight.w700, 34 / 28, 0.38, FontWeight.w800);
  static const MyComicTypeSpec headlineMedium =
      MyComicTypeSpec(22, FontWeight.w700, 28 / 22, -0.26, FontWeight.w800);
  static const MyComicTypeSpec headlineSmall =
      MyComicTypeSpec(20, FontWeight.w700, 25 / 20, -0.45, FontWeight.w800);
  static const MyComicTypeSpec titleLarge =
      MyComicTypeSpec(17, FontWeight.w600, 22 / 17, -0.43, FontWeight.w700);
  static const MyComicTypeSpec titleMedium =
      MyComicTypeSpec(16, FontWeight.w600, 21 / 16, -0.31, FontWeight.w700);
  static const MyComicTypeSpec titleSmall =
      MyComicTypeSpec(15, FontWeight.w600, 20 / 15, -0.23, FontWeight.w700);
  static const MyComicTypeSpec bodyLarge =
      MyComicTypeSpec(17, FontWeight.w400, 22 / 17, -0.43, FontWeight.w600);
  static const MyComicTypeSpec bodyMedium =
      MyComicTypeSpec(15, FontWeight.w400, 20 / 15, -0.23, FontWeight.w600);
  static const MyComicTypeSpec bodySmall =
      MyComicTypeSpec(13, FontWeight.w400, 18 / 13, -0.08, FontWeight.w600);
  static const MyComicTypeSpec labelLarge =
      MyComicTypeSpec(15, FontWeight.w500, 20 / 15, -0.23, FontWeight.w600);
  static const MyComicTypeSpec labelMedium =
      MyComicTypeSpec(12, FontWeight.w500, 16 / 12, 0, FontWeight.w600);
  static const MyComicTypeSpec labelSmall =
      MyComicTypeSpec(11, FontWeight.w500, 13 / 11, 0.06, FontWeight.w600);

  static const List<MyComicTypeSpec> roles = <MyComicTypeSpec>[
    displayLarge,
    displayMedium,
    displaySmall,
    headlineLarge,
    headlineMedium,
    headlineSmall,
    titleLarge,
    titleMedium,
    titleSmall,
    bodyLarge,
    bodyMedium,
    bodySmall,
    labelLarge,
    labelMedium,
    labelSmall,
  ];

  /// 当前平台实际生效的 15 个角色：SF 的 tracking 只对 SF 本身成立，非 Apple
  /// 平台（Apple 设计系统也能在 Windows / Android 上选）的系统字体没有按这套
  /// tracking 调过，去掉。
  static List<MyComicTypeSpec> get platformRoles {
    final bool applePlatform = defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
    if (applePlatform) return roles;
    return <MyComicTypeSpec>[
      for (final MyComicTypeSpec r in roles)
        MyComicTypeSpec(r.size, r.weight, r.height, 0, r.emphasizedWeight),
    ];
  }

  static TextTheme buildTextTheme(TextStyle base) =>
      myComicTextThemeFromRoles(platformRoles, base);
}

/// 把 15 个角色（[MyComicTypeScale.roles] 顺序）应用到 [base] 上组成 [TextTheme]。
TextTheme myComicTextThemeFromRoles(List<MyComicTypeSpec> r, TextStyle base) =>
    TextTheme(
      displayLarge: r[0].applyTo(base),
      displayMedium: r[1].applyTo(base),
      displaySmall: r[2].applyTo(base),
      headlineLarge: r[3].applyTo(base),
      headlineMedium: r[4].applyTo(base),
      headlineSmall: r[5].applyTo(base),
      titleLarge: r[6].applyTo(base),
      titleMedium: r[7].applyTo(base),
      titleSmall: r[8].applyTo(base),
      bodyLarge: r[9].applyTo(base),
      bodyMedium: r[10].applyTo(base),
      bodySmall: r[11].applyTo(base),
      labelLarge: r[12].applyTo(base),
      labelMedium: r[13].applyTo(base),
      labelSmall: r[14].applyTo(base),
    );
