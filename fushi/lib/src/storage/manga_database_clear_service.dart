import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:fushi_core/fushi_core.dart';

/// 清除数据库的三个阶段；进度框按它显示当前在做什么。
enum MangaDatabaseClearStep { works, history, readingState }

/// 书行按 Library membership 的一次性分流结果。
typedef _LibrarySplit = ({
  Set<String> libraryUids,
  List<String> notInLibraryKeys,
});

/// 待删除（或已删除）的数量。
class MangaDatabaseClearCounts {
  const MangaDatabaseClearCounts({
    required this.works,
    required this.historyEntries,
    required this.readingStateRows,
  });

  /// 不在 Library 中、将被记录级级联删除的作品数。
  final int works;

  /// `media_open_history` 行数（含未入书架作品的 snapshot 行）。
  final int historyEntries;

  /// 无法归属 Library 作品的 Reading progress（`reader_positions`）与
  /// Chapter 已读 / 章级进度（`manga_chapter_states`）行数。包含「不在 Library
  /// 作品名下」与「完全无归属」两类。用户可见文案仍统称为「阅读记录」。
  final int readingStateRows;
}

/// 进度通知：当前阶段与 0..1 的粗略进度。
class MangaDatabaseClearProgress {
  const MangaDatabaseClearProgress({
    required this.step,
    required this.fraction,
  });

  final MangaDatabaseClearStep step;
  final double fraction;
}

/// 设置 →「存储与下载」→「数据存储位置」的「清除数据库」数据层（ticket 13）。
///
/// 删除范围（只删数据库记录，永不触碰磁盘文件）：
/// - 全部 `media_open_history` 行，包括未入书架作品的快照行；
/// - 不在 Library 中的 `epub_books` 行，及其章级状态 / 阅读位置 / 阅读覆盖 /
///   下载任务 / 章节容器映射（复用 [FushiDatabase.deleteEpubBook] 的记录级级联；
///   它不删除任何磁盘文件）；
/// - 无法对应任何 Library 作品的 `reader_positions` / `manga_chapter_states`
///   孤儿行。
///
/// 保留 Library 作品（`in_library = true` 的书架条目）及其 Reading progress、
/// 章节 `readAt`、书级完成标记，也保留 Download library 文件与索引、Local source
/// 目录与文件、设置、源、扩展、搜索历史与 Tracking 数据。
///
/// Library 成员判据与书架同源：`epub_books.in_library`（见
/// `library_membership.dart`）。`format` 只描述书身份，不再表示书架归属。
class MangaDatabaseClearService {
  const MangaDatabaseClearService({
    required this.database,
    @visibleForTesting this.debugBeforeStep,
  });

  final FushiDatabase database;

  /// 测试缝：每个阶段删除前调用；抛错用于验证整个删除在单事务内回滚。
  @visibleForTesting
  final Future<void> Function(MangaDatabaseClearStep step)? debugBeforeStep;

  /// 统计确认框要展示的将删除数量。读取后用户可能取消，所以 [run] 不依赖它。
  Future<MangaDatabaseClearCounts> measure() async {
    final _LibrarySplit split = await _librarySplit();
    return MangaDatabaseClearCounts(
      works: split.notInLibraryKeys.length,
      historyEntries: await _countAll(database.mediaOpenHistory),
      readingStateRows: await _countReadingStateOutsideLibrary(
        split.libraryUids,
      ),
    );
  }

  /// 在**一个事务**里完成三阶段删除；任一阶段失败则全部回滚。
  ///
  /// 返回实际删除的数量（与 [measure] 同口径：事务开始前快照）。
  Future<MangaDatabaseClearCounts> run({
    void Function(MangaDatabaseClearProgress progress)? onProgress,
  }) async {
    final MangaDatabaseClearCounts counts = await database.transaction(
      () async {
        final _LibrarySplit split = await _librarySplit();
        final Set<String> libraryUids = split.libraryUids;
        final int readingStateRows = await _countReadingStateOutsideLibrary(
          libraryUids,
        );

        onProgress?.call(
          const MangaDatabaseClearProgress(
            step: MangaDatabaseClearStep.works,
            fraction: 0.1,
          ),
        );
        await debugBeforeStep?.call(MangaDatabaseClearStep.works);
        int worksDeleted = 0;
        for (final String bookKey in split.notInLibraryKeys) {
          worksDeleted += await database.deleteEpubBook(bookKey);
        }

        onProgress?.call(
          const MangaDatabaseClearProgress(
            step: MangaDatabaseClearStep.history,
            fraction: 0.55,
          ),
        );
        await debugBeforeStep?.call(MangaDatabaseClearStep.history);
        final int historyDeleted = await database
            .delete(database.mediaOpenHistory)
            .go();

        onProgress?.call(
          const MangaDatabaseClearProgress(
            step: MangaDatabaseClearStep.readingState,
            fraction: 0.85,
          ),
        );
        await debugBeforeStep?.call(MangaDatabaseClearStep.readingState);
        await (database.delete(
          database.readerPositions,
        )..where((t) => t.bookUid.isNotIn(libraryUids))).go();
        await (database.delete(
          database.mangaChapterStates,
        )..where((t) => t.bookUid.isNotIn(libraryUids))).go();

        return MangaDatabaseClearCounts(
          works: worksDeleted,
          historyEntries: historyDeleted,
          readingStateRows: readingStateRows,
        );
      },
    );
    return counts;
  }

  /// 一次查询读出全部书行的身份列，按 Library membership（`in_library`）
  /// 分流——书架归属的唯一判据，不再看 `format`。
  Future<_LibrarySplit> _librarySplit() async {
    final List<TypedResult> rows =
        await (database.selectOnly(database.epubBooks)
              ..addColumns(<Expression<Object>>[
                database.epubBooks.bookKey,
                database.epubBooks.uid,
                database.epubBooks.inLibrary,
              ]))
            .get();
    final Set<String> libraryUids = <String>{};
    final List<String> notInLibraryKeys = <String>[];
    for (final TypedResult row in rows) {
      final String? bookKey = row.read(database.epubBooks.bookKey);
      if (bookKey == null) continue;
      if (row.read(database.epubBooks.inLibrary) ?? true) {
        final String? uid = row.read(database.epubBooks.uid);
        if (uid != null && uid.isNotEmpty) libraryUids.add(uid);
      } else {
        notInLibraryKeys.add(bookKey);
      }
    }
    return (libraryUids: libraryUids, notInLibraryKeys: notInLibraryKeys);
  }

  Future<int> _countAll(TableInfo<Table, dynamic> table) async {
    final Expression<int> count = countAll();
    final TypedResult row = await (database.selectOnly(
      table,
    )..addColumns(<Expression<Object>>[count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// 无法归属 Library 作品的阅读状态行数：既包括不在 Library 作品名下的行
  /// （随后由记录级级联删除），也包括完全无归属的孤儿行。统计的是 Reading
  /// progress（`reader_positions`）与 Chapter 已读 / 章级进度
  /// （`manga_chapter_states`）两类行，不是「阅读次数」。
  Future<int> _countReadingStateOutsideLibrary(Set<String> libraryUids) async {
    // 两张表同形（`book_uid` 是归属键），各自用自己表的列构造谓词。
    final Expression<int> positionCount = countAll();
    final TypedResult positions =
        await (database.selectOnly(database.readerPositions)
              ..addColumns(<Expression<Object>>[positionCount])
              ..where(database.readerPositions.bookUid.isNotIn(libraryUids)))
            .getSingle();
    final Expression<int> stateCount = countAll();
    final TypedResult states =
        await (database.selectOnly(database.mangaChapterStates)
              ..addColumns(<Expression<Object>>[stateCount])
              ..where(database.mangaChapterStates.bookUid.isNotIn(libraryUids)))
            .getSingle();
    return (positions.read(positionCount) ?? 0) +
        (states.read(stateCount) ?? 0);
  }
}
