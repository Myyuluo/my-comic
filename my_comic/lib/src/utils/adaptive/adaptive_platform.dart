import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'package:my_comic/src/utils/system_transparency.dart';

enum MyComicDesignSystem { auto, material, cupertino }

@immutable
class MyComicDesignSystemTheme extends ThemeExtension<MyComicDesignSystemTheme> {
  const MyComicDesignSystemTheme(this.designSystem);

  final MyComicDesignSystem designSystem;

  @override
  MyComicDesignSystemTheme copyWith({MyComicDesignSystem? designSystem}) {
    return MyComicDesignSystemTheme(designSystem ?? this.designSystem);
  }

  @override
  MyComicDesignSystemTheme lerp(
    covariant ThemeExtension<MyComicDesignSystemTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// 墨水屏模式标志的 ThemeExtension 载体。挂在 ThemeNotifier._buildThemeData 的
/// extensions 里，使任意 widget 可经 `Theme.of(context)` 感知 eink（用于把入场
/// 淡入/滑出等 Flutter 侧动画时长归零），零新增数据流、随主题重建自动更新。
@immutable
class MyComicEinkTheme extends ThemeExtension<MyComicEinkTheme> {
  const MyComicEinkTheme(this.einkMode);

  final bool einkMode;

  @override
  MyComicEinkTheme copyWith({bool? einkMode}) {
    return MyComicEinkTheme(einkMode ?? this.einkMode);
  }

  @override
  MyComicEinkTheme lerp(
    covariant ThemeExtension<MyComicEinkTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// True 当墨水屏模式开启（读不到扩展时为 false，测试裸 ThemeData 零破坏）。
bool isEinkTheme(BuildContext context) {
  return Theme.of(context).extension<MyComicEinkTheme>()?.einkMode ?? false;
}

/// 功能层表面（导航 / 底部弹层 / 对话框）的材质。与颜色主题正交：颜色仍由
/// ColorScheme 决定，这里只决定表面是实心还是半透明 + 背景模糊。
enum MyComicGlassMaterial {
  /// 实心表面（默认）。
  off,

  /// 毛玻璃：半透明填充 + BackdropFilter 模糊。
  frosted,

  /// 液态玻璃：折射 / 色散 / 高光着色器（`liquid_glass_widgets`）。只在引擎
  /// 支持着色器 ImageFilter（Impeller）时生效，否则 [glassMaterialOf] 降级为
  /// [frosted]。
  liquid;

  /// 偏好值（`glass_material`）→ 枚举；未知值回落 [off]。
  static MyComicGlassMaterial fromPrefValue(String? value) {
    for (final MyComicGlassMaterial m in MyComicGlassMaterial.values) {
      if (m.name == value) return m;
    }
    return MyComicGlassMaterial.off;
  }
}

/// 玻璃材质的 ThemeExtension 载体，与 [MyComicEinkTheme] 同一写法：挂在
/// `buildMyComicThemeData` 的 extensions 里，随主题重建自动更新。
@immutable
class MyComicGlassTheme extends ThemeExtension<MyComicGlassTheme> {
  const MyComicGlassTheme(this.material, {this.glassDesign = false});

  /// 表面材质（off / frosted / liquid），已扣除系统降低透明度。
  final MyComicGlassMaterial material;

  /// 是否「玻璃」设计系统：为 true 时共享组件与控件包装渲染
  /// `liquid_glass_widgets` 组件族（与 MD3 并列的另一套组件），即使
  /// [material] 因降低透明度 / 高对比度回退为 off，组件族也不变——只是
  /// 玻璃变成实心。见 [isGlassDesign]。
  final bool glassDesign;

  @override
  MyComicGlassTheme copyWith({MyComicGlassMaterial? material, bool? glassDesign}) {
    return MyComicGlassTheme(
      material ?? this.material,
      glassDesign: glassDesign ?? this.glassDesign,
    );
  }

  @override
  MyComicGlassTheme lerp(
    covariant ThemeExtension<MyComicGlassTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// 引擎是否支持着色器 ImageFilter（液态玻璃的前提）。测试可覆盖。
@visibleForTesting
bool Function() debugShaderFilterSupported = () =>
    ImageFilter.isShaderFilterSupported;

/// 当前上下文实际生效的玻璃材质。墨水屏（半透明 = 灰阶抖动 + 残影）与系统
/// 「增强对比度」（[MediaQueryData.highContrast]）下一律回退 [MyComicGlassMaterial.off]；
/// 读不到扩展（测试裸 ThemeData、查词弹窗主题）同样是 off。[MyComicGlassMaterial.liquid]
/// 在不支持着色器 ImageFilter 的引擎（Skia 后端）上降级为 frosted。
MyComicGlassMaterial glassMaterialOf(BuildContext context) {
  final MyComicGlassMaterial material =
      Theme.of(context).extension<MyComicGlassTheme>()?.material ??
      MyComicGlassMaterial.off;
  if (material == MyComicGlassMaterial.off) return material;
  if (isEinkTheme(context)) return MyComicGlassMaterial.off;
  if (MediaQuery.maybeHighContrastOf(context) ?? false) {
    return MyComicGlassMaterial.off;
  }
  if (material == MyComicGlassMaterial.liquid && !debugShaderFilterSupported()) {
    return MyComicGlassMaterial.frosted;
  }
  return material;
}

/// 窗口级系统材质（Windows 11 Mica）是否请求开启。
///
/// 与 [glassMaterialOf]（组件悬浮面画不画玻璃）**解耦**：所有者 2026-10-13
/// 拍板 Apple（Cupertino）设计系统组件悬浮面实色，但窗口级材质保留——所以这里
/// 不看材质档（[MyComicGlassTheme.material] 已钉成 off），只看三件事：设计系统
/// （[glassDesign]，墨水屏下 [isGlassDesign] 恒 false）、系统「降低透明度」
/// （[reduceTransparency]）与「增强对比度」（[highContrast]）。平台支不支持由
/// 原生侧判，结果回写 `WindowCaptionChannel.systemBackdropActive`。
bool myComicWindowBackdropRequested({
  required bool glassDesign,
  required bool reduceTransparency,
  required bool highContrast,
}) {
  return glassDesign && !reduceTransparency && !highContrast;
}

/// [myComicWindowBackdropRequested] 的 BuildContext 版：系统「降低透明度」读
/// [SystemTransparency] 镜像（它变化时 ThemeNotifier 通知、根 build 重跑）。
bool windowBackdropRequestedOf(BuildContext context) {
  return myComicWindowBackdropRequested(
    glassDesign: isGlassDesign(context),
    reduceTransparency: SystemTransparency.reduceTransparency.value,
    highContrast: MediaQuery.maybeHighContrastOf(context) ?? false,
  );
}

/// 当前上下文是否走「玻璃」设计系统的组件族（`liquid_glass_widgets`）。
/// 与 [glassMaterialOf] 正交：后者决定表面透不透明，这里决定渲染 MD3 还是
/// 玻璃组件。墨水屏下恒 false（墨水屏的可读性调校全建在 MD3 组件上）；
/// 读不到扩展（测试裸 ThemeData、查词弹窗主题）同样 false。
bool isGlassDesign(BuildContext context) =>
    isGlassDesignTheme(Theme.of(context));

/// [isGlassDesign] 的 ThemeData 版：手里只有主题、没有 BuildContext 的装配点（例如
/// 生成 WebView 注入样式）用它，与 [isGlassDesign] 同一判据。
bool isGlassDesignTheme(ThemeData theme) {
  if (theme.extension<MyComicEinkTheme>()?.einkMode ?? false) return false;
  return theme.extension<MyComicGlassTheme>()?.glassDesign ?? false;
}

/// eink 下把动画时长归零（墨水屏连续重绘=残影），否则原样返回。
/// 共享组件与页面级 Animated* 统一走这里，别再手写三元。
Duration einkSafeDuration(BuildContext context, Duration duration) {
  return isEinkTheme(context) ? Duration.zero : duration;
}

/// eink 下把不定态进度（`value == null`）钉成 0：不定态是一条永不停歇的往复
/// 动画，墨水屏上等于整条进度带持续局部刷新（残影 + 闪烁）；旁边的文案已经在
/// 说「正在下载 / 同步中」，静止的空轨道足够表达。非 eink 原样返回。
double? einkSafeProgressValue(BuildContext context, double? value) {
  return isEinkTheme(context) ? (value ?? 0) : value;
}

bool isCupertinoPlatform(BuildContext context) {
  final MyComicDesignSystem designSystem =
      Theme.of(context).extension<MyComicDesignSystemTheme>()?.designSystem ??
      MyComicDesignSystem.auto;
  switch (designSystem) {
    case MyComicDesignSystem.material:
      return false;
    case MyComicDesignSystem.cupertino:
      return true;
    case MyComicDesignSystem.auto:
      return false;
  }
}

/// SDK 的 `X.adaptive` 系列（`Switch.adaptive` / `Slider.adaptive` /
/// `Checkbox.adaptive` / `AlertDialog.adaptive` / `CircularProgressIndicator.adaptive`
/// …）按 [ThemeData.platform] 选外观。本仓 `auto` 下统一 MD3（M3E），所以
/// MyComic 包装层的 `.adaptive` 构造器只在设计系统是隐藏的
/// `MyComicDesignSystem.cupertino` 时才交给 SDK 的平台分派，其余一律渲染
/// Material 控件（BUG-3309）。判据只写这一处，包装层不再各自读平台。
///
/// 注意：用户可见的「Cupertino」（玻璃设计）不是这里说的 Cupertino——它走
/// [isGlassDesign] 分支，包装层在进到本判据之前就已分流，不受此判据影响。
bool useCupertinoAdaptiveControls(BuildContext context) =>
    isCupertinoPlatform(context);
