# 15: Cupertino 设计系统下图标变成口口

**What to build:** 修复在设置页把“设计系统”切到 Cupertino 后，导航、设置分类、主题色块等位置的所有图标都渲染成豆腐块（口口）的问题。

**Blocked by:** None（post-review regression）

**Status:** resolved

## Root cause

`cupertino_ui` 的 `CupertinoIcons` 是 `IconData(fontFamily: 'CupertinoIcons', fontPackage: 'cupertino_icons')`，但应用只依赖 `cupertino_ui`，没有依赖提供字体资源的 `cupertino_icons`。Material 设计系统下用的是自定义 `MyComicSymbols` 字族，所以正常；切到 Cupertino 后 `MyComicIcon` 会把语义图标映射到 `CupertinoIcons`，而 `CupertinoIcons.ttf` 没有进 asset bundle，所有字形都变成 tofu。

## Fix

- `my_comic/pubspec.yaml` 增加 `cupertino_icons: ^1.0.8`，让字体 TTF 随包分发。
- 不改图标映射、不改 UI；Cupertino 设计系统继续使用 SF 风格图标。

## Verification

- `flutter test --no-pub test/widgets/glass/my_comic_icon_test.dart`：7/7 通过（映射值与 `fontPackage='cupertino_icons'` 不变）。
- `flutter analyze --no-pub`：0 errors。
- 重新构建后检查 asset bundle 中存在 `CupertinoIcons.ttf`；切到 Cupertino 设计系统后图标正常显示。
