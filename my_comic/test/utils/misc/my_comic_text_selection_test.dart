import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/models/my_comic_text_selection.dart';

void main() {
  group('MyComicTextSelection', () {
    test('splits text into before, inside, after for mid-word selection', () {
      final sel = MyComicTextSelection(
        text: '吾輩は猫である',
        range: const TextRange(start: 3, end: 4),
      );

      expect(sel.textBefore, '吾輩は');
      expect(sel.textInside, '猫');
      expect(sel.textAfter, 'である');
    });

    test('selection at start yields empty textBefore', () {
      final sel = MyComicTextSelection(
        text: 'Hello World',
        range: const TextRange(start: 0, end: 5),
      );

      expect(sel.textBefore, isEmpty);
      expect(sel.textInside, 'Hello');
      expect(sel.textAfter, ' World');
    });

    test('selection at end yields empty textAfter', () {
      final sel = MyComicTextSelection(
        text: 'Hello World',
        range: const TextRange(start: 6, end: 11),
      );

      expect(sel.textBefore, 'Hello ');
      expect(sel.textInside, 'World');
      expect(sel.textAfter, isEmpty);
    });

    test('full text selection', () {
      final sel = MyComicTextSelection(
        text: 'abc',
        range: const TextRange(start: 0, end: 3),
      );

      expect(sel.textBefore, isEmpty);
      expect(sel.textInside, 'abc');
      expect(sel.textAfter, isEmpty);
    });

    test('empty range returns empty strings for all parts', () {
      final sel = MyComicTextSelection(
        text: 'some text',
        range: TextRange.empty,
      );

      expect(sel.textBefore, isEmpty);
      expect(sel.textInside, isEmpty);
      expect(sel.textAfter, isEmpty);
    });

    test('default range is TextRange.empty', () {
      final sel = MyComicTextSelection(text: 'test');

      expect(sel.textBefore, isEmpty);
      expect(sel.textInside, isEmpty);
      expect(sel.textAfter, isEmpty);
    });

    test('toString contains all parts', () {
      final sel = MyComicTextSelection(
        text: 'abc',
        range: const TextRange(start: 1, end: 2),
      );

      final str = sel.toString();
      expect(str, contains('MyComicTextSelection'));
      expect(str, contains('abc'));
    });
  });
}
