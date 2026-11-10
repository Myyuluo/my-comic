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
    this.rootManifest,
  });

  final Directory directory;
  final List<ChapterContainerOnDisk> chapters;

  /// 单章 Local source 作品把 `pages.json` 直接放在漫画目录根时的 manifest。
  ///
  /// 它不是章节容器：不能写进 `manga_chapter_dirs`（`<manga>/<manga>` 路径
  /// 不存在），但可以证明目录身份，并让 manifest 扫描把这一章算作已下载。
  final MangaPagesManifest? rootManifest;

  String get mangaFolderName => p.basename(directory.path);

  /// 目录里能证明身份的所有 manifest（章节容器 + 单章根 manifest）。
  Iterable<MangaPagesManifest> get manifests sync* {
    final MangaPagesManifest? root = rootManifest;
    if (root != null) yield root;
    for (final ChapterContainerOnDisk chapter in chapters) {
      final MangaPagesManifest? manifest = chapter.manifest;
      if (manifest != null) yield manifest;
    }
  }
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
    final List<ChapterContainerOnDisk> chapters =
        await scanDownloadChapterContainers(
          mangaDir,
          readComplete: readComplete,
        );
    // 单章作品把 pages.json 直接放在漫画目录根，没有章容器（ticket 06）：
    // 只有在这种裸目录里才读根 manifest，正常下载目录保持零额外读盘。
    final MangaPagesManifest? rootManifest = chapters.isEmpty
        ? await readPagesManifest(mangaDir)
        : null;
    folders.add(
      DownloadMangaFolderOnDisk(
        directory: mangaDir,
        chapters: chapters,
        rootManifest: rootManifest,
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
      final bool complete =
          readComplete &&
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
      final bool complete =
          readComplete &&
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
  for (final FileSystemEntity entity in await listDownloadChapterContainers(
    mangaDir,
  )) {
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
  const DownloadMangaFolderProbe({
    required this.directory,
    this.manifest,
    this.additionalManifests = const <MangaPagesManifest>[],
    this.manifestAtMangaRoot = false,
  });

  final Directory directory;
  final MangaPagesManifest? manifest;

  /// 共享目录里为其他同名作品继续读到的 manifest（不含 [manifest]）。
  ///
  /// 只有查询带标题、且第一份 manifest 属于同一标题的**另一部**作品时才非空；
  /// 普通单作品目录仍是零额外读盘。
  final List<MangaPagesManifest> additionalManifests;

  /// 目录里读到的全部 manifest（第一份 + [additionalManifests]）。
  Iterable<MangaPagesManifest> get manifests sync* {
    final MangaPagesManifest? first = manifest;
    if (first != null) yield first;
    yield* additionalManifests;
  }

  /// [manifest] 是否来自漫画目录根的 `pages.json`（单章 Local source 作品）。
  ///
  /// 根 manifest 只能证明目录身份；它不是一个可用的章容器。
  final bool manifestAtMangaRoot;

  String get mangaFolderName => p.basename(directory.path);

  /// 把探针结果转成共享匹配器使用的目录描述。
  ///
  /// 普通章节 manifest 合成为一个轻量容器参与身份匹配；根 manifest 放进
  /// [DownloadMangaFolderOnDisk.rootManifest]，绝不伪造成名为漫画目录的章容器
  /// （那样会写出不可用的 `<manga>/<manga>` 映射）。
  DownloadMangaFolderOnDisk toFolder() {
    final List<MangaPagesManifest> all = manifests.toList(growable: false);
    if (all.isEmpty) {
      return DownloadMangaFolderOnDisk(
        directory: directory,
        chapters: const <ChapterContainerOnDisk>[],
      );
    }
    if (manifestAtMangaRoot) {
      return DownloadMangaFolderOnDisk(
        directory: directory,
        chapters: const <ChapterContainerOnDisk>[],
        rootManifest: all.first,
      );
    }
    return DownloadMangaFolderOnDisk(
      directory: directory,
      chapters: <ChapterContainerOnDisk>[
        for (int index = 0; index < all.length; index++)
          ChapterContainerOnDisk.folder(
            // 合成容器只是身份证据，名字不参与真磁盘映射。
            containerName: index == 0
                ? mangaFolderName
                : '$mangaFolderName#${all[index].chapterKey}',
            directory: directory,
            manifest: all[index],
          ),
      ],
    );
  }
}

/// 探测 `downloads/<source>/<manga>` 下每个 Manga 文件夹的身份。
///
/// [queries] 非空时按「同 Source 同标题可共享目录」补读 manifest：第一份
/// manifest 属于另一部同名作品时继续读该目录，直到找到查询身份或目录读完。
/// 没有同名疑点时仍只读第一份 manifest。
Future<List<DownloadMangaFolderProbe>> probeDownloadLibraryFolders(
  Directory root, {
  List<MangaDownloadDiskQuery> queries = const <MangaDownloadDiskQuery>[],
}) async {
  final List<DownloadMangaFolderProbe> probes = <DownloadMangaFolderProbe>[];
  for (final Directory sourceDir in await listDownloadChildDirectories(root)) {
    probes.addAll(await probeDownloadMangaFolders(sourceDir, queries: queries));
  }
  return probes;
}

/// 探测一个目录下直接子目录（Manga 文件夹）的 manifest 身份证据。
///
/// 见 [probeDownloadLibraryFolders]：普通目录只读第一份 manifest；共享目录
/// （同名作品）按 [queries] 的需要继续读。
Future<List<DownloadMangaFolderProbe>> probeDownloadMangaFolders(
  Directory parent, {
  List<MangaDownloadDiskQuery> queries = const <MangaDownloadDiskQuery>[],
}) async {
  final List<DownloadMangaFolderProbe> probes = <DownloadMangaFolderProbe>[];
  for (final Directory mangaDir in await listDownloadChildDirectories(parent)) {
    probes.add(await _probeDownloadMangaFolder(mangaDir, queries));
  }
  return probes;
}

/// 读一个 Manga 文件夹的 manifest 身份证据。
///
/// 只读到「够用」为止：没有查询时只读第一份（保持旧的低成本探测）；有查询时
/// 若第一份 manifest 是同一标题的另一部作品，就继续读，因为共享目录里本作品
/// 的容器可能排在后面。标题不同则说明不是共享目录，停止。
Future<DownloadMangaFolderProbe> _probeDownloadMangaFolder(
  Directory mangaDir,
  List<MangaDownloadDiskQuery> queries,
) async {
  final List<MangaPagesManifest> found = <MangaPagesManifest>[];
  for (final FileSystemEntity entity in await listDownloadChapterContainers(
    mangaDir,
  )) {
    final MangaPagesManifest? manifest = entity is Directory
        ? await readPagesManifest(entity)
        : await readDownloadLibraryArchiveManifest(entity as File);
    if (manifest == null) continue;
    found.add(manifest);
    if (!_probeNeedsMoreManifests(queries, found)) break;
  }
  if (found.isEmpty) {
    // 单章作品把 pages.json 直接放在漫画目录根（ticket 06）：章节容器里没有
    // manifest 时，根 manifest 仍能证明目录身份。
    final MangaPagesManifest? rootManifest = await readPagesManifest(mangaDir);
    return DownloadMangaFolderProbe(
      directory: mangaDir,
      manifest: rootManifest,
      manifestAtMangaRoot: rootManifest != null,
    );
  }
  return DownloadMangaFolderProbe(
    directory: mangaDir,
    manifest: found.first,
    additionalManifests: found.skip(1).toList(growable: false),
  );
}

/// [found] 是否还不足以回答 [queries]，需要继续读同一目录的 manifest。
///
/// 继续的唯一理由：某个查询身份还没被证明，而目录里已出现的 manifest 标题与
/// 该查询标题完全相同——共享目录只发生在同标题作品之间。不同标题目录直接
/// 判定「没有」。
bool _probeNeedsMoreManifests(
  List<MangaDownloadDiskQuery> queries,
  List<MangaPagesManifest> found,
) {
  if (queries.isEmpty) return false;
  final Set<String> foundTitles = <String>{
    for (final MangaPagesManifest manifest in found) manifest.mangaTitle.trim(),
  };
  for (final MangaDownloadDiskQuery query in queries) {
    if (found.any(query.identity.matchesManifest)) continue;
    if (foundTitles.contains(query.title.trim())) return true;
  }
  return false;
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
    final MangaPagesManifest? chapterManifest =
        await readFirstDownloadMangaManifest(mangaDir);
    if (chapterManifest != null) {
      probes.add(
        DownloadMangaFolderProbe(
          directory: mangaDir,
          manifest: chapterManifest,
        ),
      );
      continue;
    }
    final MangaPagesManifest? rootManifest = await readPagesManifest(mangaDir);
    probes.add(
      DownloadMangaFolderProbe(
        directory: mangaDir,
        manifest: rootManifest,
        manifestAtMangaRoot: rootManifest != null,
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
    DownloadMangaFolderOnDisk this.folder, {
    this.matches = const <DownloadMangaFolderOnDisk>[],
  }) : ambiguous = false,
       candidates = const <DownloadMangaFolderOnDisk>[];

  const DownloadMangaFolderIdentityMatch.none()
    : folder = null,
      ambiguous = false,
      candidates = const <DownloadMangaFolderOnDisk>[],
      matches = const <DownloadMangaFolderOnDisk>[];

  const DownloadMangaFolderIdentityMatch.ambiguous(this.candidates)
    : folder = null,
      ambiguous = true,
      matches = candidates;

  /// 恰好一个可复用目录。
  final DownloadMangaFolderOnDisk? folder;

  /// 多个目录都匹配：不猜。
  final bool ambiguous;

  /// 歧义候选（报告 / 测试用）。
  final List<DownloadMangaFolderOnDisk> candidates;

  /// 所有核心身份匹配的目录（包括被扩展包 tie-breaker 淘汰的重复副本）。
  ///
  /// Rebuild download index 用它把未采用的重复副本排除在 orphan recovery 之外。
  final List<DownloadMangaFolderOnDisk> matches;
}

/// [folders] 里所有能由 `pages.json` 证明属于 [identity] 的漫画目录。
///
/// 核心身份 = runtime + 数字 sourceId + seriesKey（占位扩展包容忍）；返回值
/// 不做扩展包 tie-breaker，供 Rebuild download index 评估重复副本。
List<DownloadMangaFolderOnDisk> matchingDownloadMangaFolders(
  List<DownloadMangaFolderOnDisk> folders,
  MangaDownloadIdentity identity,
) => <DownloadMangaFolderOnDisk>[
  for (final DownloadMangaFolderOnDisk folder in folders)
    if (_folderManifests(folder).any(identity.matchesManifest)) folder,
];

/// 目录里能证明身份的所有 manifest（章节容器 + 单章根 manifest）。
Iterable<MangaPagesManifest> _folderManifests(
  DownloadMangaFolderOnDisk folder,
) => folder.manifests;

/// 在 [folders] 里找能由 [identity] 的 `pages.json` 证明的漫画目录。
///
/// 先按核心身份（runtime + 数字 sourceId + seriesKey，占位包容忍）找；
/// 多个都匹配时扩展包做 tie-breaker：恰好一个带相同真实扩展包的目录胜出，
/// 否则视为歧义，一个都不选。
DownloadMangaFolderIdentityMatch matchDownloadMangaFolderByIdentity(
  List<DownloadMangaFolderOnDisk> folders,
  MangaDownloadIdentity identity,
) {
  final List<DownloadMangaFolderOnDisk> matches = matchingDownloadMangaFolders(
    folders,
    identity,
  );
  final List<DownloadMangaFolderOnDisk> exact = <DownloadMangaFolderOnDisk>[
    for (final DownloadMangaFolderOnDisk folder in matches)
      if (_folderManifests(folder).any(identity.matchesManifestPackage)) folder,
  ];
  if (exact.length == 1) {
    return DownloadMangaFolderIdentityMatch.found(
      exact.single,
      matches: matches,
    );
  }
  if (exact.length > 1) {
    return DownloadMangaFolderIdentityMatch.ambiguous(exact);
  }
  if (matches.length == 1) {
    return DownloadMangaFolderIdentityMatch.found(
      matches.single,
      matches: matches,
    );
  }
  if (matches.length > 1) {
    return DownloadMangaFolderIdentityMatch.ambiguous(matches);
  }
  return const DownloadMangaFolderIdentityMatch.none();
}
