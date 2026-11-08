import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1108 源码扫描守卫：书架顶部「继续阅读」hero 条（旧大卡 / 主 chrome 行的
/// 继续阅读胶囊）的书名必须经 [MediaSource.getDisplayTitleFromMediaItem] 应用
/// 编辑弹窗写入的 override 书名，不得直读 DB 原始列 `hero.title` 上屏。
///
/// 同卡封面早已走 override（getDisplayThumbnailFromMediaItem），BUG-1018 修
/// dashboard 改名不同步时因**无面级守卫**漏掉了本面——网格卡的同类守卫在
/// `shelf_srt_card_override_title_guard_test.dart`，这里按同一范式补上 hero 条。
void main() {
  String source() =>
      File('lib/src/pages/implementations/reader_fushi_history_page.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');

  String hero() => _functionSource(
        source(),
        '  Widget _buildContinueReadingHero(',
        '\n  Widget ',
      );

  String pill() => _functionSource(
        source(),
        '  Widget _buildContinueReadingPill(',
        '\n  Widget ',
      );

  test('hero 书名经 getDisplayTitleFromMediaItem 应用 override', () {
    expect(
      hero(),
      contains('mediaSource.getDisplayTitleFromMediaItem(hero)'),
      reason: 'hero 条书名必须与同卡封面同源，应用编辑弹窗写入的 override 书名',
    );
  });

  test('hero 书名不得直读 DB 原始列 hero.title 上屏', () {
    // 以表达式形态（带逗号结尾）匹配，避免误伤注释里的提及。
    expect(
      hero(),
      isNot(contains('hero.title,')),
      reason: '直读 hero.title 会在改名后仍显示旧名（BUG-1108）',
    );
  });

  test('顶部继续阅读胶囊的 tooltip 书名同样经 getDisplayTitleFromMediaItem', () {
    expect(
      pill(),
      contains('mediaSource.getDisplayTitleFromMediaItem(hero)'),
      reason: '胶囊 tooltip 的 hover 书名必须应用编辑弹窗写入的 override 书名',
    );
  });

  test('顶部继续阅读胶囊的 tooltip 不得直读 DB 原始列 hero.title', () {
    expect(
      pill(),
      isNot(contains('hero.title,')),
      reason: '直读 hero.title 会在改名后仍显示旧名（BUG-1108）',
    );
  });
}

/// 从 [start] 方法签名切到下一个同缩进方法声明（与
/// `reader_paginate_lyrics_guard_static_test.dart` 同范式）。
String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
