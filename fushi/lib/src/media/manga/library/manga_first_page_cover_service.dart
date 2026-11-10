import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_cover.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_metadata.dart';

import 'package:fushi/src/media/manga/library/manga_adjacent_chapter.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_cache.dart';
import 'package:fushi/src/media/manga/library/manga_shelf_cover_revision.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 本地第一页生成封面（ticket 02）。
///
/// 对「有完整本地 Chapter container、但没有更优先封面」的 Manga，从规范阅读
/// 顺序下第一个完整容器的第一页生成封面，**只写入** Program state 的 shelf
/// cover 缓存（按 bookKey）。绝不写 Content root / Download library、不创建下载
/// 目录、不改 `epub_books.cover_path`。
///
/// 缓存 sidecar 存本地容器 sentinel（容器规范路径 + 大小 + mtime）；容器替换
/// 或更新后 sentinel 变化，下一次解析重新生成。生成成功后 bump ticket 01 的
/// [MangaShelfCoverRevision]，书架 provider 立即重算。
class MangaFirstPageCoverService {
  MangaFirstPageCoverService({required this.database, required this.cache});

  final FushiDatabase database;

  final MangaShelfCoverCache cache;

  /// 页面级测试缝：没有 `AppPaths`（widget 测试壳）时注入临时缓存根。
  @visibleForTesting
  static MangaFirstPageCoverService? debugServiceOverride;

  /// 用 Program state 缓存根装配；[cacheRoot] 为 null（启动早期 / 测试壳）
  /// 且没有测试覆盖时返回 null，书架与作品页退回占位。
  static MangaFirstPageCoverService? forAppCache({
    required FushiDatabase database,
    required Directory? cacheRoot,
  }) {
    final MangaFirstPageCoverService? override = debugServiceOverride;
    if (override != null) return override;
    if (cacheRoot == null) return null;
    return MangaFirstPageCoverService(
      database: database,
      cache: MangaShelfCoverCache(
        Directory(p.join(cacheRoot.path, kMangaShelfCoverCacheDirName)),
      ),
    );
  }

  /// 同一次会话内同一本书只跑一条生成链，避免书架与作品页并发写同一份缓存。
  static final Map<String, Future<bool>> _inFlight = <String, Future<bool>>{};

  /// 命中按 bookKey 的生成封面缓存时返回 `file://` URL；否则 null。
  ///
  /// 只看 sidecar：远程真实封面（签名 URL）与生成封面（本地 sentinel）共用
  /// 一份缓存文件，展示优先级需要区分两者。
  Future<String?> cachedGeneratedCoverUrl(String bookKey) async {
    final String? stored = await cache.storedSourceUrl(bookKey);
    if (!isLocalSourceGeneratedCoverSentinel(stored)) return null;
    return cache.coverUrlFor(bookKey);
  }

  /// 命中按 bookKey 的真实来源封面缓存时返回 `file://` URL；生成封面返回 null。
  Future<String?> cachedRealCoverUrl(String bookKey) async {
    final String? url = await cache.coverUrlFor(bookKey);
    if (url == null) return null;
    final String? stored = await cache.storedSourceUrl(bookKey);
    if (isLocalSourceGeneratedCoverSentinel(stored)) return null;
    return url;
  }

  /// 生成封面（已有、真实封面、本地 `cover.*` 或容器 sentinel 未变时 no-op）。
  ///
  /// 返回 true 仅表示本次真的写入了新的持久封面字节。失败不抛：作品页 / 书架
  /// 保留占位，阅读与重建不受影响。
  Future<bool> generateIfNeeded(EpubBookRow row) {
    final String key = '${cache.directory.path}\u0000${row.bookKey}';
    final Future<bool>? existing = _inFlight[key];
    if (existing != null) return existing;
    final Future<bool> future = _generateIfNeeded(row).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  /// 作品页（未入库的本地图源扫描结果）懒生成入口。
  ///
  /// 未入库作品没有 `epub_books` 行，但仍用稳定的 `localSourceBookKeyFor`
  /// 派生 key 写 Program state 缓存；加入书架后同一 key 直接复用。
  Future<String?> ensureGeneratedCoverForScanned({
    required LocalSourceManga manga,
    required String bookKey,
  }) async {
    final String key = '${cache.directory.path}\u0000$bookKey';
    final Future<bool>? existing = _inFlight[key];
    final Future<bool> future =
        existing ??
        _generateForScanned(manga: manga, bookKey: bookKey).whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = future;
    await future;
    return cachedGeneratedCoverUrl(bookKey);
  }

  /// 作品页等待生成完成并返回缓存 URL（没有容器 / 生成失败返回 null）。
  Future<String?> ensureGeneratedCover(EpubBookRow row) async {
    await generateIfNeeded(row);
    return cachedGeneratedCoverUrl(row.bookKey);
  }

  Future<bool> _generateIfNeeded(EpubBookRow row) async {
    try {
      if (BookFormat.parseOrEpub(row.format) != BookFormat.manga) return false;
      if (await cachedRealCoverUrl(row.bookKey) != null) {
        // 真实来源封面已经落盘：生成封面不得覆盖它。
        return false;
      }
      if (await _hasLocalCoverFile(row.extractDir)) return false;
      final LocalSourceCoverContainer? container = await _firstCoverContainer(
        row,
      );
      if (container == null) return false;
      return await _generateForContainer(
        bookKey: row.bookKey,
        container: container,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFirstPageCoverService.generate',
        error,
        stack,
      );
      return false;
    }
  }

  Future<bool> _generateForScanned({
    required LocalSourceManga manga,
    required String bookKey,
  }) async {
    try {
      if (_hasCoverRelativePath(manga.directoryPath, manga.coverRelativePath)) {
        return false;
      }
      final LocalSourceChapter? chapter = manga.chapters.isEmpty
          ? null
          : manga.chapters.first;
      if (chapter == null) return false;
      final String? path = chapter.isArchive
          ? chapter.archiveFile?.path
          : (chapter.relativePath.isEmpty
                ? manga.directoryPath
                : p.join(manga.directoryPath, chapter.relativePath));
      if (path == null) return false;
      final LocalSourceCoverContainer container = chapter.isArchive
          ? LocalSourceCoverContainer.archive(path)
          : LocalSourceCoverContainer.folder(path);
      return await _generateForContainer(
        bookKey: bookKey,
        container: container,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFirstPageCoverService.generateScanned',
        error,
        stack,
      );
      return false;
    }
  }

  /// 生成并写入缓存；sentinel 未变时跳过解码与写盘。
  Future<bool> _generateForContainer({
    required String bookKey,
    required LocalSourceCoverContainer container,
  }) async {
    final String? sentinel = await localSourceFirstPageCoverSentinel(container);
    if (sentinel == null) {
      ErrorLogService.instance.logDiagnostic(
        'MangaFirstPageCoverService.container',
        '${container.path}: no readable first page',
      );
      return false;
    }
    final String? stored = await cache.storedSourceUrl(bookKey);
    if (isLocalSourceGeneratedCoverSentinel(stored) &&
        stored == sentinel &&
        await cache.hasCover(bookKey)) {
      return false;
    }
    final LocalSourceGeneratedCover? generated =
        await generateLocalSourceFirstPageCover(container);
    if (generated == null) {
      ErrorLogService.instance.logDiagnostic(
        'MangaFirstPageCoverService.decode',
        '${container.path}: first page is not a decodable image',
      );
      return false;
    }
    final bool wrote = await cache.store(
      bookKey: bookKey,
      sourceUrl: generated.sentinel,
      bytes: generated.bytes,
    );
    if (wrote) MangaShelfCoverRevision.bump();
    return wrote;
  }

  /// 规范阅读顺序下第一个完整 Chapter container。
  ///
  /// 在线条目先按 `manga_chapter_dirs` 映射 + [mangaReadingOrder] 找；映射缺失
  /// （尚未重建）时回退扫描漫画目录。Local source 条目直接扫描作品目录——扫描
  /// 顺序就是自然阅读顺序。
  Future<LocalSourceCoverContainer?> _firstCoverContainer(
    EpubBookRow row,
  ) async {
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry != null) {
      final LocalSourceCoverContainer? mapped =
          await _firstMappedCoverContainer(row, entry);
      if (mapped != null) return mapped;
    }
    return _firstScannedCoverContainer(row);
  }

  Future<LocalSourceCoverContainer?> _firstMappedCoverContainer(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
  ) async {
    final Directory mangaDir = Directory(row.extractDir);
    if (!await mangaDir.exists()) return null;
    final Map<String, MangaChapterDirRow> mappings = await database
        .getMangaChapterDirRowsForBook(row.bookKey);
    MangaPagesManifest? rootManifest;
    bool rootManifestRead = false;
    bool loggedUnreadable = false;
    for (final OnlineMangaChapter chapter in mangaReadingOrder(
      entry.chapters,
    )) {
      final MangaChapterDirRow? mapping = mappings[chapter.key];
      if (mapping != null) {
        final String containerPath = p.join(row.extractDir, mapping.folderName);
        if (!isLocalSourcePathWithinRoot(containerPath, mangaDir)) continue;
        final bool readable;
        final LocalSourceCoverContainer container;
        if (mapping.containerKindEnum == MangaChapterContainerKind.archive) {
          final File file = File(containerPath);
          if (!await file.exists()) continue;
          readable = await _isArchiveReadable(file);
          container = LocalSourceCoverContainer.archive(file.path);
        } else {
          final Directory directory = Directory(containerPath);
          if (!await directory.exists()) continue;
          readable = await _isFolderReadable(directory);
          container = LocalSourceCoverContainer.folder(directory.path);
        }
        if (readable) return container;
        if (!loggedUnreadable) {
          loggedUnreadable = true;
          ErrorLogService.instance.logDiagnostic(
            'MangaFirstPageCoverService.container',
            '$containerPath: unreadable chapter container',
          );
        }
        continue;
      }
      // 单章作品把 pages.json 直接放在漫画目录根：根容器不是章子目录映射。
      if (!rootManifestRead) {
        rootManifest = await readPagesManifest(mangaDir);
        rootManifestRead = true;
      }
      if (rootManifest?.chapterKey == chapter.key &&
          await readDownloadLibraryChapterPayload(mangaDir) != null) {
        return LocalSourceCoverContainer.folder(mangaDir.path);
      }
    }
    return null;
  }

  Future<LocalSourceCoverContainer?> _firstScannedCoverContainer(
    EpubBookRow row,
  ) async {
    final Directory mangaDir = Directory(row.extractDir);
    if (!await mangaDir.exists()) return null;
    final LocalSourceMetadata? metadata = LocalSourceMetadata.tryParse(
      row.sourceMetadata,
    );
    final LocalSourceManga? manga = await scanLocalSourceMangaDirectory(
      mangaDir,
      relativePath: metadata?.relativePath ?? p.basename(row.extractDir),
    );
    if (manga == null || manga.chapters.isEmpty) return null;
    final LocalSourceChapter chapter = manga.chapters.first;
    if (chapter.isArchive) {
      final File? file = chapter.archiveFile;
      return file == null ? null : LocalSourceCoverContainer.archive(file.path);
    }
    final String path = chapter.relativePath.isEmpty
        ? manga.directoryPath
        : p.join(manga.directoryPath, chapter.relativePath);
    return LocalSourceCoverContainer.folder(path);
  }

  Future<bool> _isArchiveReadable(File file) async {
    final MangaPagesManifest? manifest =
        await readDownloadLibraryArchiveManifest(file);
    if (manifest != null) return isDownloadLibraryArchiveComplete(file);
    return isDownloadLibraryArchiveReadable(file);
  }

  Future<bool> _isFolderReadable(Directory directory) async {
    final MangaPagesManifest? manifest = await readPagesManifest(directory);
    if (manifest != null) {
      return await readDownloadLibraryChapterPayload(directory) != null;
    }
    return isDownloadLibraryFolderReadable(directory);
  }

  /// 作品根目录已有 `cover.jpg/jpeg/png`（大小写不敏感）时不再生成。
  Future<bool> _hasLocalCoverFile(String extractDir) async {
    try {
      await for (final FileSystemEntity entity in Directory(
        extractDir,
      ).list(followLinks: false)) {
        if (entity is File &&
            kLocalSourceCoverFileNames.contains(
              p.basename(entity.path).toLowerCase(),
            )) {
          return true;
        }
      }
    } on FileSystemException {
      // 目录不存在 / 读不了：交给后续容器探测返回 null。
    }
    return false;
  }

  bool _hasCoverRelativePath(String directoryPath, String? relativePath) {
    if (relativePath == null || relativePath.isEmpty) return false;
    return File(p.join(directoryPath, relativePath)).existsSync();
  }
}
