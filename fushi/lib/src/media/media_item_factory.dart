import 'package:fushi_core/fushi_core.dart' show BookFormat;
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

/// 用「跳回原文」所需的最小信息重建一条 [MediaItem]。
///
/// [format] 必须是**当前** `EpubBooks.format`（调用方现查），不能省略也不能默认成
/// EPUB：`mediaSourceIdentifier` 决定打开哪个阅读器，写死成 `reader_fushi` 会让漫画 /
/// PDF 书落进 EPUB 阅读器并在解析路径出错。派生走 [ReaderFushiSource.mediaSourceKeyFor]
/// 这一唯一真相源，与书架列书同一条路径。
MediaItem buildCollectionReaderMediaItem({
  required String bookKey,
  required String title,
  required BookFormat format,
}) {
  return MediaItem(
    mediaIdentifier: ReaderFushiSource.mediaIdentifierFor(bookKey),
    title: title,
    mediaTypeIdentifier: ReaderFushiSource.instance.mediaType.uniqueKey,
    mediaSourceIdentifier: ReaderFushiSource.mediaSourceKeyFor(format),
    position: 0,
    duration: 1,
    canDelete: false,
    canEdit: true,
  );
}
