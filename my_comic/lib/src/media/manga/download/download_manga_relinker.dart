/// 把一个磁盘漫画目录重新关联到在线 Manga 条目。
///
/// 文件夹复用（[OnlineMangaLibraryService]）与 Rebuild download index 共用
/// 这一份 re-link：`pages.json` 稳定身份优先，已有映射与容器名回退兜底；
/// 每个章 key 最多映射一个容器，多个候选视为歧义并跳过。只增改
/// `manga_chapter_dirs` 与 `epub_books.extract_dir`，绝不删除或重命名文件。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:my_comic_core/my_comic_core.dart';
import 'package:my_comic_engine/media/manga/download_library_storage.dart';

import 'package:my_comic/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:my_comic/src/media/manga/download/download_identity.dart';
import 'package:my_comic/src/media/manga/download/download_library_scanner.dart';
import 'package:my_comic/src/media/manga/library/online_manga_library_entry.dart';

/// 一次 re-link 的结果计数。
class DownloadMangaRelinkResult {
  const DownloadMangaRelinkResult({
    this.extractDirChanged = false,
    this.chaptersRelinked = 0,
    this.chaptersMissing = 0,
    this.chaptersSkipped = 0,
    this.cancelled = false,
  });

  /// `epub_books.extract_dir` 被重指向该漫画目录。
  final bool extractDirChanged;

  /// 新增或更新的 `manga_chapter_dirs` 行数。
  final int chaptersRelinked;

  /// 下载索引认为已下载、但目录里找不到容器的章数。
  final int chaptersMissing;

  /// 多候选 / 多 manifest 无法安全关联的章数。
  final int chaptersSkipped;

  /// 用户中途取消（已写下的映射保留，下一次幂等重跑会补齐）。
  final bool cancelled;

  bool get relinked => extractDirChanged || chaptersRelinked > 0;
}

/// 用 [mangaFolder] 里的章节容器重建 [row] 的章节映射。
///
/// [indexedChapterKeys] 是「下载索引曾认为已下载」的章集合（已有映射或 done
/// 任务）；只有这些章找不到容器时才算 Missing，从未下载的章不计入。
/// [chapters] 可传入已扫描结果避免重复读盘。
Future<DownloadMangaRelinkResult> relinkDownloadMangaFolder({
  required MyComicDatabase database,
  required EpubBookRow row,
  required OnlineMangaLibraryEntry entry,
  required Directory mangaFolder,
  List<ChapterContainerOnDisk>? chapters,
  Set<String> indexedChapterKeys = const <String>{},
  bool Function()? isCancelled,
}) async {
  final List<ChapterContainerOnDisk> containers =
      chapters ?? await scanDownloadChapterContainers(mangaFolder);
  final MangaDownloadIdentity identity = MangaDownloadIdentity.ofEntry(entry);
  final Map<String, MangaChapterDirRow> existingMappings =
      await database.getMangaChapterDirRowsForBook(row.bookKey);

  bool extractDirChanged = false;
  if (!_samePath(row.extractDir, mangaFolder.path)) {
    await database.updateEpubBookContentPaths(
      row.bookKey,
      extractDir: mangaFolder.path,
    );
    extractDirChanged = true;
  }

  // 1) pages.json 稳定 ID 优先。
  final Map<String, List<ChapterContainerOnDisk>> idCandidates =
      <String, List<ChapterContainerOnDisk>>{};
  for (final ChapterContainerOnDisk diskChapter in containers) {
    final MangaPagesManifest? manifest = diskChapter.manifest;
    if (manifest == null) continue;
    if (!identity.matchesManifest(manifest)) continue;
    final int chapterIndex = entry.indexOfChapterKey(manifest.chapterKey);
    if (chapterIndex < 0) continue;
    idCandidates
        .putIfAbsent(manifest.chapterKey, () => <ChapterContainerOnDisk>[])
        .add(diskChapter);
  }
  final Map<String, ChapterContainerOnDisk> byId =
      <String, ChapterContainerOnDisk>{};
  final Set<String> ambiguousIds = <String>{};
  for (final MapEntry<String, List<ChapterContainerOnDisk>> item
      in idCandidates.entries) {
    if (item.value.length == 1) {
      byId[item.key] = item.value.single;
    } else {
      ambiguousIds.add(item.key);
    }
  }
  final Set<String> idClaimedContainerNames = <String>{
    for (final ChapterContainerOnDisk container in byId.values)
      container.containerName.toLowerCase(),
  };
  // 共享目录里被 `pages.json` 证明属于**另一部作品**的容器：名称回退绝不能
  // 把它们认成本作品的章，否则同 Title 的两部作品会互相串章节。
  final Set<String> foreignContainerNames = <String>{
    for (final ChapterContainerOnDisk container in containers)
      if (container.manifest != null &&
          !identity.matchesManifest(container.manifest!))
        container.containerName.toLowerCase(),
  };
  // 目录里出现另一部作品的 manifest = 这是一个共享目录。无 manifest 的容器
  // 在共享目录里没有可证明的归属：名称对同 Title 的每部作品都成立，不能猜给
  // 任何一方（否则删除 A 会连带删掉 B 映射的同一个容器）。
  final bool folderIsShared = foreignContainerNames.isNotEmpty;
  bool ownershipProvable(ChapterContainerOnDisk container) =>
      container.manifest != null || !folderIsShared;

  final Map<String, ChapterContainerOnDisk> existingContainers =
      <String, ChapterContainerOnDisk>{
    for (final ChapterContainerOnDisk chapter in containers)
      chapter.containerName.toLowerCase(): chapter,
  };

  final Map<String, ChapterContainerOnDisk> matches =
      <String, ChapterContainerOnDisk>{...byId};
  final Set<String> usedContainerNames = <String>{...idClaimedContainerNames};
  int chaptersMissing = 0;
  int chaptersSkipped = ambiguousIds.length;
  for (final OnlineMangaChapter chapter in entry.chapters) {
    if (isCancelled?.call() ?? false) {
      // 取消只停在这一章之前；已写下的 extractDir 保留，映射在循环后统一落库，
      // 因此这里不需要回滚任何东西（下一次幂等重跑会补齐）。
      return DownloadMangaRelinkResult(
        extractDirChanged: extractDirChanged,
        chaptersMissing: chaptersMissing,
        chaptersSkipped: chaptersSkipped,
        cancelled: true,
      );
    }
    if (matches.containsKey(chapter.key)) continue;
    if (ambiguousIds.contains(chapter.key)) continue;

    // 2a) 已有映射（应用自己写下的名称映射）仍指向本漫画目录里的容器。
    final String? mappedName = existingMappings[chapter.key]?.folderName;
    ChapterContainerOnDisk? candidate;
    if (mappedName != null) {
      final ChapterContainerOnDisk? mapped =
          existingContainers[mappedName.toLowerCase()];
      if (mapped != null) {
        final String mappedName = mapped.containerName.toLowerCase();
        final bool claimedByOther =
            idClaimedContainerNames.contains(mappedName) ||
            foreignContainerNames.contains(mappedName);
        if (!claimedByOther && ownershipProvable(mapped)) candidate = mapped;
      }
    }

    // 2b) 没有可用映射时按容器名回退（无稳定身份 / pages.json 丢失）。
    if (candidate == null) {
      final List<ChapterContainerOnDisk> nameCandidates = containers
          .where(
            (ChapterContainerOnDisk item) =>
                !usedContainerNames.contains(
                  item.containerName.toLowerCase(),
                ) &&
                !foreignContainerNames.contains(
                  item.containerName.toLowerCase(),
                ) &&
                ownershipProvable(item) &&
                _chapterContainerNameMatches(item.containerName, chapter),
          )
          .toList();
      if (nameCandidates.length == 1) {
        candidate = nameCandidates.single;
      } else if (nameCandidates.length > 1) {
        final List<ChapterContainerOnDisk> completeCandidates = nameCandidates
            .where((ChapterContainerOnDisk item) => item.complete)
            .toList();
        if (completeCandidates.length == 1) {
          candidate = completeCandidates.single;
        } else {
          chaptersSkipped++;
          continue;
        }
      }
    }

    if (candidate != null) {
      matches[chapter.key] = candidate;
      usedContainerNames.add(candidate.containerName.toLowerCase());
    } else {
      // 只有「下载索引认为已下载」的章才算 Missing；从未下载的章不是缺失。
      if (indexedChapterKeys.contains(chapter.key)) chaptersMissing++;
      // 映射指向的目录已被 pages.json 证明属于别的章：原样保留这条映射，不删除。
    }
  }

  int chaptersRelinked = 0;
  for (final MapEntry<String, ChapterContainerOnDisk> match
      in matches.entries) {
    final MangaChapterDirRow? previous = existingMappings[match.key];
    if (previous != null &&
        previous.folderName == match.value.containerName &&
        previous.containerKindEnum == match.value.kind) {
      continue;
    }
    await database.upsertMangaChapterDir(
      bookKey: row.bookKey,
      chapterKey: match.key,
      folderName: match.value.containerName,
      containerKind: match.value.kind,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    chaptersRelinked++;
  }
  return DownloadMangaRelinkResult(
    extractDirChanged: extractDirChanged,
    chaptersRelinked: chaptersRelinked,
    chaptersMissing: chaptersMissing,
    chaptersSkipped: chaptersSkipped,
  );
}

/// 容器名是否像这一章的展示名。
///
/// 只用于 `pages.json` 缺稳定身份时的兜底：比较净化后的章名；允许下载器在重名 /
/// 同扫译组时追加的 `[扫译组]`、旧 ` (2)` 序号，以及新命名的 `~<8 位哈希>` 后缀
/// （见 `uniqueDownloadChapterName`）。CBZ 容器名先去掉 `.cbz` 扩展名再比。
/// 大小写不敏感（Windows 语义）。
bool _chapterContainerNameMatches(
  String containerName,
  OnlineMangaChapter chapter,
) {
  final String rawName =
      chapter.name.trim().isEmpty ? chapter.key : chapter.name;
  final String base = sanitizeDownloadLibrarySegment(rawName).toLowerCase();
  final String lower = (isDownloadChapterArchiveName(containerName)
          ? p.basenameWithoutExtension(containerName)
          : containerName)
      .toLowerCase();
  if (lower == base) return true;
  final String scanlator = chapter.scanlator?.trim() ?? '';
  if (scanlator.isNotEmpty) {
    final String qualifier = sanitizeDownloadLibrarySegment(
      scanlator,
      maxLength: 32,
    ).toLowerCase();
    if (lower == '$base [$qualifier]') return true;
  }
  return RegExp(
    '^${RegExp.escape(base)}(?: \\[.+\\])?(?: \\(\\d+\\)|~[0-9a-f]{8})\$',
  ).hasMatch(lower);
}

bool _samePath(String a, String b) =>
    p.equals(p.canonicalize(a), p.canonicalize(b));
