/// 读取 Local source 的一部作品的某一章——**原地**从 `localcomic` 目录取页。
///
/// 登记时写入的章节描述只保存目录相对路径；每次打开都重新枚举章节页，因此用户
/// 在导入后新增/替换的图片无需重新导入即可读到（ADR 0013：不复制、不监视）。
library;

import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/import/image_size_probe.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 解析好的一章：页文件、目录与阅读器可直接装载的 payload。
class LocalSourceResolvedChapter {
  const LocalSourceResolvedChapter({
    required this.row,
    required this.chapterIndex,
    required this.chapter,
    required this.chapterDirectory,
    required this.pages,
    required this.payload,
  });

  final EpubBookRow row;
  final int chapterIndex;
  final LocalSourceChapterRecord chapter;
  final Directory chapterDirectory;
  final List<LocalSourcePage> pages;
  final MokuroPayload payload;
}

/// Local source 阅读入口。
abstract final class LocalSourceReader {
  /// 解析 [bookKey] 的第 [chapterIndex] 章；不是 Local source 条目 / 下标越界 /
  /// 章节目录没有页图时返回 null。
  static Future<LocalSourceResolvedChapter?> resolveChapter({
    required FushiDatabase db,
    required String bookKey,
    required int chapterIndex,
  }) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return null;
    if (LocalSourceMetadata.tryParse(row.sourceMetadata) == null) return null;
    final List<LocalSourceChapterRecord> chapters = decodeLocalSourceChapters(
      row.chaptersJson,
    );
    if (chapterIndex < 0 || chapterIndex >= chapters.length) return null;
    final LocalSourceChapterRecord chapter = chapters[chapterIndex];
    final Directory? directory = localSourceChapterDirectory(
      row.extractDir,
      chapter,
    );
    if (directory == null) return null;
    if (!await directory.exists()) return null;

    final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
      directory.path,
      isRootChapter: chapter.relativePath.isEmpty,
    );
    if (pages.isEmpty) return null;
    final MokuroPayload payload = await localSourcePayloadForPages(pages);
    return LocalSourceResolvedChapter(
      row: row,
      chapterIndex: chapterIndex,
      chapter: chapter,
      chapterDirectory: directory,
      pages: pages,
      payload: payload,
    );
  }
}

/// 章节记录 → 磁盘目录；相对路径越出作品目录时返回 null（防穿越）。
Directory? localSourceChapterDirectory(
  String mangaDirectoryPath,
  LocalSourceChapterRecord chapter,
) {
  if (chapter.relativePath.isEmpty) return Directory(mangaDirectoryPath);
  final String root = p.canonicalize(mangaDirectoryPath);
  // 返回规范化后的原始大小写路径（Windows 的 canonicalize 会折叠大小写，
  // 直接拿它当目录名在大小写敏感文件系统上会找不到文件）。
  final String candidate = p.normalize(
    p.absolute(
      p.joinAll(<String>[
        mangaDirectoryPath,
        ...chapter.relativePath.split('/'),
      ]),
    ),
  );
  if (!p.isWithin(root, p.canonicalize(candidate))) return null;
  return Directory(candidate);
}

/// 页列表 → 阅读器 payload。宽高优先取 `pages.json` 声明，否则读文件头；
/// 认不出的格式退回整张解码，仍失败时用安全的占位比例，不让一章打不开。
Future<MokuroPayload> localSourcePayloadForPages(
  List<LocalSourcePage> pages,
) async {
  final List<MokuroImage> images = <MokuroImage>[];
  for (final LocalSourcePage page in pages) {
    int? width = page.width;
    int? height = page.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      final ({int width, int height})? probed = await _probePage(page.file);
      width = probed?.width ?? 1000;
      height = probed?.height ?? 1414;
    }
    images.add(
      MokuroImage(
        url: page.relativePath,
        size: MokuroSize(width.toDouble(), height.toDouble()),
        blocks: const <MokuroBlock>[],
      ),
    );
  }
  return MokuroPayload(images: images);
}

Future<({int width, int height})?> _probePage(File file) async {
  try {
    final bytes = await file.readAsBytes();
    final ({int width, int height})? header = probeOrientedImageSize(bytes);
    if (header != null) return header;
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    final img.Image oriented = img.bakeOrientation(decoded);
    return (width: oriented.width, height: oriented.height);
  } on Object {
    return null;
  }
}
