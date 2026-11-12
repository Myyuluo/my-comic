import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/main.dart';

void main() {
  group('myComicSystemOverlayStyle', () {
    test('dark brightness yields light (bright) system bar icons', () {
      final style = myComicSystemOverlayStyle(Brightness.dark);
      // Light icons are required for legibility over a dark app surface.
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      expect(style.statusBarIconBrightness, Brightness.light);
    });

    test('light brightness yields dark system bar icons', () {
      final style = myComicSystemOverlayStyle(Brightness.light);
      // Dark icons are required for legibility over a light app surface.
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarIconBrightness, Brightness.dark);
    });

    test('bars stay transparent and uncontrasted for edge-to-edge', () {
      for (final brightness in Brightness.values) {
        final style = myComicSystemOverlayStyle(brightness);
        expect(style.statusBarColor, Colors.transparent);
        expect(style.systemNavigationBarColor, Colors.transparent);
        expect(style.systemNavigationBarContrastEnforced, false);
      }
    });
  });
}
