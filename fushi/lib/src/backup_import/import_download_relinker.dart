/// `.tachibk` 导入后的窄范围下载重链（ticket 11）。
///
/// 只处理本次导入/合并成功的 Manga 行：用共享的 `pages.json` 身份判据在
/// `downloads` 与带 manifest 的 `local` 里找到唯一对应目录，再交给共享的
/// [relinkDownloadMangaFolder] 写 `extractDir` 与 `manga_chapter_dirs`。
///
/// 不扫描 `autobackup`、不补建 Library 条目、不删除/重命名任何文件；多个目录
/// 能证明同一身份时报告 skipped 而不是猜一个。全量重建仍是 ticket 12 的入口。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/manga/download/chapter_container_on_disk.dart';
import 'package:fushi/src/media/manga/download/download_identity.dart';
import 'package:fushi/src/media/manga/download/download_library_scanner.dart';
import 'package:fushi/src/media/manga/download/download_manga_relinker.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 导入后自动下载匹配的计数。
class ImportDownloadRelinkReport {
  const ImportDownloadRelinkReport({
    this.mangaMatched = 0,
    this.mangaSkipped = 0,
    this.chaptersRelinked = 0,
    this.chaptersSkipped = 0,
  });

  /// 唯一匹配到磁盘目录、并已执行 re-link 的导入 Manga 数。
  final int mangaMatched;

  /// 多个目录都能证明同一身份（不猜）或匹配过程失败的 Manga 数。
  final int mangaSkipped;

  /// 新增或更新的 `manga_chapter_dirs` 行数。
  final int chaptersRelinked;

  /// 匹配到的目录内部因歧义没有写映射的章节数。
  final int chaptersSkipped;
}

/// 对 [bookKeys] 对应的在线 Manga 行执行一次窄范围下载匹配。
///
/// 两个根都可为 null（测试壳 / 未解析 Content root）：null 的根不扫描。
Future<ImportDownloadRelinkReport> relinkImportedMangaDownloads({
  required FushiDatabase database,
  required Iterable<String> bookKeys,
  Directory? downloadsRoot,
  Directory? localComicRoot,
}) async {
  final Set<String> wanted = bookKeys.toSet();
  // A synchronous preflight keeps the common "nothing downloaded yet" import
  // free of async disk I/O (and avoids scanning two empty roots). Only roots
  // with at least one child directory can contain a match.
  final bool scanDownloads =
      downloadsRoot != null && _hasChildDirectory(downloadsRoot);
  final bool scanLocal =
      localComicRoot != null && _hasChildDirectory(localComicRoot);
  if (wanted.isEmpty || (!scanDownloads && !scanLocal)) {
    return const ImportDownloadRelinkReport();
  }

  final List<DownloadMangaFolderOnDisk> downloadFolders = !scanDownloads
      ? const <DownloadMangaFolderOnDisk>[]
      : _probeFolders(await probeDownloadLibraryFolders(downloadsRoot));
  final List<DownloadMangaFolderOnDisk> localFolders = !scanLocal
      ? const <DownloadMangaFolderOnDisk>[]
      : _probeFolders(await probeLocalMangaFolders(localComicRoot));

  int mangaMatched = 0;
  int mangaSkipped = 0;
  int chaptersRelinked = 0;
  int chaptersSkipped = 0;

  for (final String bookKey in wanted) {
    final EpubBookRow? row = await database.getEpubBook(bookKey);
    if (row == null) continue;
    final OnlineMangaLibraryEntry? entry = OnlineMangaLibraryEntry.tryParse(
      row.sourceMetadata,
    );
    if (entry == null) continue;

    final MangaDownloadIdentity identity = MangaDownloadIdentity.ofEntry(entry);
    DownloadMangaFolderIdentityMatch match = matchDownloadMangaFolderByIdentity(
      downloadFolders,
      identity,
    );
    Directory? folder = match.folder?.directory;
    if (folder == null && !match.ambiguous) {
      final DownloadMangaFolderIdentityMatch localMatch =
          matchDownloadMangaFolderByIdentity(localFolders, identity);
      folder = localMatch.folder?.directory;
      if (folder == null && localMatch.ambiguous) match = localMatch;
    }
    if (folder == null) {
      // 没有目录 = 未下载，不是 skip；只有「有候选但无法安全决定」才报告。
      if (match.ambiguous) mangaSkipped++;
      continue;
    }

    try {
      final Map<String, MangaChapterDirRow> existing = await database
          .getMangaChapterDirRowsForBook(bookKey);
      final DownloadMangaRelinkResult result = await relinkDownloadMangaFolder(
        database: database,
        row: row,
        entry: entry,
        mangaFolder: folder,
        chapters: await scanDownloadChapterContainers(folder),
        indexedChapterKeys: existing.keys.toSet(),
      );
      mangaMatched++;
      chaptersRelinked += result.chaptersRelinked;
      chaptersSkipped += result.chaptersSkipped;
    } on Object {
      mangaSkipped++;
    }
  }

  return ImportDownloadRelinkReport(
    mangaMatched: mangaMatched,
    mangaSkipped: mangaSkipped,
    chaptersRelinked: chaptersRelinked,
    chaptersSkipped: chaptersSkipped,
  );
}

/// 根下是否至少有一个非点号子目录（`downloads/<source>` / `local/<manga>`）。
/// 读盘失败按「没有」处理：匹配本来就是尽力而为，导入结果不受影响。
bool _hasChildDirectory(Directory root) {
  try {
    if (!root.existsSync()) return false;
    return root
        .listSync(followLinks: false)
        .any(
          (FileSystemEntity entity) =>
              entity is Directory && !p.basename(entity.path).startsWith('.'),
        );
  } on FileSystemException {
    return false;
  }
}

/// 探针只用于身份匹配：一个带 manifest 的合成容器即可让共享匹配器判断目录
/// 归属；真正写映射前再扫描该目录的完整章表。
List<DownloadMangaFolderOnDisk> _probeFolders(
  List<DownloadMangaFolderProbe> probes,
) => <DownloadMangaFolderOnDisk>[
  for (final DownloadMangaFolderProbe probe in probes)
    if (probe.manifest != null)
      DownloadMangaFolderOnDisk(
        directory: probe.directory,
        chapters: <ChapterContainerOnDisk>[
          ChapterContainerOnDisk.folder(
            containerName: probe.mangaFolderName,
            directory: probe.directory,
            manifest: probe.manifest,
          ),
        ],
      ),
];
