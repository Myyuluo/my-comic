import 'package:material_ui/material_ui.dart';

/// Text and a range for a highlighted selection.
///
/// 原住在 `fushi_dictionary`（查词域）。漫画阅读器 / MediaSource 的「当前句」状态
/// 仍以它为值对象；独立化时抽到 app 模型层，字段与语义保持不变。
class FushiTextSelection {
  /// Initialise an instance of this entity.
  FushiTextSelection({required this.text, this.range = TextRange.empty});

  /// Text that has a length valid within range.
  final String text;

  /// Highlighted text range.
  final TextRange range;

  /// Text before the highlighted text.
  String get textBefore {
    if (range == TextRange.empty) {
      return '';
    }
    return range.textBefore(text);
  }

  /// Text after the highlighted text.
  String get textAfter {
    if (range == TextRange.empty) {
      return '';
    }
    return range.textAfter(text);
  }

  /// Highlighted text.
  String get textInside {
    if (range == TextRange.empty) {
      return '';
    }
    return range.textInside(text);
  }

  @override
  String toString() {
    return '''
FushiTextSelection(
  text: $text
  range: $range
  before: $textBefore
  inside: $textInside
  after: $textAfter
)
''';
  }
}
