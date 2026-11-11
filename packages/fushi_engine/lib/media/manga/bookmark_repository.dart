import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

/// 书签模型与持久化。
///
/// 原住在 `fushi_audio`（有声书域）。漫画阅读器的书签功能仍在使用，独立化时抽到
/// 引擎漫画域，JSON/DB 语义保持不变（遗留偏好键 `bookmarks_<bookKey>` 冻结）。
class Bookmark {
  // json 键名 'bookKey' 是遗留偏好的 wire 面貌，冻结不改；v82 起值语义为书
  // 稳定 uid（遗留 json 里的旧 bookKey 值在迁移落库时被调用方传入的 uid 覆盖）。
  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
    id: json['id'] as int?,
    sectionIndex: json['sectionIndex'] as int,
    normCharOffset: json['normCharOffset'] as int,
    label: json['label'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    bookUid: json['bookKey'] as String?,
    bookTitle: json['bookTitle'] as String?,
    pageInChapter: json['pageInChapter'] as int?,
    totalPagesInChapter: json['totalPagesInChapter'] as int?,
  );
  Bookmark({
    required this.sectionIndex,
    required this.normCharOffset,
    required this.label,
    required this.createdAt,
    this.id,
    this.bookUid,
    this.bookTitle,
    this.pageInChapter,
    this.totalPagesInChapter,
    this.charAnchor,
    this.charAnchorLength,
    this.preserveSavedPosition = false,
  });

  factory Bookmark.fromRow(BookmarkRow row) => Bookmark(
    id: row.id,
    sectionIndex: row.sectionIndex,
    normCharOffset: row.normCharOffset,
    label: row.label,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    bookUid: row.bookUid,
    bookTitle: row.bookTitle,
    pageInChapter: row.pageInChapter,
    totalPagesInChapter: row.totalPagesInChapter,
  );

  final int? id;
  final int sectionIndex;

  /// 真实书签（[BookmarkRow]）的 `normCharOffset` 是 `(progress*10000).round()` 的
  /// 0-10000 章内进度分数。这是持久化语义，跳转端按分数 `/10000` 还原。
  final int normCharOffset;
  final String label;
  final DateTime createdAt;

  /// 书稳定身份（v82 起 = EpubBooks.uid；非 epub 域沿用其既有稳定键）。
  final String? bookUid;
  final String? bookTitle;
  final int? pageInChapter;
  final int? totalPagesInChapter;

  /// BUG-459：临时跳转用的「章节内绝对可匹配字符索引」（`getNormalizedOffset`
  /// 口径，0..数千），与阅读器 `_initialCharOffset` / `ReaderPosition.charOffset`
  /// 同计量。**仅内存传输用，不持久化**（[fromRow]/[fromJson] 不读它）。
  final int? charAnchor;

  /// BUG-461：收藏句的「章节内可匹配字符长度」（`getNormalizedOffset` 口径）。
  /// **仅内存传输用，不持久化**；null/0 时退回单点句首锚（旧行为）。
  final int? charAnchorLength;

  /// BUG-459：本次跳转是否为「临时浏览跳转」——true 时阅读器进入后**不覆盖**该书
  /// 已保存的 [ReaderPosition]。
  final bool preserveSavedPosition;

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'sectionIndex': sectionIndex,
    'normCharOffset': normCharOffset,
    'label': label,
    'createdAt': createdAt.toIso8601String(),
    if (bookUid != null) 'bookKey': bookUid,
    if (bookTitle != null) 'bookTitle': bookTitle,
    if (pageInChapter != null) 'pageInChapter': pageInChapter,
    if (totalPagesInChapter != null) 'totalPagesInChapter': totalPagesInChapter,
  };
}

class BookmarkRepository {
  BookmarkRepository(this._db);

  final FushiDatabase _db;

  // 遗留偏好键空间冻结在旧 bookKey（`bookmarks_<bookKey>`），与 DB 键（v82 起
  // uid）解耦：迁移需要调用方显式给 legacyBookKey，其余路径纯 uid。
  String _key(String legacyBookKey) => 'bookmarks_$legacyBookKey';

  Future<List<Bookmark>> getBookmarks(
    String bookUid, {
    String? legacyBookKey,
  }) async {
    if (legacyBookKey != null) {
      await _migrateLegacyBookmarks(bookUid, legacyBookKey);
    }
    final rows =
        await (_db.select(_db.bookmarks)
              ..where((tbl) => tbl.bookUid.equals(bookUid))
              ..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)]))
            .get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<int> addBookmark(String bookUid, Bookmark bookmark) async {
    return _db
        .into(_db.bookmarks)
        .insert(
          BookmarksCompanion.insert(
            bookUid: bookUid,
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            label: bookmark.label,
            createdAt: bookmark.createdAt.millisecondsSinceEpoch,
            bookTitle: Value(bookmark.bookTitle),
            pageInChapter: Value(bookmark.pageInChapter),
            totalPagesInChapter: Value(bookmark.totalPagesInChapter),
          ),
        );
  }

  Future<void> removeBookmarkById(int id) async {
    await (_db.delete(_db.bookmarks)..where((tbl) => tbl.id.equals(id))).go();
  }

  /// 清空全部书签（所有书籍）。
  Future<void> clearAllBookmarks() async {
    await _db.delete(_db.bookmarks).go();
  }

  Future<void> removeBookmark(String bookUid, int index) async {
    final bookmarks = await getBookmarks(bookUid);
    if (index < 0 || index >= bookmarks.length) return;
    final int? id = bookmarks[index].id;
    if (id == null) return;
    await removeBookmarkById(id);
  }

  Future<void> removeBookmarkMatching(
    String bookUid, {
    required int sectionIndex,
    required int normCharOffset,
    required DateTime createdAt,
  }) async {
    await (_db.delete(_db.bookmarks)..where(
          (tbl) =>
              tbl.bookUid.equals(bookUid) &
              tbl.sectionIndex.equals(sectionIndex) &
              tbl.normCharOffset.equals(normCharOffset) &
              tbl.createdAt.equals(createdAt.millisecondsSinceEpoch),
        ))
        .go();
  }

  Future<void> _migrateLegacyBookmarks(
    String bookUid,
    String legacyBookKey,
  ) async {
    final raw = await _db.getPref(_key(legacyBookKey));
    if (raw == null || raw.isEmpty) return;
    final existing =
        await (_db.selectOnly(_db.bookmarks)
              ..where(_db.bookmarks.bookUid.equals(bookUid))
              ..addColumns([_db.bookmarks.id.count()]))
            .map((row) => row.read(_db.bookmarks.id.count()) ?? 0)
            .getSingle();
    if (existing == 0) {
      final List<dynamic> list;
      try {
        list = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        await _db.deletePref(_key(legacyBookKey));
        return;
      }
      for (final dynamic e in list) {
        if (e is! Map<String, dynamic>) continue;
        final bookmark = Bookmark.fromJson(e);
        await addBookmark(
          bookUid,
          Bookmark(
            sectionIndex: bookmark.sectionIndex,
            normCharOffset: bookmark.normCharOffset,
            label: bookmark.label,
            createdAt: bookmark.createdAt,
            // 遗留 json 里的旧 bookKey 值不落库——DB 键统一为传入的 uid。
            bookUid: bookUid,
            pageInChapter: bookmark.pageInChapter,
            totalPagesInChapter: bookmark.totalPagesInChapter,
            bookTitle: bookmark.bookTitle,
          ),
        );
      }
    }
    await _db.deletePref(_key(legacyBookKey));
  }

  Future<List<Bookmark>> getAllBookmarks() async {
    await _db.migrateLegacyBookmarkPreferences();
    final rows = await (_db.select(
      _db.bookmarks,
    )..orderBy([(tbl) => OrderingTerm.desc(tbl.createdAt)])).get();
    return rows.map(Bookmark.fromRow).toList();
  }

  Future<void> importLegacyBookmark(String bookUid, Bookmark bookmark) async {
    await addBookmark(bookUid, bookmark);
  }
}
