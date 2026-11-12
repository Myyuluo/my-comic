import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/src/media/manga/reader/manga_my_comic_page.dart',
  ).readAsStringSync();

  test('restore and live reset share the mode precedence resolver', () {
    expect('MangaMyComicPage.resolveReaderMode('.allMatches(source).length, 2);
    final int start = source.indexOf(
      'Future<void> _reapplyReaderPreferences()',
    );
    final int end = source.indexOf('Future<void> _showPageJumpDialog()', start);
    final String body = source.substring(start, end);
    expect(body, contains('hasModeOverride: hasModeOverride'));
    expect(body, contains('legacyMode: row.mangaReadingMode'));
    expect(body, isNot(contains(': _mode;')));
  });

  test(
    'serialized step consumes the half page before panel or spread changes',
    () {
      final int start = source.indexOf(
        'Future<void> _applyMangaTurnStep(int delta)',
      );
      final int end = source.indexOf('// ── 换章', start);
      final String body = source.substring(start, end);
      final int probe = body.indexOf('window.__mangaTurnWithinPage(');
      final int consumed = body.indexOf(
        'if (MangaWindowGeneration.parse(consumed) == 1) return;',
      );
      final int advance = body.indexOf('_currentSpread = target;');
      expect(probe, greaterThanOrEqualTo(0));
      expect(consumed, greaterThan(probe));
      // AI 分镜导航已随死亡的分镜检测一起删除：半页消费后直接落到 spread 推进。
      expect(advance, greaterThan(consumed));
      expect(body, contains('!identical(session, _pageSession)'));
      expect(body, contains('!identical(controller, _controller)'));
    },
  );
}
