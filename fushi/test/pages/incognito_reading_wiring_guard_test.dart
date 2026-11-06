import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ticket 04 的接线守卫：EPUB / PDF 阅读器的位置落库只在真实 WebView 进度回调里
/// 发生，widget harness 无法驱动（漫画阅读器另有 `manga_incognito_reading_test`
/// 的真页面证据）。这里锁住三件事，防止以后重构时静默丢掉无痕语义：
///
/// 1. 每条自动落库路径都在**落库时**现读 `appModel.incognitoReading`；
/// 2. `ReaderPositionRepository.save` 传入 `advanceUpdatedAt: !incognito`
///    （冻结 `reader_positions.updatedAt` 这个 History 的 recency 信号）；
/// 3. 自动书级完成 / 自动章节已读在无痕时被跳过（显式用户「标记已读」不经过
///    这些自动路径，照常生效）。
void main() {
  String read(String path) {
    final File file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'run from the fushi/ package root',
    );
    return file.readAsStringSync();
  }

  test('EPUB 阅读器：落库现读无痕开关，冻结时间戳并跳过自动完成标记', () {
    final String src = read(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    );
    expect(src, contains('appModel.incognitoReading'));
    expect(
      src,
      contains('advanceUpdatedAt: !incognito'),
      reason: 'reader_positions.updatedAt 必须按无痕开关冻结',
    );
    expect(
      src,
      contains('completed && !incognito'),
      reason: '无痕期间不得自动写 EpubBooks.completedAt',
    );
  });

  test('PDF 阅读器：落库现读无痕开关，冻结时间戳并跳过自动完成标记', () {
    final String src = read(
      'lib/src/pages/implementations/reader_pdf_page.dart',
    );
    expect(src, contains('appModel.incognitoReading'));
    expect(src, contains('advanceUpdatedAt: !incognito'));
    expect(src, contains('!incognito && pageCount > 0'));
  });

  test('漫画阅读器：冻结时间戳、不自动写 readAt，章尾自动已读被跳过', () {
    final String src = read('lib/src/media/manga/reader/manga_fushi_page.dart');
    expect(src, contains('appModel.incognitoReading'));
    expect(src, contains('advanceUpdatedAt: !incognito'));
    expect(
      src,
      contains('atLastPage && !incognito'),
      reason: '无痕期间不得自动写书级完成标记',
    );
    expect(
      src,
      contains('readAt: atLastPage && !incognito'),
      reason: '无痕期间不得自动写章节已读',
    );
    expect(
      src,
      contains('if (appModel.incognitoReading) return;'),
      reason: '章尾自动标记已读必须被无痕开关跳过',
    );
  });
}
