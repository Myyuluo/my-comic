/// 本地图源封面生成：作品根目录缺少 `cover.jpg/jpeg/png` 时，从第一页生成
/// 可见的 `cover.jpg`（宽 600，JPEG 质量 85）。
///
/// 扫描本身仍只读页面文件（ADR 0013）；这里只**补写缺失的封面**，不复制 /
/// 移动页文件、不写隐藏元数据。已有任何封面文件时绝不覆盖。写入复用引擎的
/// [writeCoverBytesAtomically]（可解码校验 + 原子替换 + 解码缓存驱逐）。
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/cover_file_writer.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_archive.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

/// 生成封面的目标文件名。
const String kLocalSourceGeneratedCoverFileName = 'cover.jpg';

/// 生成封面的目标宽度（像素）；原图更窄时不放大。
const int kLocalSourceCoverWidth = 600;

/// 生成封面的 JPEG 质量。
const int kLocalSourceCoverJpegQuality = 85;

/// 一次封面补齐尝试的结局。
enum LocalSourceCoverOutcome {
  /// 已写入新的 `cover.jpg`。
  generated,

  /// 作品根目录已有 `cover.jpg/jpeg/png`，未写任何文件。
  existing,

  /// 第一页缺失 / 损坏 / 读不出，或写入失败；未写文件，下次进入重试。
  unavailable,
}

/// 封面补齐结果。
class LocalSourceCoverResult {
  const LocalSourceCoverResult({
    required this.outcome,
    this.coverRelativePath,
    this.registeredCoverPathUpdated = false,
  });

  final LocalSourceCoverOutcome outcome;

  /// 作品目录内可用的封面相对路径（已有封面的真实文件名，或 `cover.jpg`）。
  final String? coverRelativePath;

  /// 是否把已登记作品的 `coverPath` 同步到了 [coverRelativePath]。
  final bool registeredCoverPathUpdated;
}

/// 给扫描结果补齐缺失的封面。
class LocalSourceCoverService {
  const LocalSourceCoverService({required this.db});

  final FushiDatabase db;

  /// 若 [manga] 的作品根目录没有封面，取第一页生成 `cover.jpg`。
  ///
  /// 文件夹作品取扫描顺序（自然序）第一部章节的第一页；CBZ 章节按包内
  /// `pages.json` 排出的第一页（无 manifest / 损坏时回退图片名自然序）。
  /// 第一页读不出或解码失败时返回 [LocalSourceCoverOutcome.unavailable]，
  /// 不落任何文件。
  Future<LocalSourceCoverResult> generateMissingCover(
    LocalSourceManga manga,
  ) async {
    final String? existing = _existingCoverName(manga.directoryPath);
    if (existing != null) {
      final bool updated = await _syncRegisteredCoverPath(manga, existing);
      return LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.existing,
        coverRelativePath: existing,
        registeredCoverPathUpdated: updated,
      );
    }

    final Uint8List? pageBytes = await _readFirstPageBytes(manga);
    if (pageBytes == null) {
      return const LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.unavailable,
      );
    }
    final Uint8List? encoded = _encodeCover(pageBytes);
    if (encoded == null) {
      return const LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.unavailable,
      );
    }

    // 生成期间用户/其它进程可能已放进封面：再确认一次，绝不覆盖。
    final String? raced = _existingCoverName(manga.directoryPath);
    if (raced != null) {
      final bool updated = await _syncRegisteredCoverPath(manga, raced);
      return LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.existing,
        coverRelativePath: raced,
        registeredCoverPathUpdated: updated,
      );
    }

    try {
      await writeCoverBytesAtomically(
        bytes: encoded,
        destPath: p.join(
          manga.directoryPath,
          kLocalSourceGeneratedCoverFileName,
        ),
      );
    } on Object {
      return const LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.unavailable,
      );
    }

    final bool updated = await _syncRegisteredCoverPath(
      manga,
      kLocalSourceGeneratedCoverFileName,
    );
    return LocalSourceCoverResult(
      outcome: LocalSourceCoverOutcome.generated,
      coverRelativePath: kLocalSourceGeneratedCoverFileName,
      registeredCoverPathUpdated: updated,
    );
  }

  /// 已登记作品如果 `coverPath` 为空或不再指向磁盘上的封面，同步为
  /// [coverRelativePath]，让书架 / 作品页立即显示。
  Future<bool> _syncRegisteredCoverPath(
    LocalSourceManga manga,
    String coverRelativePath,
  ) async {
    final String bookKey = localSourceBookKeyFor(manga.directoryPath);
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return false;
    final String? current = row.coverPath;
    if (current != null &&
        current.isNotEmpty &&
        kLocalSourceCoverFileNames.contains(
          p.basename(current).toLowerCase(),
        ) &&
        File(p.join(manga.directoryPath, current)).existsSync()) {
      return false;
    }
    await (db.update(
      db.epubBooks,
    )..where((t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(coverPath: Value<String?>(coverRelativePath)),
    );
    return true;
  }

  /// 作品根目录已有的封面文件名（大小写不敏感）；没有为 null。
  String? _existingCoverName(String directoryPath) {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(directoryPath).listSync(followLinks: false);
    } on FileSystemException {
      return null;
    }
    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);
      if (kLocalSourceCoverFileNames.contains(name.toLowerCase())) return name;
    }
    return null;
  }

  /// 第一页字节：自然顺序第一部章节的第一页；读不出返回 null。
  Future<Uint8List?> _readFirstPageBytes(LocalSourceManga manga) async {
    if (manga.chapters.isEmpty) return null;
    final LocalSourceChapter chapter = manga.chapters.first;
    if (chapter.pages.isEmpty) return null;
    final LocalSourcePage page = chapter.pages.first;

    if (chapter.isArchive) {
      final File? archiveFile = chapter.archiveFile;
      if (archiveFile == null) return null;
      LocalSourceArchive? archive;
      try {
        archive = LocalSourceArchive.open(archiveFile.path);
        return archive.readEntry(page.relativePath);
      } on Object {
        return null;
      } finally {
        archive?.close();
      }
    }

    final File? pageFile = page.file;
    if (pageFile == null) return null;
    try {
      if (!await pageFile.exists()) return null;
      return await pageFile.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// 解码 → 按 EXIF 摆正 → 宽 600（不放大）→ JPEG 质量 85。
  /// 解不出 / 编码失败返回 null。
  Uint8List? _encodeCover(Uint8List bytes) {
    try {
      final img.Image? decoded = img.decodeImage(bytes);
      if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
        return null;
      }
      final img.Image oriented = img.bakeOrientation(decoded);
      final img.Image out = oriented.width > kLocalSourceCoverWidth
          ? img.copyResize(
              oriented,
              width: kLocalSourceCoverWidth,
              interpolation: img.Interpolation.average,
            )
          : oriented;
      return img.encodeJpg(out, quality: kLocalSourceCoverJpegQuality);
    } on Object {
      return null;
    }
  }
}

/// [LocalSourceManga] 的封面路径替换副本：后台补齐后用它更新网格条目。
LocalSourceManga withLocalSourceCoverRelativePath(
  LocalSourceManga manga,
  String? coverRelativePath,
) => LocalSourceManga(
  title: manga.title,
  directoryPath: manga.directoryPath,
  relativePath: manga.relativePath,
  chapters: manga.chapters,
  coverRelativePath: coverRelativePath,
);
