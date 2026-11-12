/// 漫画目录页图枚举：从已删除的 OCR 整卷任务里抽出的通用符号
/// （ticket 21/22：`.mokuro` 导入与本地扫描仍需要它）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:my_comic_engine/media/manga/shelf_sort.dart'
    show naturalCompare;
import 'package:my_comic_engine/media/media_extensions.dart';
import 'package:my_comic_engine/media/manga/mokuro_payload.dart'
    show normalizeMangaUrl;

/// 页图扩展名白名单（小写比较）＝图片扩展名基集，与漫画导入的
/// `kMangaImageExtensions`（manga_importer.dart）同源对齐。
const Set<String> kMangaOcrImageExtensions = kImageExtensionsBase;

/// 一张待处理的页图：磁盘文件 + manga.json 用的正斜杠相对 url。
class MangaOcrPageFile {
  const MangaOcrPageFile({required this.file, required this.relativeUrl});

  final File file;

  /// 相对被扫描目录的正斜杠路径（`p001.jpg` / `vol1/p001.jpg`）。
  final String relativeUrl;
}

/// 页图目录树的最大下钻层数（root 自身算第 0 层）。
const int kMangaPageScanMaxDepth = 6;

/// 枚举 [root] 下的页图：递归下钻到 [kMangaPageScanMaxDepth] 层，排除
/// `manga_ocr_out` 产物目录，按相对路径自然序排序。
List<MangaOcrPageFile> enumerateMangaPages(Directory root) {
  final List<MangaOcrPageFile> pages = <MangaOcrPageFile>[];
  void addFile(File file) {
    final String ext = p.extension(file.path).toLowerCase();
    if (!kMangaOcrImageExtensions.contains(ext)) return;
    final String relative = p.relative(file.path, from: root.path);
    pages.add(
      MangaOcrPageFile(file: file, relativeUrl: normalizeMangaUrl(relative)),
    );
  }

  void walk(Directory dir, int depth) {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    for (final FileSystemEntity entity in entries) {
      if (entity is File) {
        addFile(entity);
      } else if (entity is Directory && depth < kMangaPageScanMaxDepth) {
        if (p.basename(entity.path) == 'manga_ocr_out') continue;
        walk(entity, depth + 1);
      }
    }
  }

  walk(root, 0);
  pages.sort(
    (MangaOcrPageFile a, MangaOcrPageFile b) =>
        naturalCompare(a.relativeUrl, b.relativeUrl),
  );
  return pages;
}
