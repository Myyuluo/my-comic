import 'dart:io';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

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

  /// 数据库删除未移除任何行（或底层删除失败）；作品仍在 Library。
  incomplete,
}

/// 「移出书架」的结局。[failure] 非空 = 作品仍在 Library（文件删除失败或
/// 数据库删除失败），调用方应提示原因；空 = 已从 Library 移除。
class MangaLibraryRemovalResult {
  const MangaLibraryRemovalResult.removed() : failure = null, detail = null;

  const MangaLibraryRemovalResult.failure(this.failure, [this.detail]);

  final MangaLibraryRemovalFailure? failure;

  /// 诊断细节（底层文件删除原因 / 错误信息），只用于日志与附带展示。
  final String? detail;

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

/// 把一部在线或本地 Manga 移出书架。
///
/// 顺序是硬约束：先删本地文件（勾选时），成功后才删数据库条目。文件删除失败时
/// 直接返回失败、**不碰** Library 行——否则会留下「书架里没有、文件还在」的中间
/// 状态。文件本来就不存在视为已删除（[EpubStorage.deleteBookDir] 与
/// [LocalSourceLibrary.deleteOriginalFilesBeforeLibraryRemoval] 都按此处理）。
///
/// 固定删除：Library 条目、Reading progress、Chapter 已读标记、Tag 分配与下载
/// 索引（由 `deleteEpubBook` 事务级联）。History 不删：底层删除以
/// `removeFromLibraryOnly: true` 调用，跳过「整部作品连文件删除」的 History
/// 级联——即使受管漫画卷（无在线 / Local source 描述符）也一样。
///
/// [downloadService] 是停止排队中 / 下载中任务的唯一入口：在线与受管漫画卷的
/// 调用方都传同一个服务，不再各自实现一份停止循环。
Future<MangaLibraryRemovalResult> removeMangaFromLibrary({
  required FushiDatabase db,
  required String bookKey,
  Directory? localSourceRoot,
  bool deleteLocalFiles = false,
  bool deleteStatistics = false,
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

  // 在线 Manga 的排队中 / 下载中任务必须先停：任务还握着作品目录，随后删文件
  // 会撞上仍被 worker 写入的目录；用户移出后也不该继续下载。本地 Manga 没有
  // 下载任务，跳过。用 remove（等正在飞的那个真停）而不是 cancel（只置标志）。
  if (!localSource && downloadService != null) {
    final Map<String, MangaDownloadJobRow> jobs = await downloadService
        .jobsForBook(bookKey);
    for (final MangaDownloadJobRow job in jobs.values) {
      if (job.status == MangaDownloadJobStatus.queued ||
          job.status == MangaDownloadJobStatus.running) {
        await downloadService.remove(job.jobId);
      }
    }
  }

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
    } else {
      try {
        await EpubStorage.deleteBookDir(row.extractDir);
      } on Object catch (error) {
        return MangaLibraryRemovalResult.failure(
          MangaLibraryRemovalFailure.downloadedFilesFailed,
          '$error',
        );
      }
    }
  }

  // 文件已处理完（或不需要处理）才动 DB。removeFromLibraryOnly 让底层只删
  // Library 相关行：文件由本方法负责，History 始终保留。
  final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
    db: db,
    bookKey: bookKey,
    scope: scope,
    deleteLocalFiles: false,
    deleteStatistics: deleteStatistics,
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
