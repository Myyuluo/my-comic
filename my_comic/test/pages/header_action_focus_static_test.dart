import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';
import '../helpers/source_guard.dart';

void main() {
  test('custom theme import and share use shared focusable hero buttons', () {
    final String source = File(
      'lib/src/pages/implementations/custom_theme_page.dart',
    ).readAsStringSync();
    // 4f886a5e37a moves import/share from header icon actions to the hero.
    final String hero = methodBody(source, 'Widget _buildHeaderCard(');
    for (final String action in <String>['_importTheme', '_shareTheme']) {
      final EnclosingCall button = enclosingCallOf(hero, 'onPressed: $action');
      expect(button.name, 'MyComicFilledButton.tonalIcon');
    }
    expect(containsIdentifierCall(hero, 'IconButton'), isFalse);
  });

  test('shortcut action rows use MyComicIconButton for edit command', () {
    // _ActionTile lives in the action_tile part of shortcut_settings_page.dart
    // (shortcut settings refactor); the part file only contains the tile + the
    // mouse chip, so the whole file is the tile section.
    final String actionTile = File(
      'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart',
    ).readAsStringSync();

    expect(actionTile, contains('MyComicIconButton('));
    expect(actionTile, isNot(contains('trailing: IconButton(')));
  });

  test('reader history batch toolbar uses MyComicIconButton actions', () {
    final String source = readReaderHistorySource();
    final int barStart = source.indexOf('Widget _buildBatchActionBar()');
    final int deleteStart = source.indexOf(
      'Future<void> _batchDeleteConfirm()',
    );
    final String selectionBar = source.substring(barStart, deleteStart);

    expect(selectionBar, contains('MyComicIconButton('));
    expect(selectionBar, isNot(contains('\n              IconButton(')));
  });

}
