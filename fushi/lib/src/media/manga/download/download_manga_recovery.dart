/// 发现 / 恢复辅助模块：把 `downloads/{source}/{manga}` 里尚未入库的作品
/// 登记为 Manga。供「检索已下载」（票 03）复用；「重建下载索引」不再调用它。
///
/// 归属规则（与 Rebuild 曾经的内联 orphan recovery 完全一致）：
///  - 一个漫画目录里可以有多个作品身份：按 `pages.json` 的
///    `(runtime, extension, sourceId, mangaKey)` 逐个身份建条目；
///  - 源已安装时建在线条目，并把**完整**章节写进 `manga_chapter_dirs`；
///  - 源未安装或目录没有 `pages.json` 时，原地登记为指向该 `downloads` 目录的
///    本地条目；
///  - 默认跳过 `book_tombstones` 里的身份与已有 Manga 行，绝不复活 / 重复登记。
///
/// 「检索已下载」在用户显式执行时通过可选项关闭这些跳过：
/// [recover] 的 `reviveTombstoned` 复活并清除墓碑；`existingNonLibraryBookKeys`
/// 把已有非书架行原地提升为书架成员，保留阅读进度、已读、History 与下载映射。
///
/// 模块只增改数据库行，不移动、复制、删除或重命名任何用户文件。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/download_library_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:fushi/src/media/manga/download/download_library_scanner.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 一次磁盘作品恢复的结局计数。
class DownloadMangaRecoveryOutcome {
  const DownloadMangaRecoveryOutcome({
    this.added = 0,
    this.addedOnline = 0,
    this.addedLocal = 0,
    this.addedLocalSourceMissing = 0,
    this.promoted = 0,
    this.revivedTombstones = 0,
    this.skipped = 0,
    this.skippedTombstoned = 0,
    this.chaptersAdded = 0,
    this.chaptersSkipped = 0,
  });

  /// 新登记的 Manga 条目数。
  final int added;

  /// [added] 中建为在线条目的数量（源已安装）。
  final int addedOnline;

  /// [added] 中建为本地条目的数量（无 manifest 或源未安装）。
  final int addedLocal;

  /// [addedLocal] 中因为源未安装而降级的数量。
  final int addedLocalSourceMissing;

  /// 已有非书架行（`membership=false`）被原地提升为书架成员的数目。
  ///
  /// 提升只写 `in_library`，同一行的阅读进度、已读、History 与下载映射原样
  /// 保留，不新建行。
  final int promoted;

  /// 在显式复活模式下重新加入书架、并清除墓碑的作品数。
  final int revivedTombstones;

  /// 因 `book_tombstones`（主动移出书架）而跳过的目录 / 身份数。
  final int skipped;

  /// [skipped] 中因 `book_tombstones`（主动移出书架）而跳过的数量。
  final int skippedTombstoned;

  /// 新登记条目里被写入索引的完整章节数。
  final int chaptersAdded;

  /// 因重复 chapter key 无法安全归属的章节数。
  final int chaptersSkipped;

  /// 合并一个目录里多个作品身份的恢复结果。
  DownloadMangaRecoveryOutcome merge(DownloadMangaRecoveryOutcome other) =>
      DownloadMangaRecoveryOutcome(
        added: added + other.added,
        addedOnline: addedOnline + other.addedOnline,
        addedLocal: addedLocal + other.addedLocal,
        addedLocalSourceMissing:
            addedLocalSourceMissing + other.addedLocalSourceMissing,
        promoted: promoted + other.promoted,
        revivedTombstones: revivedTombstones + other.revivedTombstones,
        skipped: skipped + other.skipped,
        skippedTombstoned: skippedTombstoned + other.skippedTombstoned,
        chaptersAdded: chaptersAdded + other.chaptersAdded,
        chaptersSkipped: chaptersSkipped + other.chaptersSkipped,
      );
}

/// 扩展与在线源都已安装的集合（决定建在线条目还是降级本地条目）。
class DownloadMangaInstalledSources {
  const DownloadMangaInstalledSources({
    required this.extensionPackages,
    required this.sourceIds,
  });

  /// 读取当前数据库里的扩展与在线源安装状态。
  static Future<DownloadMangaInstalledSources> load(
    FushiDatabase database,
  ) async {
    final List<MangaExtensionRow> extensions = await database
        .getMangaExtensions(mediaKind: 'manga');
    final List<MangaOnlineSourceRow> sources = await database
        .getMangaOnlineSources(mediaKind: 'manga');
    return DownloadMangaInstalledSources(
      extensionPackages: <String>{
        for (final MangaExtensionRow row in extensions) row.packageName,
      },
      sourceIds: <String>{
        for (final MangaOnlineSourceRow row in sources)
          _sourceIdentity(row.extensionPackage, row.sourceId),
      },
    );
  }

  final Set<String> extensionPackages;
  final Set<String> sourceIds;

  bool has(String extensionPackage, String sourceId) =>
      extensionPackages.contains(extensionPackage) &&
      sourceIds.contains(_sourceIdentity(extensionPackage, sourceId));
}

/// 把 `downloads/{source}/{manga}` 里尚未入库的作品登记为 Manga。
class DownloadMangaRecovery {
  const DownloadMangaRecovery({
    required this.database,
    required this.downloadsRoot,
  });

  final FushiDatabase database;

  /// 当前 Content root 的 Download library 根；本地降级条目的根也指向它。
  final Directory downloadsRoot;

  /// 恢复一个漫画目录。
  ///
  /// [tombstonedBookKeys]：主动移出书架的作品身份；[existingBookKeys]：已在
  /// 书架的 Manga 行（在线或本地身份）；[existingNonLibraryBookKeys]：已有但
  /// `membership=false` 的行；[skippedOnlineBookKeys]：同身份有多个副本、无法
  /// 安全决定归属的在线身份。默认命中的墓碑 / 已有行都跳过，不重复登记。
  ///
  /// 显式扫描（「检索已下载」）可以传入 [reviveTombstoned] 与
  /// [existingNonLibraryBookKeys]：墓碑作品复活并清除墓碑，非书架行原地提升
  /// 为书架成员（只写 membership，保留阅读进度、已读、History 与下载映射）。
  Future<DownloadMangaRecoveryOutcome> recover(
    DownloadMangaFolderOnDisk folder, {
    required DownloadMangaInstalledSources installedSources,
    Set<String> tombstonedBookKeys = const <String>{},
    Set<String> existingBookKeys = const <String>{},
    Set<String> existingNonLibraryBookKeys = const <String>{},
    Set<String> skippedOnlineBookKeys = const <String>{},
    bool reviveTombstoned = false,
  }) async {
    final Map<String, List<ChapterContainerOnDisk>> groups =
        <String, List<ChapterContainerOnDisk>>{};
    for (final ChapterContainerOnDisk chapter in folder.chapters) {
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest == null) continue;
      final String identity = <String>[
        manifest.sourceRuntime,
        manifest.extensionPackage,
        manifest.sourceId,
        manifest.mangaKey,
      ].join('\u0000');
      groups
          .putIfAbsent(identity, () => <ChapterContainerOnDisk>[])
          .add(chapter);
    }
    final String localBookKey = localSourceBookKeyFor(folder.directory.path);
    final bool localTombstoned = tombstonedBookKeys.contains(localBookKey);

    if (existingBookKeys.contains(localBookKey)) {
      return const DownloadMangaRecoveryOutcome();
    }
    if (existingNonLibraryBookKeys.contains(localBookKey)) {
      // 显式「检索已下载」：同一条记录原地提升，不新建行、不重链章节。
      await database.updateEpubBookInLibrary(localBookKey, inLibrary: true);
      if (localTombstoned) {
        await database.clearBookTombstone(localBookKey);
      }
      return DownloadMangaRecoveryOutcome(
        promoted: 1,
        revivedTombstones: localTombstoned ? 1 : 0,
      );
    }
    // 主动移出书架的作品（在线身份或降级后的本地身份）默认不复活；没有
    // pages.json 的目录也一样——它们可能正是上次降级登记后又被移出的作品。
    if (localTombstoned && !reviveTombstoned) {
      return const DownloadMangaRecoveryOutcome(
        skipped: 1,
        skippedTombstoned: 1,
      );
    }

    int added = 0;
    int addedOnline = 0;
    int addedLocal = 0;
    int addedLocalSourceMissing = 0;
    int promoted = 0;
    int skipped = 0;
    int skippedTombstoned = 0;
    int chaptersAdded = 0;
    int chaptersSkipped = 0;
    final Set<String> revivedKeys = <String>{};
    final Set<String> tombstonesToClear = <String>{};

    if (groups.isEmpty) {
      final DownloadMangaRecoveryOutcome local = await _recoverAsLocal(folder);
      added += local.added;
      addedLocal += local.addedLocal;
      addedLocalSourceMissing += local.addedLocalSourceMissing;
      chaptersAdded += local.chaptersAdded;
      chaptersSkipped += local.chaptersSkipped;
      if (local.added > 0 && localTombstoned) {
        tombstonesToClear.add(localBookKey);
        revivedKeys.add(localBookKey);
      }
      await _clearTombstones(tombstonesToClear);
      return DownloadMangaRecoveryOutcome(
        added: added,
        addedOnline: addedOnline,
        addedLocal: addedLocal,
        addedLocalSourceMissing: addedLocalSourceMissing,
        promoted: promoted,
        revivedTombstones: revivedKeys.length,
        skipped: skipped,
        skippedTombstoned: skippedTombstoned,
        chaptersAdded: chaptersAdded,
        chaptersSkipped: chaptersSkipped,
      );
    }

    // 源未安装的组无法各自建本地条目（本地 bookKey 由目录路径派生，一个目录
    // 只能有一行）；把它们合并成一个只含这些容器的本地条目，至少不丢内容、
    // 也不覆盖已安装身份。
    final List<ChapterContainerOnDisk> uninstalledContainers =
        <ChapterContainerOnDisk>[];
    final Set<String> uninstalledRevivedKeys = <String>{};
    bool folderAddedOrPromoted = false;
    for (final List<ChapterContainerOnDisk> group in groups.values) {
      final MangaPagesManifest manifest = group.first.manifest!;
      final OnlineMangaRuntimeKind? runtime = OnlineMangaRuntimeKind.fromWire(
        manifest.sourceRuntime,
      );
      final String? onlineBookKey = runtime == null
          ? null
          : onlineMangaBookKeyFor(
              runtime: runtime,
              extensionPackage: manifest.extensionPackage,
              sourceId: manifest.sourceId,
              seriesKey: manifest.mangaKey,
            );
      final bool onlineTombstoned =
          onlineBookKey != null && tombstonedBookKeys.contains(onlineBookKey);

      if (onlineBookKey != null && existingBookKeys.contains(onlineBookKey)) {
        continue;
      }
      if (onlineBookKey != null &&
          existingNonLibraryBookKeys.contains(onlineBookKey)) {
        await database.updateEpubBookInLibrary(onlineBookKey, inLibrary: true);
        promoted += 1;
        folderAddedOrPromoted = true;
        if (onlineTombstoned) {
          tombstonesToClear.add(onlineBookKey);
          revivedKeys.add(onlineBookKey);
        }
        continue;
      }
      // 同身份的多个副本无法安全决定归属：跳过该身份，不猜。
      if (onlineBookKey != null &&
          skippedOnlineBookKeys.contains(onlineBookKey)) {
        continue;
      }
      if (onlineTombstoned && !reviveTombstoned) {
        skipped += 1;
        skippedTombstoned += 1;
        continue;
      }

      final bool installed =
          runtime == OnlineMangaRuntimeKind.mihon &&
          installedSources.has(manifest.extensionPackage, manifest.sourceId);
      if (!installed) {
        uninstalledContainers.addAll(group);
        if (onlineBookKey != null && onlineTombstoned) {
          uninstalledRevivedKeys.add(onlineBookKey);
        }
        continue;
      }
      final DownloadMangaRecoveryOutcome online = await _createOnlineEntry(
        folder,
        group,
        runtime!,
      );
      added += online.added;
      addedOnline += online.addedOnline;
      addedLocal += online.addedLocal;
      addedLocalSourceMissing += online.addedLocalSourceMissing;
      chaptersAdded += online.chaptersAdded;
      chaptersSkipped += online.chaptersSkipped;
      if (online.added > 0) {
        folderAddedOrPromoted = true;
        if (onlineTombstoned) {
          tombstonesToClear.add(onlineBookKey);
          revivedKeys.add(onlineBookKey);
        }
      }
    }

    if (uninstalledContainers.isNotEmpty) {
      final MangaPagesManifest first = uninstalledContainers.first.manifest!;
      final DownloadMangaRecoveryOutcome local = await _recoverAsLocal(
        folder,
        onlyCompleteManifestChapters: true,
        title: first.mangaTitle.trim().isEmpty
            ? folder.mangaFolderName
            : first.mangaTitle,
        sourceMissing: true,
        containerNames: <String>{
          for (final ChapterContainerOnDisk chapter in uninstalledContainers)
            chapter.containerName.toLowerCase(),
        },
      );
      added += local.added;
      addedLocal += local.addedLocal;
      addedLocalSourceMissing += local.addedLocalSourceMissing;
      chaptersAdded += local.chaptersAdded;
      chaptersSkipped += local.chaptersSkipped;
      if (local.added > 0) {
        folderAddedOrPromoted = true;
        tombstonesToClear.addAll(uninstalledRevivedKeys);
        revivedKeys.addAll(uninstalledRevivedKeys);
      }
    }

    // 这个目录曾经以「降级本地条目」存在并被主动移出：作品回来后连同旧墓碑
    // 一起清除（与在线身份的墓碑算同一个作品，只计一次复活）。
    if (localTombstoned && reviveTombstoned && folderAddedOrPromoted) {
      tombstonesToClear.add(localBookKey);
      if (revivedKeys.isEmpty) revivedKeys.add(localBookKey);
    }
    await _clearTombstones(tombstonesToClear);

    return DownloadMangaRecoveryOutcome(
      added: added,
      addedOnline: addedOnline,
      addedLocal: addedLocal,
      addedLocalSourceMissing: addedLocalSourceMissing,
      promoted: promoted,
      revivedTombstones: revivedKeys.length,
      skipped: skipped,
      skippedTombstoned: skippedTombstoned,
      chaptersAdded: chaptersAdded,
      chaptersSkipped: chaptersSkipped,
    );
  }

  Future<void> _clearTombstones(Set<String> bookKeys) async {
    for (final String bookKey in bookKeys) {
      await database.clearBookTombstone(bookKey);
    }
  }

  /// 源未安装 / 没有 `pages.json` 时，把下载目录降级为指向该文件夹的本地条目。
  Future<DownloadMangaRecoveryOutcome> _recoverAsLocal(
    DownloadMangaFolderOnDisk folder, {
    bool onlyCompleteManifestChapters = false,
    String? title,
    bool sourceMissing = false,
    Set<String>? containerNames,
  }) async {
    final LocalSourceManga? scanned = await _scanAsLocal(
      folder,
      onlyCompleteManifestChapters: onlyCompleteManifestChapters,
      title: title,
      containerNames: containerNames,
    );
    if (scanned == null) return const DownloadMangaRecoveryOutcome();
    final bool added = await LocalSourceLibrary(
      db: database,
      root: downloadsRoot,
    ).registerScannedManga(scanned);
    if (!added) return const DownloadMangaRecoveryOutcome();
    return DownloadMangaRecoveryOutcome(
      added: 1,
      addedLocal: 1,
      addedLocalSourceMissing: sourceMissing ? 1 : 0,
      chaptersAdded: scanned.chapters.length,
    );
  }

  /// 用图片扫描（`pages.json` 缺失/不可用）把下载漫画目录读成一部本地作品。
  Future<LocalSourceManga?> _scanAsLocal(
    DownloadMangaFolderOnDisk folder, {
    required bool onlyCompleteManifestChapters,
    String? title,
    Set<String>? containerNames,
  }) async {
    final String relativePath = p
        .relative(folder.directory.path, from: downloadsRoot.path)
        .replaceAll('\\', '/');
    final LocalSourceManga? scanned = await scanLocalSourceMangaDirectory(
      folder.directory,
      relativePath: relativePath,
    );
    if (scanned == null) return null;
    if (!onlyCompleteManifestChapters) return scanned;
    final Set<String> completeContainers = <String>{
      for (final ChapterContainerOnDisk chapter in folder.chapters)
        if (chapter.complete && chapter.manifest != null)
          chapter.containerName.toLowerCase(),
    };
    final List<LocalSourceChapter> complete = <LocalSourceChapter>[
      for (final LocalSourceChapter chapter in scanned.chapters)
        if (completeContainers.contains(chapter.relativePath.toLowerCase()) &&
            (containerNames == null ||
                containerNames.contains(chapter.relativePath.toLowerCase())))
          chapter,
    ];
    if (complete.isEmpty) return null;
    return LocalSourceManga(
      title: title ?? scanned.title,
      directoryPath: scanned.directoryPath,
      relativePath: scanned.relativePath,
      chapters: complete,
      coverRelativePath: scanned.coverRelativePath,
    );
  }

  /// 源已安装：按 `pages.json` 的稳定身份创建在线条目，并把完整下载的章写进
  /// `manga_chapter_dirs`（`epub_books.extractDir` 指向漫画目录）。
  Future<DownloadMangaRecoveryOutcome> _createOnlineEntry(
    DownloadMangaFolderOnDisk folder,
    List<ChapterContainerOnDisk> group,
    OnlineMangaRuntimeKind runtime,
  ) async {
    final Map<String, ChapterContainerOnDisk> byKey =
        <String, ChapterContainerOnDisk>{};
    int chaptersSkipped = 0;
    for (final ChapterContainerOnDisk chapter in group) {
      final MangaPagesManifest manifest = chapter.manifest!;
      // 半成品下载不进索引：只有 pages.json + 全部页文件齐全的章才算已下载。
      if (!chapter.complete) continue;
      if (byKey.containsKey(manifest.chapterKey)) {
        chaptersSkipped++;
        continue;
      }
      byKey[manifest.chapterKey] = chapter;
    }
    if (byKey.isEmpty) return const DownloadMangaRecoveryOutcome();

    final MangaPagesManifest first = group.first.manifest!;
    final String title = first.mangaTitle.trim().isEmpty
        ? folder.mangaFolderName
        : first.mangaTitle;
    final List<OnlineMangaChapter> chapters = <OnlineMangaChapter>[
      for (final MapEntry<String, ChapterContainerOnDisk> entry
          in byKey.entries)
        _onlineChapterFromManifest(entry.value.manifest!),
    ];
    final OnlineMangaLibraryEntry libraryEntry = OnlineMangaLibraryEntry(
      runtime: runtime,
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
      series: OnlineMangaSeries(
        key: first.mangaKey,
        title: title,
        raw: <String, Object?>{'url': first.mangaKey, 'title': title},
      ),
      chapters: chapters,
    );
    final String bookKey = onlineMangaBookKeyFor(
      runtime: runtime,
      extensionPackage: first.extensionPackage,
      sourceId: first.sourceId,
      seriesKey: first.mangaKey,
    );
    await database.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        title: title,
        coverPath: Value<String?>(
          _downloadMangaCoverRelative(folder, byKey.values),
        ),
        epubPath: kDownloadPagesFileName,
        extractDir: folder.directory.path,
        chapterCount: chapters.length,
        chaptersJson: jsonEncode(<Map<String, Object?>>[
          for (final OnlineMangaChapter chapter in chapters) chapter.toJson(),
        ]),
        sourceMetadata: Value<String?>(libraryEntry.encode()),
        importedAt: DateTime.now().millisecondsSinceEpoch,
        format: const Value<String>('manga'),
      ),
    );
    for (final MapEntry<String, ChapterContainerOnDisk> entry
        in byKey.entries) {
      await database.upsertMangaChapterDir(
        bookKey: bookKey,
        chapterKey: entry.key,
        folderName: entry.value.containerName,
        containerKind: entry.value.kind,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return DownloadMangaRecoveryOutcome(
      added: 1,
      addedOnline: 1,
      chaptersAdded: byKey.length,
      chaptersSkipped: chaptersSkipped,
    );
  }

  /// `pages.json` → 归一化章节。raw 保留 Mihon 原生章 payload 的最小形状，
  /// 源已安装时仍能按 `url` 拉取未下载的章。
  static OnlineMangaChapter _onlineChapterFromManifest(
    MangaPagesManifest manifest,
  ) {
    final String url = (manifest.chapterUrl ?? '').trim().isEmpty
        ? manifest.chapterKey
        : manifest.chapterUrl!;
    return OnlineMangaChapter(
      key: manifest.chapterKey,
      name: manifest.chapterName,
      scanlator: manifest.scanlator,
      number: manifest.chapterNumber,
      raw: <String, Object?>{
        'url': url,
        'name': manifest.chapterName,
        'date_upload': 0,
        'chapter_number': manifest.chapterNumber ?? 0,
        if (manifest.scanlator != null) 'scanlator': manifest.scanlator,
      },
    );
  }

  /// 在线条目的封面：优先漫画目录里的 `cover.*`，否则取第一张完整下载的页图
  /// （相对漫画目录，与 `ReaderFushiSource.resolveCoverFilePath` 的解析一致）。
  static String? _downloadMangaCoverRelative(
    DownloadMangaFolderOnDisk folder,
    Iterable<ChapterContainerOnDisk> chapters,
  ) {
    for (final String name in const <String>[
      'cover.jpg',
      'cover.jpeg',
      'cover.png',
    ]) {
      if (File(p.join(folder.directory.path, name)).existsSync()) return name;
    }
    for (final ChapterContainerOnDisk chapter in chapters) {
      // 压缩包内的页不是漫画目录下的独立文件，不能当封面相对路径。
      if (chapter.isArchive) continue;
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest == null || manifest.payload.images.isEmpty) continue;
      return p
          .join(chapter.containerName, manifest.payload.images.first.url)
          .replaceAll('\\', '/');
    }
    return null;
  }
}

String _sourceIdentity(String extensionPackage, String sourceId) =>
    '$extensionPackage\u0000$sourceId';
