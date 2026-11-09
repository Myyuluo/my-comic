import 'dart:io';

import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/local_source/local_source_library.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';

/// 「移出书架」的结局。[failureReason] 非空 = 作品仍在 Library（文件删除失败或
/// 数据库删除失败），调用方应提示原因；空 = 已从 Library 移除。
class MangaLibraryRemovalResult {
  const MangaLibraryRemovalResult.removed() : failureReason = null;

  const MangaLibraryRemovalResult.failure(this.failureReason);

  final String? failureReason;

  bool get removed => failureReason == null;
}

/// 把一部在线或本地 Manga 移出书架。
///
/// 顺序是硬约束：先删本地文件（勾选时），成功后才删数据库条目。文件删除失败时
/// 直接返回失败、**不碰** Library 行——否则会留下「书架里没有、文件还在」的中间
/// 状态。文件本来就不存在视为已删除（[EpubStorage.deleteBookDir] 与
/// [LocalSourceLibrary.deleteOriginalFilesBeforeLibraryRemoval] 都按此处理）。
///
/// 固定删除：Library 条目、Reading progress、Chapter 已读标记、Tag 分配与下载
/// 索引（由 `deleteEpubBook` 事务级联）。History 不删：这里始终以
/// `deleteLocalFiles: false` 调底层删除，避开「整部作品连文件删除」同时清历史的
/// 旧路径。
Future<MangaLibraryRemovalResult> removeMangaFromLibrary({
  required FushiDatabase db,
  required String bookKey,
  Directory? localSourceRoot,
  bool deleteLocalFiles = false,
  bool deleteStatistics = false,
  DeleteScope scope = DeleteScope.keepLocalOnly,
}) async {
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) {
    return const MangaLibraryRemovalResult.failure('找不到这本书的数据');
  }
  final bool localSource =
      LocalSourceMetadata.tryParse(row.sourceMetadata) != null;

  if (deleteLocalFiles) {
    if (localSource) {
      if (localSourceRoot == null) {
        return const MangaLibraryRemovalResult.failure('无法定位 Local source 根目录');
      }
      try {
        final LocalSourceDeleteResult files = await LocalSourceLibrary(
          db: db,
          root: localSourceRoot,
        ).deleteOriginalFilesBeforeLibraryRemoval(bookKey);
        if (!files.deleted) {
          return MangaLibraryRemovalResult.failure(
            '无法删除本地文件（${files.reason.name}）',
          );
        }
      } on Object catch (error) {
        return MangaLibraryRemovalResult.failure('无法删除本地文件：$error');
      }
    } else {
      try {
        await EpubStorage.deleteBookDir(row.extractDir);
      } on Object catch (error) {
        return MangaLibraryRemovalResult.failure('无法删除已下载章节文件：$error');
      }
    }
  }

  // 文件已处理完（或不需要处理）才动 DB。deleteLocalFiles 恒为 false：文件已经
  // 在本方法里删过，且底层 true 分支会连 History 一起清掉。
  final DeleteBookResult result = await ReaderFushiSource.instance.deleteBook(
    db: db,
    bookKey: bookKey,
    scope: scope,
    deleteLocalFiles: false,
    deleteStatistics: deleteStatistics,
  );
  if (!result.deleted) {
    return MangaLibraryRemovalResult.failure(
      result.failureReason ?? '删除未移除任何数据',
    );
  }
  return const MangaLibraryRemovalResult.removed();
}
