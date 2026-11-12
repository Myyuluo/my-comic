import 'dart:io';

import 'package:my_comic_engine/media/cover_file_writer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 生成封面用的「不覆盖」写入路径（local-source-polish 审查）：
/// [writeCoverBytesAtomically] 的存在检查与替换之间有窗口，可能在用户刚放进
/// 封面后被覆盖；[writeCoverBytesIfAbsent] 必须在目标已存在时拒绝发布、且
/// 一字不改，目标缺席时仍写出经过校验的完整图片。
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('cover_file_writer_absent_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  List<int> jpegBytes() {
    final img.Image image = img.Image(width: 40, height: 60)
      ..clear(img.ColorRgb8(255, 0, 0));
    return img.encodeJpg(image);
  }

  test('目标缺席：写入可解码图片并返回 true，不残留 tmp', () async {
    final String destPath = p.join(root.path, 'cover.jpg');

    final bool written = await writeCoverBytesIfAbsent(
      bytes: jpegBytes(),
      destPath: destPath,
    );

    expect(written, isTrue);
    final File dest = File(destPath);
    expect(dest.existsSync(), isTrue);
    expect(isDecodableImageBytes(await dest.readAsBytes()), isTrue);
    expect(
      root.listSync().whereType<File>().map((File f) => p.basename(f.path)),
      <String>['cover.jpg'],
      reason: '发布后不得残留 .tmp 文件',
    );
  });

  test('目标已存在：绝不覆盖，原文件字节一字不改', () async {
    final String destPath = p.join(root.path, 'cover.jpg');
    final List<int> userCover = <int>[7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7];
    File(destPath).writeAsBytesSync(userCover);

    final bool written = await writeCoverBytesIfAbsent(
      bytes: jpegBytes(),
      destPath: destPath,
    );

    expect(written, isFalse, reason: '目标存在时不得发布新文件');
    expect(File(destPath).readAsBytesSync(), userCover, reason: '用户封面不得被覆盖');
    expect(
      root.listSync().whereType<File>().map((File f) => p.basename(f.path)),
      <String>['cover.jpg'],
      reason: '拒绝发布后不得残留 .tmp 文件',
    );
  });

  test('字节不是完整图片：抛校验错误且不落任何文件', () async {
    final String destPath = p.join(root.path, 'cover.jpg');

    await expectLater(
      writeCoverBytesIfAbsent(
        bytes: <int>[1, 2, 3],
        destPath: destPath,
      ),
      throwsA(isA<CoverImageInvalidException>()),
    );
    expect(File(destPath).existsSync(), isFalse);
    expect(root.listSync(), isEmpty);
  });
}
