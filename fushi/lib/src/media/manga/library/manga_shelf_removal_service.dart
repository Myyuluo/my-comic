import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_layout.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/storage/app_paths.dart';

/// 移出书架失败的原因。
///
/// 服务层只给出可判定的原因与诊断细节；面向用户的文案由 [failureMessage]
/// 通过 Slang 渲染，页面不再拼接中文字符串。
enum MangaLibraryRemovalFailure {
  /// Library 里找不到这本书（可能已被其他入口删除）。
  bookNotFound,

  /// 勾选删除 Local source 原作，但当前环境无法解析 Local source 根目录。
  localSourceRootUnavailable,

  /// 删除 Local source 原作失败；[MangaLibraryRemovalResult.detail] 带底层原因。
  localFilesFailed,

  /// 删除已下载章节文件失败；[MangaLibraryRemovalResult.detail] 带底层错误。
  downloadedFilesFailed,

  /// 数据库写入未生效（或底层删除失败）；作品仍在 Library。
  incomplete,
}

/// 「移出书架」的结局。[failure] 非空 = 作品仍在 Library（文件删除失败或
/// 数据库写入失败），调用方应提示原因；空 = 已从 Library 移除。
class MangaLibraryRemovalResult {
  const MangaLibraryRemovalResult.removed([this.row])
    : failure = null,
      detail = null;

  const MangaLibraryRemovalResult.failure(this.failure, [this.detail])
    : row = null;

  final MangaLibraryRemovalFailure? failure;

  /// 诊断细节（底层文件删除原因 / 错误信息），只用于日志与附带展示。
  final String? detail;

  /// 移出后仍保留的 Manga 行（非破坏移出）。null = 行已随文件一起删除
  /// （Local source / 受管本地卷勾选「同时删除本地文件」）。
  final EpubBookRow? row;

  bool get removed => failure == null;

  /// 已本地化的失败说明；[removed] 为 true 时是空字符串。
  String get failureMessage => switch (failure) {
    null => '',
    MangaLibraryRemovalFailure.bookNotFound => t.manga_removal_book_not_found,
    MangaLibraryRemovalFailure.localSourceRootUnavailable =>
      t.manga_removal_local_source_root_unavailable,
    MangaLibraryRemovalFailure.localFilesFailed =>
      t.manga_removal_local_files_failed(detail: detail ?? ''),
    MangaLibraryRemovalFailure.downloadedFilesFailed =>
      t.manga_removal_downloaded_files_failed(detail: detail ?? ''),
    MangaLibraryRemovalFailure.incomplete => t.manga_removal_incomplete(
      detail: detail ?? '',
    ),
  };
}

/// 把一部在线或本地 Manga 移出书架（manga-library-membership 票 04）。
///
/// 非破坏语义：默认只把 Library membership 置 false 并移除 Tag 分配与订阅 /
/// 自动追更标志；Manga/Chapter 行、阅读进度、已读标记、下载任务、章目录映射、
/// 下载文件夹与 History 全部保留。重新加入时复用同一条记录与同一个文件夹。
///
/// 两个可选动作只在勾选时生效：
/// - 在线作品勾选「同时删除本地文件」：删除 Download library 里的已下载文件与
///   下载索引（任务 + 章目录映射），但**保留非书架行与阅读状态**，之后可重新
///   下载。文件删除失败时直接返回失败、**不碰** membership——否则会留下
///   「书架里没有、文件还在」的中间状态。只有 `extractDir` 能证明位于当前
///   Download library 根（`downloads`）内时才删文件；重建/导入可能把在线行
///   关联到 `local` 里带 `pages.json` 的原作目录，那些文件绝不删除，跳过删
///   文件与下载索引后仍按非破坏语义移出书架。
/// - 本地作品（Local source / 受管本地卷）勾选「同时删除本地文件」：删除原作
///   文件后连 Manga 行与阅读/已读/下载状态一起删除（不留下指向已删除文件的
///   孤儿）；History 仍保留。文件删除失败时作品留在 Library。
/// History 始终保留：行删除路径也以 `removeFromLibraryOnly: true` 调底层，
/// 跳过「整部作品连文件删除」的 History 级联。
///
/// [downloadService] 只用于「删文件」路径：先停排队中 / 下载中任务（它们握着
/// 作品目录，且随后任务行会被清掉）。默认移出保留下载任务，不打断非书架下载。
Future<MangaLibraryRemovalResult> removeMangaFromLibrary({
  required FushiDatabase db,
  required String bookKey,
  Directory? localSourceRoot,
  Directory? downloadsRoot,
  bool deleteLocalFiles = false,
  DeleteScope scope = DeleteScope.keepLocalOnly,
  MangaDownloadService? downloadService,
}) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) {
    return const MangaLibraryRemovalResult.failure(
      MangaLibraryRemovalFailure.bookNotFound,
    );
  }
  final bool localSource =
      LocalSourceMetadata.tryParse(row.sourceMetadata) != null;
  final OnlineMangaLibraryEntry? onlineEntry = localSource
      ? null
      : OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
  // 受管本地卷（导入卷 / PDF 转漫画）：既不是 Local source，也没有在线描述符。
  // 它的 extractDir 是应用管理的副本，和 Local source 一样属于「本地作品」。
  final bool managedLocalVolume = !localSource && onlineEntry == null;
  final bool deletesRow =
      deleteLocalFiles && (localSource || managedLocalVolume);

  if (deleteLocalFiles) {
    if (localSource) {
      if (localSourceRoot == null) {
        return const MangaLibraryRemovalResult.failure(
          MangaLibraryRemovalFailure.localSourceRootUnavailable,
        );
      }
      try {
        final LocalSourceDeleteResult files = await LocalSourceLibrary(
          db: db,
          root: localSourceRoot,
        ).deleteOriginalFilesBeforeLibraryRemoval(bookKey);
        if (!files.deleted) {
          return MangaLibraryRemovalResult.failure(
            MangaLibraryRemovalFailure.localFilesFailed,
            files.reason.name,
          );
        }
      } on Object catch (error) {
        return MangaLibraryRemovalResult.failure(
          MangaLibraryRemovalFailure.localFilesFailed,
          '$error',
        );
      }
    } else if (managedLocalVolume ||
        (row.extractDir.isNotEmpty &&
            isLocalSourcePathWithinRoot(
              row.extractDir,
              await _resolveDownloadsRoot(downloadsRoot),
            ))) {
      // 在线 / 受管本地卷：先停正在写这个目录的任务，再删文件。
      //
      // 在线行只有在 `extractDir` 能证明位于当前 Download library 根内时才
      // 走这里。Ticket 12 允许把在线行关联到 `local` 里带 `pages.json` 的
      // 目录；那些是用户的原作文件，绝不是可删的下载副本，因此落到下面的
      // else 分支跳过删除（行与阅读状态照常保留，仅移出书架）。
      if (downloadService != null) {
        final Map<String, MangaDownloadJobRow> jobs = await downloadService
            .jobsForBook(bookKey);
        for (final MangaDownloadJobRow job in jobs.values) {
          if (job.status == MangaDownloadJobStatus.queued ||
              job.status == MangaDownloadJobStatus.running) {
            await downloadService.remove(job.jobId);
          }
        }
      }
      try {
        await EpubStorage.deleteBookDir(row.extractDir);
      } on Object catch (error) {
        return MangaLibraryRemovalResult.failure(
          MangaLibraryRemovalFailure.downloadedFilesFailed,
          '$error',
        );
      }
      // 文件已删：任务与章目录映射指向不存在的文件，必须一并清掉，否则 worker
      // 会重新下载、详情页也会显示旧的已下载状态。非书架行本身保留。
      await db.deleteMangaDownloadJobsForBook(bookKey);
      await db.deleteMangaChapterDirsForBook(bookKey);
    } else {
      // 在线行的 `extractDir` 指向 `local` 或其他非 Download library 位置
      // （重建/导入按 manifest 身份关联过）。不删文件、也不清下载索引，避免
      // 误删 Local source 原作或留下「记录说已删除、文件还在」的假象。
    }
  }

  if (deletesRow) {
    // 本地作品连行删除：走既有删除路径（级联章节状态 / 进度 / 任务 / 映射 /
    // Tag，并写 tombstone）。文件已由本方法处理，History 始终保留。
    final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
      db: db,
      bookKey: bookKey,
      scope: scope,
      deleteLocalFiles: false,
      removeFromLibraryOnly: true,
    );
    if (!result.deleted) {
      return MangaLibraryRemovalResult.failure(
        MangaLibraryRemovalFailure.incomplete,
        result.failureReason ?? '',
      );
    }
    return const MangaLibraryRemovalResult.removed();
  }

  // 非破坏移出：只清书架归属与书架专属状态。
  await db.deleteTagAssignmentsForHost(TagHostKind.epub, bookKey);
  if (onlineEntry != null) {
    // 订阅 / 自动追更只属于 Library：移出时把两位写回 false，避免描述符里留着
    // 已失效的书架专属状态。
    final OnlineMangaLibraryEntry cleared = onlineEntry.copyWith(
      subscribed: false,
      autoDownload: false,
    );
    if (cleared.subscribed != onlineEntry.subscribed ||
        cleared.autoDownload != onlineEntry.autoDownload) {
      await db.updateEpubBookMihonState(
        bookKey,
        sourceMetadata: cleared.encode(),
        chapterCount: row.chapterCount,
        chaptersJson: row.chaptersJson,
      );
    }
  }
  final int updated = await db.updateEpubBookInLibrary(
    bookKey,
    inLibrary: false,
  );
  if (updated == 0) {
    return const MangaLibraryRemovalResult.failure(
      MangaLibraryRemovalFailure.incomplete,
      'membership update removed no rows',
    );
  }
  return MangaLibraryRemovalResult.removed(await db.getEpubBook(bookKey));
}

/// 「删除本地文件」只能删当前 Download library 内的文件。
///
/// 与 `DownloadLibraryIndex` 同一条根解析：显式注入优先；测试壳里
/// `EpubStorage` 根的同级 `downloads` 与 Download library 一致；生产回落
/// AppPaths 的 Content root。
Future<Directory> _resolveDownloadsRoot(Directory? injected) async {
  if (injected != null) return injected;
  final String? bookBase = EpubStorage.debugBaseDirectoryOverridePath;
  if (bookBase != null && bookBase.isNotEmpty) {
    return Directory(p.join(p.dirname(bookBase), 'downloads'));
  }
  return AppPaths.downloadsRootDirectory();
}
