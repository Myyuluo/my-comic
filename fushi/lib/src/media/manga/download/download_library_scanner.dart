/// Download library 的磁盘扫描：`downloads/<source>/<manga>/<chapter>`。
///
/// 文件夹复用（[OnlineMangaLibraryService]）、Rebuild download index 与
/// `downloads/<source>` 归属判定共用这一份扫描：目录章节与 `.cbz` 章节都读
/// 包内 `pages.json`，点号目录（`.staging` 等）一律忽略。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/manga/download_library_storage.dart';

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:fushi/src/media/manga/download/download_identity.dart';

/// 磁盘上的一部 Manga 目录及其章节容器（文件夹或 CBZ）。
class DownloadMangaFolderOnDisk {
  const DownloadMangaFolderOnDisk({
    required this.directory,
    required this.chapters,
  });

  final Directory directory;
  final List<ChapterContainerOnDisk> chapters;

  String get mangaFolderName => p.basename(directory.path);
}

/// 扫描整个 Download library 根（`downloads/<source>/<manga>`）。
Future<List<DownloadMangaFolderOnDisk>> scanDownloadLibraryFolders(
  Directory root, {
  bool readComplete = false,
}) async {
  final List<DownloadMangaFolderOnDisk> folders = <DownloadMangaFolderOnDisk>[];
  for (final Directory sourceDir in await listDownloadChildDirectories(root)) {
    folders.addAll(
      await scanDownloadSourceFolders(sourceDir, readComplete: readComplete),
    );
  }
  return folders;
}

/// 扫描一个 `<source>` 目录下的所有 Manga 文件夹。
Future<List<DownloadMangaFolderOnDisk>> scanDownloadSourceFolders(
  Directory sourceDir, {
  bool readComplete = false,
}) async {
  final List<DownloadMangaFolderOnDisk> folders = <DownloadMangaFolderOnDisk>[];
  for (final Directory mangaDir in await listDownloadChildDirectories(
    sourceDir,
  )) {
    folders.add(
      DownloadMangaFolderOnDisk(
        directory: mangaDir,
        chapters: await scanDownloadChapterContainers(
          mangaDir,
          readComplete: readComplete,
        ),
      ),
    );
  }
  return folders;
}

/// 一个 Manga 目录下的章节容器实体：子目录（文件夹章节）与 `.cbz` 文件；
/// 点号条目（`.staging` 等）忽略。按小写名字排序，保证扫描确定。
Future<List<FileSystemEntity>> listDownloadChapterContainers(
  Directory mangaDir,
) async {
  if (!await mangaDir.exists()) return const <FileSystemEntity>[];
  final List<FileSystemEntity> entries = <FileSystemEntity>[];
  try {
    await for (final FileSystemEntity entity in mangaDir.list(
      followLinks: false,
    )) {
      final String name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is Directory ||
          (entity is File && isDownloadChapterArchiveName(name))) {
        entries.add(entity);
      }
    }
  } on FileSystemException {
    return const <FileSystemEntity>[];
  }
  entries.sort(
    (FileSystemEntity a, FileSystemEntity b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()),
  );
  return entries;
}

/// 一个 Manga 目录下的章节容器：子目录（文件夹章节）与 `.cbz` 文件；
/// 点号条目（`.staging` 等）忽略。按小写名字排序，保证扫描确定。
Future<List<ChapterContainerOnDisk>> scanDownloadChapterContainers(
  Directory mangaDir, {
  bool readComplete = false,
}) async {
  final List<ChapterContainerOnDisk> chapters = <ChapterContainerOnDisk>[];
  for (final FileSystemEntity entity in await listDownloadChapterContainers(
    mangaDir,
  )) {
    final String containerName = p.basename(entity.path);
    if (entity is Directory) {
      final MangaPagesManifest? manifest = await readPagesManifest(entity);
      final bool complete = readComplete &&
          manifest != null &&
          await readDownloadLibraryChapterPayload(entity) != null;
      chapters.add(
        ChapterContainerOnDisk.folder(
          containerName: containerName,
          directory: entity,
          manifest: manifest,
          complete: complete,
        ),
      );
    } else if (entity is File) {
      final MangaPagesManifest? manifest =
          await readDownloadLibraryArchiveManifest(entity);
      final bool complete = readComplete &&
          manifest != null &&
          await isDownloadLibraryArchiveComplete(entity);
      chapters.add(
        ChapterContainerOnDisk.archive(
          containerName: containerName,
          archiveFile: entity,
          manifest: manifest,
          complete: complete,
        ),
      );
    }
  }
  return chapters;
}

/// 一个漫画目录里第一个可解析的 `pages.json`（含 `.cbz` 内）。
///
/// Source 级归属只需要一处证据；扫到第一个就停，避免为每个 Manga 读完整章表。
Future<MangaPagesManifest?> readFirstDownloadMangaManifest(
  Directory mangaDir,
) async {
  for (final FileSystemEntity entity
      in await listDownloadChapterContainers(mangaDir)) {
    final MangaPagesManifest? manifest = entity is Directory
        ? await readPagesManifest(entity)
        : await readDownloadLibraryArchiveManifest(entity as File);
    if (manifest != null) return manifest;
  }
  return null;
}

/// 一个 Manga 文件夹的轻量身份探针：只读第一份可解析的 `pages.json`。
///
/// 已下载状态查询会先探测所有文件夹的身份，只有身份匹配的文件夹才去读完整
/// 章表 / 检查完整性，避免为了一个作品扫全库的每一章。
class DownloadMangaFolderProbe {
  const DownloadMangaFolderProbe({required this.directory, this.manifest});

  final Directory directory;
  final MangaPagesManifest? manifest;

  String get mangaFolderName => p.basename(directory.path);
}

/// 探测 `downloads/<source>/<manga>` 下每个 Manga 文件夹的身份。
Future<List<DownloadMangaFolderProbe>> probeDownloadLibraryFolders(
  Directory root,
) async {
  final List<DownloadMangaFolderProbe> probes = <DownloadMangaFolderProbe>[];
  for (final Directory sourceDir in await listDownloadChildDirectories(root)) {
    probes.addAll(await probeDownloadMangaFolders(sourceDir));
  }
  return probes;
}

/// 探测一个目录下直接子目录（Manga 文件夹）的第一份 manifest。
Future<List<DownloadMangaFolderProbe>> probeDownloadMangaFolders(
  Directory parent,
) async {
  final List<DownloadMangaFolderProbe> probes = <DownloadMangaFolderProbe>[];
  for (final Directory mangaDir in await listDownloadChildDirectories(parent)) {
    probes.add(
      DownloadMangaFolderProbe(
        directory: mangaDir,
        manifest: await readFirstDownloadMangaManifest(mangaDir),
      ),
    );
  }
  return probes;
}

/// 探测 Local source 根（`local/<manga>`）的 Manga 文件夹身份。
///
/// 单章作品的 `pages.json` 直接住在 Manga 目录根，因此首个章节容器没有
/// manifest 时再看 Manga 根。
Future<List<DownloadMangaFolderProbe>> probeLocalMangaFolders(
  Directory localRoot,
) async {
  final List<DownloadMangaFolderProbe> probes = <DownloadMangaFolderProbe>[];
  for (final Directory mangaDir in await listDownloadChildDirectories(
    localRoot,
  )) {
    probes.add(
      DownloadMangaFolderProbe(
        directory: mangaDir,
        manifest:
            await readFirstDownloadMangaManifest(mangaDir) ??
            await readPagesManifest(mangaDir),
      ),
    );
  }
  return probes;
}

/// 第一层直接子目录；点号目录（`.staging` 等）忽略。按小写名字排序。
Future<List<Directory>> listDownloadChildDirectories(Directory parent) async {
  if (!await parent.exists()) return const <Directory>[];
  final List<Directory> dirs = <Directory>[];
  try {
    await for (final FileSystemEntity entity in parent.list(
      followLinks: false,
    )) {
      if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
        dirs.add(entity);
      }
    }
  } on FileSystemException {
    return const <Directory>[];
  }
  dirs.sort(
    (Directory a, Directory b) => p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase()),
  );
  return dirs;
}

/// 按 `pages.json` 身份匹配漫画文件夹的结果。
class DownloadMangaFolderIdentityMatch {
  const DownloadMangaFolderIdentityMatch.found(
    DownloadMangaFolderOnDisk this.folder,
  )   : ambiguous = false,
        candidates = const <DownloadMangaFolderOnDisk>[];

  const DownloadMangaFolderIdentityMatch.none()
      : folder = null,
        ambiguous = false,
        candidates = const <DownloadMangaFolderOnDisk>[];

  const DownloadMangaFolderIdentityMatch.ambiguous(this.candidates)
      : folder = null,
        ambiguous = true;

  /// 恰好一个可复用目录。
  final DownloadMangaFolderOnDisk? folder;

  /// 多个目录都匹配：不猜。
  final bool ambiguous;

  /// 歧义候选（报告 / 测试用）。
  final List<DownloadMangaFolderOnDisk> candidates;
}

/// 在 [folders] 里找能由 [identity] 的 `pages.json` 证明的漫画目录。
///
/// 先按核心身份（runtime + 数字 sourceId + seriesKey，占位包容忍）找；
/// 多个都匹配时扩展包做 tie-breaker：恰好一个带相同真实扩展包的目录胜出，
/// 否则视为歧义，一个都不选。
DownloadMangaFolderIdentityMatch matchDownloadMangaFolderByIdentity(
  List<DownloadMangaFolderOnDisk> folders,
  MangaDownloadIdentity identity,
) {
  final List<DownloadMangaFolderOnDisk> matches = <DownloadMangaFolderOnDisk>[
    for (final DownloadMangaFolderOnDisk folder in folders)
      if (folder.chapters.any(
        (ChapterContainerOnDisk chapter) =>
            chapter.manifest != null &&
            identity.matchesManifest(chapter.manifest!),
      ))
        folder,
  ];
  final List<DownloadMangaFolderOnDisk> exact = <DownloadMangaFolderOnDisk>[
    for (final DownloadMangaFolderOnDisk folder in matches)
      if (folder.chapters.any(
        (ChapterContainerOnDisk chapter) =>
            chapter.manifest != null &&
            identity.matchesManifestPackage(chapter.manifest!),
      ))
        folder,
  ];
  if (exact.length == 1) {
    return DownloadMangaFolderIdentityMatch.found(exact.single);
  }
  if (exact.length > 1) {
    return DownloadMangaFolderIdentityMatch.ambiguous(exact);
  }
  if (matches.length == 1) {
    return DownloadMangaFolderIdentityMatch.found(matches.single);
  }
  if (matches.length > 1) {
    return DownloadMangaFolderIdentityMatch.ambiguous(matches);
  }
  return const DownloadMangaFolderIdentityMatch.none();
}
