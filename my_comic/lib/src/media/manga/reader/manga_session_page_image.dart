import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/src/media/manga/mihon/manga_page_provider.dart';

/// 由页会话提供文件的缩略图（下载库 CBZ 等按需解压的会话）。
///
/// 阅读器的页面一览 / 拖动气泡要的是 `ImageProvider?`（同步返回），但压缩包里的
/// 页在真正显示前并没有磁盘文件。这个 provider 把「向会话要文件」推迟到解码时
/// （[loadImage]），因此构造缩略图不会解压任何页，只有真正渲染的格子才由会话解
/// 当前页到它的会话私有缓存。
///
/// 缓存键取会话的稳定页身份（`session.cacheIdentity`，构造时取一次）：跨会话
/// 重开同一压缩包仍可复用已解码的缩略图。
class MangaSessionPageImage extends ImageProvider<MangaSessionPageImage> {
  MangaSessionPageImage({required this.session, required this.pageIndex})
    : cacheKey = session.cacheIdentity(pageIndex);

  final MangaReaderSession session;
  final int pageIndex;

  /// 稳定页身份（`session.cacheIdentity`）；参与 ImageCache 键。
  final String cacheKey;

  @override
  Future<MangaSessionPageImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MangaSessionPageImage>(this);

  @override
  ImageStreamCompleter loadImage(
    MangaSessionPageImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1,
      debugLabel: cacheKey,
      informationCollector: () sync* {
        yield ErrorDescription('Page: $cacheKey');
      },
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    final File? file = await session.localFile(pageIndex);
    if (file == null) {
      throw StateError('Page session returned no file for $cacheKey');
    }
    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError(
        'Page $cacheKey is empty and cannot be loaded as an image.',
      );
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is MangaSessionPageImage && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;

  @override
  String toString() =>
      '${objectRuntimeType(this, 'MangaSessionPageImage')}("$cacheKey")';
}
