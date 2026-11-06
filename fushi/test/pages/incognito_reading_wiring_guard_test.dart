import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ticket 04 的**最小**接线守卫：EPUB / PDF 阅读器的位置落库只在真实 WebView /
/// PDF 渲染回调里发生，widget harness 无法驱动。
///
/// 语义本身已有可测的行为证据：漫画阅读器由 `manga_incognito_reading_test` 挂真
/// 页面验证；`ReaderHistoryPolicy`（advanceUpdatedAt / 自动 readAt / 书级完成 /
/// 哨兵判定）由 `reader_position_repository_test` 覆盖。这里只钉住这两条不可测
/// 路径没有在重构时静默丢掉策略接线：
/// 1. 落库时从 `AppModel.readerHistoryPolicy` 现取策略（而不是各自重读偏好）；
/// 2. 策略原样交给 `ReaderPositionRepository.save`；
/// 3. 自动书级完成标记受 `autoMarkBookCompleted` 控制。
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

  test('EPUB 阅读器：落库现取策略，交给仓储并跳过无痕下的自动完成标记', () {
    final String src = read(
      'lib/src/pages/implementations/reader_fushi/navigation.part.dart',
    );
    expect(src, contains('appModel.readerHistoryPolicy'));
    expect(src, contains('history: history'));
    expect(
      src,
      contains('history.autoMarkBookCompleted'),
      reason: '无痕期间不得自动写 EpubBooks.completedAt',
    );
  });

  test('PDF 阅读器：落库现取策略，交给仓储并跳过无痕下的自动完成标记', () {
    final String src = read(
      'lib/src/pages/implementations/reader_pdf_page.dart',
    );
    expect(src, contains('appModel.readerHistoryPolicy'));
    expect(src, contains('history: history'));
    expect(src, contains('history.autoMarkBookCompleted'));
  });
}
