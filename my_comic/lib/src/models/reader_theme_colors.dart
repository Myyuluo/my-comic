import 'package:material_ui/material_ui.dart';

import 'package:my_comic/src/models/my_comic_reader_palette.dart';
import 'package:my_comic/src/models/theme_notifier.dart' show ThemeNotifier;

/// 阅读器主题用的五个颜色角色：正文背景、正文字色、跟读高亮、查词选区、链接。
///
/// 从已删除的 EPUB 阅读器页抽出；自定义主题编辑页的「阅读器」预览仍共用这一条
/// 解析链，保证编辑页看到的正文色与（未来的）漫画阅读器配色语义一致。
typedef ReaderThemeColors = ({
  Color bg,
  Color fg,
  Color sentenceAudioHighlight,
  Color selection,
  Color link,
  bool dark,
});

/// 自定义主题在阅读器角色上的可选覆盖：null = 跟随主题。
typedef ReaderThemeOverrides = ({
  Color? bg,
  Color? fg,
  Color? selection,
  Color? link,
});

ReaderThemeColors? readerPresetFor({
  required String themeKey,
  required Map<String, ReaderThemeColors> presetMap,
  required ColorScheme scheme,
}) {
  final ReaderThemeColors? preset = presetMap[themeKey];
  if (preset == null) return null;
  if (preset.dark != (scheme.brightness == Brightness.dark)) return null;
  return preset;
}

ReaderThemeColors readerThemeColorsFromPalette(MyComicReaderPalette palette) {
  return (
    bg: palette.background,
    fg: palette.text,
    sentenceAudioHighlight: palette.sentenceHighlight,
    selection: palette.lookupHighlight,
    link: palette.link,
    dark: palette.dark,
  );
}

ReaderThemeColors applyReaderThemeOverrides(
  ReaderThemeColors base,
  ReaderThemeOverrides overrides,
) {
  final Color bg = overrides.bg ?? base.bg;
  final bool dark = overrides.bg == null
      ? base.dark
      : ThemeData.estimateBrightnessForColor(bg) == Brightness.dark;
  final Color fg =
      overrides.fg ??
      (overrides.bg == null
          ? base.fg
          : (dark ? const Color(0xDEFFFFFF) : const Color(0xDE000000)));
  return (
    bg: bg,
    fg: fg,
    sentenceAudioHighlight: base.sentenceAudioHighlight,
    selection: overrides.selection ?? base.selection,
    link: overrides.link ?? base.link,
    dark: dark,
  );
}

ReaderThemeColors _resolveBaseReaderThemeColors({
  required String themeKey,
  required Map<String, ReaderThemeColors> presetMap,
  required ColorScheme scheme,
  ReaderThemeOverrides? customOverrides,
}) {
  final ReaderThemeColors? preset = readerPresetFor(
    themeKey: themeKey,
    presetMap: presetMap,
    scheme: scheme,
  );
  if (preset != null) return preset;
  final MyComicReaderPalette palette =
      myComicReaderPaletteFor(scheme, scheme.brightness);
  final ReaderThemeColors fromScheme = readerThemeColorsFromPalette(palette);
  if (customOverrides == null || !ThemeNotifier.isCustomThemeKey(themeKey)) {
    return fromScheme;
  }
  return applyReaderThemeOverrides(fromScheme, customOverrides);
}

ReaderThemeColors resolveReaderThemeColors({
  required String themeKey,
  required Map<String, ReaderThemeColors> presetMap,
  required ColorScheme scheme,
  ReaderThemeOverrides? customOverrides,
  Color? audioHighlightOverride,
}) {
  final ReaderThemeColors base = _resolveBaseReaderThemeColors(
    themeKey: themeKey,
    presetMap: presetMap,
    scheme: scheme,
    customOverrides: customOverrides,
  );
  if (audioHighlightOverride == null) return base;
  return (
    bg: base.bg,
    fg: base.fg,
    sentenceAudioHighlight: audioHighlightOverride,
    selection: base.selection,
    link: base.link,
    dark: base.dark,
  );
}
