/// 读取 Local source 的一部作品的某一章——**原地**从 `local` 目录取页。
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

/// 一个 CBZ 章解出的阅读内容：页表（包内条目名，顺序即页序）与阅读器 payload。
class LocalSourceArchiveChapterContent {
  const LocalSourceArchiveChapterContent({
    required this.pages,
    required this.payload,
  });

  final List<LocalSourcePage> pages;
  final MokuroPayload payload;
}

/// Local source 阅读入口。
abstract final class LocalSourceReader {
  /// 打开 [archivePath] 这份 CBZ 的阅读内容。
  ///
  /// 页序与 Local source 阅读同一口径：包根 `pages.json` 优先（顺序 + 声明宽高），
  /// 缺失 / 损坏 / 引用了包内不存在的条目时回退到图片条目自然序。包不存在、不是
  /// 合法 ZIP 或没有页图时返回 null（调用方按「文件缺失」处理）。
  ///
  /// 下载库 CBZ 章节复用这条路径（票 07）：只读中央目录与页头，不解压整包、不
  /// 复制、不改原包。
  static Future<LocalSourceArchiveChapterContent?> readArchiveContent(
    String archivePath,
  ) async {
    final LocalSourceArchive archive;
    try {
      archive = LocalSourceArchive.open(archivePath);
    } on Object {
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
      return LocalSourceArchiveChapterContent(pages: pages, payload: payload);
    } finally {
      archive.close();
    }
  }

  /// 解析 [bookKey] 的第 [chapterIndex] 章；不是 Local source 条目 / 下标越界 /
  /// 章节目录没有页图时返回 null。
  static Future<LocalSourceResolvedChapter?> resolveChapter({
    required FushiDatabase db,
    required String bookKey,
    required int chapterIndex,
    Directory? localSourceRoot,
    Directory? downloadsRoot,
  }) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return null;
    if (LocalSourceMetadata.tryParse(row.sourceMetadata) == null) return null;
    // Ticket 08：切换 Content root 后库里的 extractDir 仍指向旧根（switch 不重基
    // 路径）。调用方给了当前 Local source root 时，旧根下的作品一律视为 Missing，
    // 绝不回读旧路径。
    //
    // Ticket 10：源未安装时 Rebuild download index 会把 `downloads/{source}/{manga}`
    // 降级成指向该文件夹的本地条目；它仍在当前 Download library 根内，所以
    // 恢复条目也能原地读取。
    if (localSourceRoot != null || downloadsRoot != null) {
      final bool withinLocal =
          localSourceRoot != null &&
          isLocalSourcePathWithinRoot(row.extractDir, localSourceRoot);
      final bool withinDownloads =
          downloadsRoot != null &&
          isLocalSourcePathWithinRoot(row.extractDir, downloadsRoot);
      if (!withinLocal && !withinDownloads) return null;
    }
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
  /// 不解压进受管目录，也不改 `local` 里的原包。
  static Future<LocalSourceResolvedChapter?> _resolveArchiveChapter({
    required EpubBookRow row,
    required int chapterIndex,
    required LocalSourceChapterRecord chapter,
    required String archivePath,
  }) async {
    // 包不存在 / 损坏：按「文件缺失」处理，让阅读器显示失败态。
    final LocalSourceArchiveChapterContent? content = await readArchiveContent(
      archivePath,
    );
    if (content == null) return null;
    return LocalSourceResolvedChapter(
      row: row,
      chapterIndex: chapterIndex,
      chapter: chapter,
      chapterDirectory: Directory(p.dirname(archivePath)),
      pages: content.pages,
      payload: content.payload,
      archiveFile: File(archivePath),
    );
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
