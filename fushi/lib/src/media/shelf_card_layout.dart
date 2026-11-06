/// 书架卡片网格的共享尺寸推导（原 `collection_shelf_row.dart` 中的通用 helper）。
///
/// 以 [targetWidth] 为基准算响应式列数（floor→卡只会比目标更宽不会更窄），
/// 返回列数 + 实际卡宽：网格 `FixedCrossAxisCount` 的 cell 宽与横排 `SizedBox`
/// 宽取同一值。
({int columns, double cardWidth}) unifiedShelfCardLayout({
  required double availableWidth,
  required double targetWidth,
  double spacing = 12,
}) {
  if (availableWidth <= 0 || targetWidth <= 0) {
    return (columns: 1, cardWidth: targetWidth > 0 ? targetWidth : 1);
  }
  final int columns = ((availableWidth + spacing) / (targetWidth + spacing))
      .floor()
      .clamp(1, 1 << 10);
  final double cardWidth = (availableWidth - (columns - 1) * spacing) / columns;
  return (columns: columns, cardWidth: cardWidth);
}
