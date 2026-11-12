import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-049 wiring guard (source scan, sibling of reader_live_settings_guard).
///
/// The three font targets are independent ONLY if each renderer reads its own
/// source list. A future refactor that re-points one of them back at the shared
/// `customFonts`/body list would silently re-couple them (no compile error,
/// hard to catch at runtime across 5 platforms). These static assertions pin the
/// data source of each renderer so any such regression turns this test red.
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('app-wide UI font is resolved from the appUiFonts target', () {
    final String src = read('lib/src/models/app_model.dart');
    // Both the live refresh and the init path must feed appUiFonts to the loader
    // => two AppFontLoader call sites (video subtitle target removed with the
    // non-manga domains).
    expect(
      'AppFontLoader.resolveAndLoad'.allMatches(src).length,
      greaterThanOrEqualTo(2),
      reason: 'expected the two AppFontLoader call sites (refresh + init)',
    );
    // The appUi target consumes the WHOLE ordered list (fallback chain), so it
    // must go through resolveAndLoadAll — resolveAndLoad drops every entry after
    // the first, which silently kills the user's own fallback order.
    // 去空白 + 去尾逗号再比：dart format 会把长调用拆成多行带尾逗号。
    final String flat = src
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(',)', ')');
    expect(flat.contains('resolveAndLoadAll(settings.appUiFonts)'), isTrue);
    expect(
      flat.contains('resolveAndLoadAll(readerSettings.appUiFonts)'),
      isTrue,
    );
    // It must NOT be fed the body list any more.
    expect(src.contains('resolveAndLoad(settings.customFonts)'), isFalse);
    expect(src.contains('resolveAndLoad(readerSettings.customFonts)'), isFalse);
  });

  test('reader body CSS still uses the legacy body customFonts list', () {
    final String src = read('lib/src/reader/reader_content_styles.dart');
    expect(src.contains('settings.buildCustomFontCss()'), isTrue);
    final String settings = read('lib/src/reader/reader_settings.dart');
    // buildCustomFontCss must stay bound to the BODY target (legacy key).
    expect(
      settings.contains(
          'buildCustomFontCss() =>\n      customFontCssForEntries(customFonts)'),
      isTrue,
    );
  });

  test('settings exposes one font catalog entry with five row targets', () {
    final String schema =
        read('lib/src/settings/settings_schema_appearance.dart');
    expect(schema.contains("'appearance.font_catalog'"), isTrue);
    expect(schema.contains('t.custom_fonts_catalog_title'), isTrue);
    expect(schema.contains("'appearance.fonts_app_ui'"), isFalse);
    expect(schema.contains("'appearance.fonts_body'"), isFalse);
    expect(schema.contains("'appearance.fonts_dictionary'"), isFalse);

    final String page =
        read('lib/src/pages/implementations/custom_fonts_page.dart');
    expect(page.contains('for (final FontTarget target in FontTarget.values)'),
        isTrue);
    expect(page.contains('customFontCatalogRowsFromState'), isTrue);
    expect(page.contains('customFontCatalogStateFromRows'), isTrue);
    expect(page.contains('ReaderSettings.fontCatalogKey'), isTrue);
    expect(page.contains('ReaderSettings.fontTargetsKey'), isTrue);
    expect(page.contains('customFontLegacyListsFromRows'), isTrue);
  });

  test('font catalog init reads DB without watching ProviderScope', () {
    final String page =
        read('lib/src/pages/implementations/custom_fonts_page.dart');
    final int start = page.indexOf('Future<void> _initializeFonts()');
    // 读/写目录状态已提升为顶层 readCustomFontCatalogState /
    // persistCustomFontState（与扩展字体端点共用）；页面里的初始化区间到 _save()
    // 为止，其间仍不得碰 ref.watch 驱动的 appModel。
    final int end = page.indexOf('Future<void> _save()');
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String initAndRead = page.substring(start, end);
    expect(initAndRead.contains('appModelNoUpdate.database'), isTrue);
    expect(initAndRead.contains('appModel.database'), isFalse,
        reason: 'BasePageState.appModel uses ref.watch and is illegal during '
            'initState; initialization must use the cache populated by '
            'super.initState().');
  });

  test('the legacy body key is never renamed (backward-compat ironclad)', () {
    final String src = read('lib/src/reader/reader_settings.dart');
    expect(src.contains("fontKeyBody = 'custom_fonts'"), isTrue);
    expect(src.contains("fontKeyAppUi = 'app_ui_fonts'"), isTrue);
    expect(src.contains("fontKeyDictionary = 'dict_fonts'"), isTrue);
    // TODO-864: video subtitle font key is equally ironclad (backward-compat).
    expect(src.contains("fontKeyVideoSubtitle = 'video_sub_fonts'"), isTrue);
    expect(src.contains("fontKeyGameLookup = 'game_lookup_fonts'"), isTrue);
    expect(
      src.contains("fontKeyFloatingLyric = 'floating_lyric_fonts'"),
      isTrue,
    );
  });

}
