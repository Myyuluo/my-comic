// 下载库 CBZ 章节的页缩略图（票 07）：缩略图由页会话按需解压，构造缩略图
// 本身不碰磁盘；只有真正解码某一页时才解那一页，会话关闭清理临时目录。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/manga/mihon/manga_page_provider.dart';
import 'package:my_comic/src/media/manga/reader/manga_session_page_image.dart';
import 'package:image/image.dart' as img;
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

Future<ui.Image> _resolve(ImageProvider<Object> provider) {
  final Completer<ui.Image> done = Completer<ui.Image>();
  final ImageStream stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (ImageInfo info, bool sync) {
      stream.removeListener(listener);
      done.complete(info.image);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      done.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return done.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('缩略图只在解码时解当前页，会话关闭清理临时目录', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'manga_session_page_image_',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    final Uint8List first = Uint8List.fromList(
      img.encodePng(img.Image(width: 100, height: 150)),
    );
    final Uint8List second = Uint8List.fromList(
      img.encodePng(img.Image(width: 220, height: 330)),
    );
    final Uint8List third = Uint8List.fromList(
      img.encodePng(img.Image(width: 140, height: 210)),
    );
    final Archive archive = Archive()
      ..addFile(ArchiveFile('001.png', first.length, first))
      ..addFile(ArchiveFile('002.png', second.length, second))
      ..addFile(ArchiveFile('003.png', third.length, third));
    final File cbz = File(p.join(root.path, 'book.cbz'))
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);

    final LocalSourceArchiveReaderSession session =
        await LocalSourceArchivePageProvider(
              archivePath: cbz.path,
              cacheRoot: Directory(p.join(root.path, 'cache')),
              relativePaths: const <String>['001.png', '002.png', '003.png'],
            ).open()
            as LocalSourceArchiveReaderSession;
    addTearDown(session.close);

    final List<MangaSessionPageImage> thumbnails = <MangaSessionPageImage>[
      for (int index = 0; index < session.pageCount; index++)
        MangaSessionPageImage(session: session, pageIndex: index),
    ];
    expect(session.directory.listSync(), isEmpty, reason: '构造缩略图不得提前解压任何页');

    final ui.Image image = await _resolve(thumbnails[1]);
    expect(image.width, 220);
    expect(image.height, 330);
    expect(
      session.directory.listSync().whereType<File>().map(
        (File file) => p.basename(file.path),
      ),
      <String>['page_000001.png'],
      reason: '只解当前页，不预解其余页',
    );
    expect(cbz.existsSync(), isTrue, reason: '原包只读');

    await session.close();
    expect(await session.directory.exists(), isFalse);
  });
}
