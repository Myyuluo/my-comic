/// 本地图源封面生成：作品根目录缺少 `cover.jpg/jpeg/png` 时，从第一页生成
/// 可见的 `cover.jpg`（宽 600，JPEG 质量 85）。
///
/// 扫描本身仍只读页面文件（ADR 0013）；这里只**补写缺失的封面**，不复制 /
/// 移动页文件、不写隐藏元数据。已有任何封面文件时绝不覆盖。写入复用引擎的
/// [writeCoverBytesAtomically]（可解码校验 + 原子替换 + 解码缓存驱逐）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/cover_file_writer.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_archive.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_layout.dart';
import 'package:my_comic_engine/media/manga/local_source/local_source_library.dart';

/// 生成封面的目标文件名。
const String kLocalSourceGeneratedCoverFileName = 'cover.jpg';

/// 生成封面的目标宽度（像素）；原图更窄时不放大。
const int kLocalSourceCoverWidth = 600;

/// 生成封面的 JPEG 质量。
const int kLocalSourceCoverJpegQuality = 85;

/// 第一页生成封面 sidecar 的 sentinel 前缀（ticket 02）。
///
/// 书架封面缓存（`MangaShelfCoverCache` 的 `.url` 侧车）既可能存远程签名 URL，
/// 也可能存本地第一页 sentinel。前缀让展示层区分「真实来源封面」与「生成封面」，
/// 从而在 Source 恢复后让真实封面优先。
const String kLocalSourceGeneratedCoverSentinelPrefix = 'local-first-page:';

/// 是否是本地第一页生成封面的 sentinel（而不是远程封面 URL）。
bool isLocalSourceGeneratedCoverSentinel(String? value) =>
    value != null && value.startsWith(kLocalSourceGeneratedCoverSentinelPrefix);

/// 生成封面用的章节容器：文件夹章节目录或 CBZ 文件。
///
/// 只描述磁盘位置；读取与解码由 [generateLocalSourceFirstPageCover] 负责。
class LocalSourceCoverContainer {
  const LocalSourceCoverContainer.folder(this.path) : isArchive = false;

  const LocalSourceCoverContainer.archive(this.path) : isArchive = true;

  /// 容器绝对路径：文件夹章节目录，或 `.cbz` 文件。
  final String path;

  final bool isArchive;
}

/// 第一页生成封面的只读结果。
class LocalSourceGeneratedCover {
  const LocalSourceGeneratedCover({
    required this.bytes,
    required this.sentinel,
  });

  /// 缩放后的 JPEG 字节（宽 600、质量 85）。
  final Uint8List bytes;

  /// 容器本地文件 sentinel：规范路径 + 大小 + mtime。
  ///
  /// 写入 Program state 的 shelf cover 缓存 sidecar；容器替换或更新后 sentinel
  /// 变化，缓存据此重新生成。
  final String sentinel;
}

/// 从 [container] 的第一页生成封面字节，**不写任何文件**。
///
/// 复用 Local source 的页表规则：CBZ 取包根 `pages.json` 排出的第一页（缺失 /
/// 损坏时回退图片名自然序），文件夹章节同样 `pages.json` 优先、否则自然序扫描
/// 图片。`ComicInfo.xml` 等非图片条目天然被跳过。
///
/// 第一页缺失、容器读不了或解码失败返回 null；调用方保留占位并记日志。
/// 已选中的第一页损坏时不会偷偷换下一页——那会让封面随损坏情况漂移。
Future<LocalSourceGeneratedCover?> generateLocalSourceFirstPageCover(
  LocalSourceCoverContainer container,
) async {
  if (container.isArchive) {
    return _generateCoverFromArchive(container.path);
  }
  return _generateCoverFromFolder(container.path);
}

/// 只计算 [container] 第一页的 sentinel，不读取图片字节。
///
/// 书架每次重算时用它判断已缓存的生成封面是否过期；只有 sentinel 变化才重新
/// 解码/编码，避免每帧都读一遍第一页。
Future<String?> localSourceFirstPageCoverSentinel(
  LocalSourceCoverContainer container,
) async {
  if (container.isArchive) {
    LocalSourceArchive? archive;
    try {
      archive = LocalSourceArchive.open(container.path);
      final List<LocalSourceArchivePage> pages = readLocalSourceArchivePages(
        archive,
      );
      if (pages.isEmpty) return null;
      final FileStat stat = await File(container.path).stat();
      return _coverSentinel(canonicalPath: container.path, stat: stat);
    } on Object {
      return null;
    } finally {
      archive?.close();
    }
  }
  try {
    final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
      container.path,
      isRootChapter: false,
    );
    if (pages.isEmpty) return null;
    final File? pageFile = pages.first.file;
    if (pageFile == null || !await pageFile.exists()) return null;
    return await _folderCoverSentinel(container.path, pages);
  } on Object {
    return null;
  }
}

Future<LocalSourceGeneratedCover?> _generateCoverFromArchive(
  String archivePath,
) async {
  LocalSourceArchive? archive;
  try {
    archive = LocalSourceArchive.open(archivePath);
    final List<LocalSourceArchivePage> pages = readLocalSourceArchivePages(
      archive,
    );
    if (pages.isEmpty) return null;
    final Uint8List? pageBytes = archive.readEntry(pages.first.relativePath);
    if (pageBytes == null) return null;
    final Uint8List? encoded = encodeLocalSourceCoverBytes(pageBytes);
    if (encoded == null) return null;
    final File file = File(archivePath);
    final FileStat stat = await file.stat();
    return LocalSourceGeneratedCover(
      bytes: encoded,
      sentinel: _coverSentinel(canonicalPath: file.path, stat: stat),
    );
  } on Object {
    return null;
  } finally {
    archive?.close();
  }
}

Future<LocalSourceGeneratedCover?> _generateCoverFromFolder(
  String directoryPath,
) async {
  try {
    final List<LocalSourcePage> pages = await readLocalSourceChapterPages(
      directoryPath,
      isRootChapter: false,
    );
    if (pages.isEmpty) return null;
    final File? pageFile = pages.first.file;
    if (pageFile == null) return null;
    if (!await pageFile.exists()) return null;
    final Uint8List pageBytes = await pageFile.readAsBytes();
    final Uint8List? encoded = encodeLocalSourceCoverBytes(pageBytes);
    if (encoded == null) return null;
    // 文件夹容器的 sentinel 必须覆盖整个目录内容，而不是只看第一页 stat：
    // 替换容器时第一页的 size/mtime 可能被还原成原值（备份还原 / 复制工具都会
    // 保留 mtime），只看第一页会让封面永远停在旧图。
    return LocalSourceGeneratedCover(
      bytes: encoded,
      sentinel: await _folderCoverSentinel(directoryPath, pages),
    );
  } on Object {
    return null;
  }
}

/// CBZ 容器 sentinel：规范路径 + 归档文件 size/mtime。
String _coverSentinel({
  required String canonicalPath,
  required FileStat stat,
}) =>
    '$kLocalSourceGeneratedCoverSentinelPrefix'
    '${p.canonicalize(canonicalPath)}|${stat.size}|'
    '${stat.modified.millisecondsSinceEpoch}';

/// 文件夹容器 sentinel：规范路径 + 目录 mtime + 页数 + 每页
/// `相对路径|size|mtime` 的摘要。
///
/// 仅看第一页 stat 无法感知「容器被替换但第一页 size/mtime 被保留」——目录
/// mtime、页数与整份页表指纹一起构成容器身份。摘要把长度压到固定 64 字符，
/// sidecar 不会随章节页数膨胀。
Future<String> _folderCoverSentinel(
  String directoryPath,
  List<LocalSourcePage> pages,
) async {
  int directoryModified = 0;
  try {
    directoryModified = (await Directory(
      directoryPath,
    ).stat()).modified.millisecondsSinceEpoch;
  } on FileSystemException {
    // 目录读不了：按 0 处理，页表指纹仍能区分大多数变化。
  }
  final StringBuffer material = StringBuffer()
    ..write(p.canonicalize(directoryPath))
    ..write('|')
    ..write(directoryModified)
    ..write('|')
    ..write(pages.length)
    ..write('|');
  for (final LocalSourcePage page in pages) {
    int size = 0;
    int modified = 0;
    final File? file = page.file;
    if (file != null) {
      try {
        final FileStat stat = await file.stat();
        size = stat.size;
        modified = stat.modified.millisecondsSinceEpoch;
      } on FileSystemException {
        // 读不了的单页按 0 处理；页面缺失本身会改变页表。
      }
    }
    material
      ..write(page.relativePath)
      ..write('|')
      ..write(size)
      ..write('|')
      ..write(modified)
      ..write(';');
  }
  final String fingerprint = sha256
      .convert(utf8.encode(material.toString()))
      .toString();
  return '$kLocalSourceGeneratedCoverSentinelPrefix'
      '${p.canonicalize(directoryPath)}|${pages.length}|$fingerprint';
}

/// 解码 → 按 EXIF 摆正 → 宽 600（不放大）→ JPEG 质量 85。
/// 解不出 / 编码失败返回 null。
Uint8List? encodeLocalSourceCoverBytes(Uint8List bytes) {
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

  final MyComicDatabase db;

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
    final Uint8List? encoded = encodeLocalSourceCoverBytes(pageBytes);
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

    // 上面的存在检查与写入之间仍有窗口：用「目标已存在就不发布」的写入路径
    // 收窄竞态——生成期间用户放进来的封面绝不被这里覆盖。
    final bool written;
    try {
      written = await writeCoverBytesIfAbsent(
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
    if (!written) {
      final String cover =
          _existingCoverName(manga.directoryPath) ??
          kLocalSourceGeneratedCoverFileName;
      final bool updated = await _syncRegisteredCoverPath(manga, cover);
      return LocalSourceCoverResult(
        outcome: LocalSourceCoverOutcome.existing,
        coverRelativePath: cover,
        registeredCoverPathUpdated: updated,
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
