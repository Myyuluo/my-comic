/// 读取 Local source 的一部作品的某一章——**原地**从 `localcomic` 目录取页。
///
/// 登记时写入的章节描述只保存目录相对路径；每次打开都重新枚举章节页，因此用户
/// 在导入后新增/替换的图片无需重新导入即可读到（ADR 0013：不复制、不监视）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/import/image_size_probe.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_archive.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 解析好的一章：页文件、目录 / 压缩包与阅读器可直接装载的 payload。
class LocalSourceResolvedChapter {
  const LocalSourceResolvedChapter({
    required this.row,
    required this.chapterIndex,
    required this.chapter,
    required this.chapterDirectory,
    required this.pages,
    required this.payload,
    this.archiveFile,
  });

  final EpubBookRow row;
  final int chapterIndex;
  final LocalSourceChapterRecord chapter;

  /// 文件夹章节的目录；CBZ 章节为压缩包所在目录（[archiveFile] 才是容器）。
  final Directory chapterDirectory;
  final List<LocalSourcePage> pages;
  final MokuroPayload payload;

  /// CBZ 章节的压缩包；文件夹章节为 null。
  final File? archiveFile;

  bool get isArchive => archiveFile != null;
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
    final String? containerPath = localSourceChapterPath(
      row.extractDir,
      chapter,
    );
    if (containerPath == null) return null;
    final FileSystemEntityType type = await FileSystemEntity.type(
      containerPath,
      followLinks: false,
    );
    if (type == FileSystemEntityType.file &&
        p.extension(containerPath).toLowerCase() == '.cbz') {
      return _resolveArchiveChapter(
        row: row,
        chapterIndex: chapterIndex,
        chapter: chapter,
        archivePath: containerPath,
      );
    }
    if (type != FileSystemEntityType.directory) return null;

    final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
      containerPath,
      isRootChapter: chapter.relativePath.isEmpty,
    );
    if (pages.isEmpty) return null;
    final MokuroPayload payload = await localSourcePayloadForPages(pages);
    return LocalSourceResolvedChapter(
      row: row,
      chapterIndex: chapterIndex,
      chapter: chapter,
      chapterDirectory: Directory(containerPath),
      pages: pages,
      payload: payload,
    );
  }

  /// CBZ 章节：只读打开压缩包，页表/宽高按需取自包内条目，读完即关闭——
  /// 不解压进受管目录，也不改 `localcomic` 里的原包。
  static Future<LocalSourceResolvedChapter?> _resolveArchiveChapter({
    required EpubBookRow row,
    required int chapterIndex,
    required LocalSourceChapterRecord chapter,
    required String archivePath,
  }) async {
    final LocalSourceArchive archive;
    try {
      archive = LocalSourceArchive.open(archivePath);
    } on Object {
      // 包不存在 / 损坏：按「文件缺失」处理，让阅读器显示失败态。
      return null;
    }
    try {
      final List<LocalSourcePage> pages = <LocalSourcePage>[
        for (final LocalSourceArchivePage page in readLocalSourceArchivePages(
          archive,
        ))
          LocalSourcePage(
            relativePath: page.relativePath,
            width: page.width,
            height: page.height,
          ),
      ];
      if (pages.isEmpty) return null;
      final MokuroPayload payload = await localSourcePayloadForPages(
        pages,
        readBytes: (LocalSourcePage page) async =>
            archive.readEntry(page.relativePath),
      );
      return LocalSourceResolvedChapter(
        row: row,
        chapterIndex: chapterIndex,
        chapter: chapter,
        chapterDirectory: Directory(p.dirname(archivePath)),
        pages: pages,
        payload: payload,
        archiveFile: File(archivePath),
      );
    } finally {
      archive.close();
    }
  }
}

/// 章节记录 → 磁盘路径（目录或 `.cbz` 文件）；相对路径越出作品目录时返回
/// null（防穿越）。
String? localSourceChapterPath(
  String mangaDirectoryPath,
  LocalSourceChapterRecord chapter,
) {
  if (chapter.relativePath.isEmpty) return mangaDirectoryPath;
  final String root = p.canonicalize(mangaDirectoryPath);
  // 返回规范化后的原始大小写路径（Windows 的 canonicalize 会折叠大小写，
  // 直接拿它当目录/文件名在大小写敏感文件系统上会找不到）。
  final String candidate = p.normalize(
    p.absolute(
      p.joinAll(<String>[
        mangaDirectoryPath,
        ...chapter.relativePath.split('/'),
      ]),
    ),
  );
  if (!p.isWithin(root, p.canonicalize(candidate))) return null;
  return candidate;
}

/// 章节记录 → 章节目录（文件夹章节）；CBZ 章节 / 越界路径返回 null。
Directory? localSourceChapterDirectory(
  String mangaDirectoryPath,
  LocalSourceChapterRecord chapter,
) {
  final String? path = localSourceChapterPath(mangaDirectoryPath, chapter);
  return path == null ? null : Directory(path);
}

/// 页列表 → 阅读器 payload。宽高优先取 `pages.json` 声明，否则读文件头（CBZ
/// 章节经 [readBytes] 从包里取页字节）；认不出的格式退回整张解码，仍失败时用
/// 安全的占位比例，不让一章打不开。
Future<MokuroPayload> localSourcePayloadForPages(
  List<LocalSourcePage> pages, {
  Future<Uint8List?> Function(LocalSourcePage page)? readBytes,
}) async {
  final List<MokuroImage> images = <MokuroImage>[];
  for (final LocalSourcePage page in pages) {
    int? width = page.width;
    int? height = page.height;
    if (width == null || height == null || width <= 0 || height <= 0) {
      Uint8List? bytes;
      try {
        bytes = page.file != null
            ? await page.file!.readAsBytes()
            : await readBytes?.call(page);
      } on Object {
        bytes = null;
      }
      final ({int width, int height})? probed = _probePageBytes(bytes);
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

({int width, int height})? _probePageBytes(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  try {
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
