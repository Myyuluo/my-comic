import 'package:drift/drift.dart';
import 'package:my_comic_core/my_comic_core.dart';

/// Reader 上次阅读位置 —— 漫画阅读器与（已删除的）书籍阅读器共用同一张
/// `reader_positions` 表。位置用 `(sectionIndex, normCharOffset)`：
/// `normCharOffset` 是 **章内** 的归一化字符偏移（0-10000 分数基准）。
///
/// 原住在 `my_comic_audio`（有声书域）。漫画阅读器 / 书架 / 历史 / 删除链路都依赖它，
/// 独立化时抽到引擎漫画域，类名与落库语义保持不变。
class ReaderPosition {
  int? id;

  /// 书稳定身份（v82 起 = EpubBooks.uid；非 epub 域沿用其既有稳定键），按书一条。
  late String bookUid;

  /// 章节 index（0-based）。
  late int sectionIndex;

  /// 章内归一化字符偏移（0-10000 分数基准）。`0` = 章首。
  late int normCharOffset;

  /// BUG-162: section 内精确绝对字符偏移（恢复锚）。`null` = 无精确偏移
  /// （恢复回退 normCharOffset 分数）。退出再进用它做「存→取」不动点。
  int? charOffset;

  /// 更新时间戳（ms since epoch）。
  late int updatedAt;
}

/// 阅读历史（History）写入策略：普通阅读 vs 无痕阅读。
///
/// 策略只决定「写不写 History 的可见信号」，续读位置永远照常写：
///
/// - [advanceUpdatedAt]：是否推进 `reader_positions.updatedAt`。它是书架「最近
///   阅读」排序 / 继续阅读 hero 的唯一 recency 信号。
/// - [autoMarkChapterRead]：翻到章尾是否自动写 `manga_chapter_states.readAt`。
/// - [autoMarkBookCompleted]：是否自动写 `EpubBooks.completedAt`。
class ReaderHistoryPolicy {
  const ReaderHistoryPolicy._({
    required this.advanceUpdatedAt,
    required this.autoMarkChapterRead,
    required this.autoMarkBookCompleted,
  });

  /// 普通阅读：所有 History 信号照常写（默认，零行为变化）。
  static const ReaderHistoryPolicy recording = ReaderHistoryPolicy._(
    advanceUpdatedAt: true,
    autoMarkChapterRead: true,
    autoMarkBookCompleted: true,
  );

  /// 无痕阅读：只保留续读位置，History 的可见信号全部不新增。
  static const ReaderHistoryPolicy incognito = ReaderHistoryPolicy._(
    advanceUpdatedAt: false,
    autoMarkChapterRead: false,
    autoMarkBookCompleted: false,
  );

  /// 按开关值取策略。调用方在**每次落库时**现取，开关切换后立即生效。
  static ReaderHistoryPolicy forIncognito(bool incognito) =>
      incognito ? ReaderHistoryPolicy.incognito : ReaderHistoryPolicy.recording;

  /// `reader_positions.updatedAt` 的「没有阅读历史」哨兵。
  ///
  /// 无痕阅读首次读一本从没读过的书时，没有旧时间戳可冻结，新行写它而不是
  /// 「现在」：continue 表面必须把它当「无阅读历史」，不能当成一次新的近期阅读。
  static const int noRecency = 0;

  /// [at] 是否是一次**可用的**阅读时间戳（哨兵 0 / 缺失都不算）。
  static bool hasRecency(int? at) => at != null && at > noRecency;

  /// 下一次落库应写的 `reader_positions.updatedAt`：普通阅读写 [now]；无痕
  /// 冻结已有行的旧值，新行用 [noRecency] 哨兵。
  int updatedAtFor({required int? existing, required int now}) =>
      advanceUpdatedAt ? now : existing ?? noRecency;

  /// 是否推进 `reader_positions.updatedAt`（false = 无痕冻结 recency）。
  final bool advanceUpdatedAt;

  /// 是否自动写章节已读标记（`manga_chapter_states.readAt`）。
  final bool autoMarkChapterRead;

  /// 是否自动写书级完成标记（`EpubBooks.completedAt`）。
  final bool autoMarkBookCompleted;
}

/// 阅读位置持久化。键为书稳定身份（v82 起 = EpubBooks.uid；非 epub 域沿用其
/// 既有稳定键）。
class ReaderPositionRepository {
  const ReaderPositionRepository(this._db);

  final MyComicDatabase _db;

  Future<ReaderPosition?> findByBookUid(String bookUid) async {
    final ReaderPositionRow? row = await _db.getReaderPosition(bookUid);
    if (row == null) return null;
    return _rowToModel(row);
  }

  /// 全部阅读位置按 bookUid 建表（书架列书一次取完，替代每本一查的 N+1）。
  Future<Map<String, ReaderPosition>> findAllByBookUid() async {
    final List<ReaderPositionRow> rows = await _db.getAllReaderPositions();
    return <String, ReaderPosition>{
      for (final ReaderPositionRow row in rows) row.bookUid: _rowToModel(row),
    };
  }

  /// 写入一次阅读位置。
  ///
  /// [history] 决定 `reader_positions.updatedAt`（History 的 recency 信号：
  /// 书架「最近阅读」排序 / 继续阅读 hero）怎么写：普通阅读每次刷新；无痕阅读
  /// 冻结已有行的旧值，新行写 [ReaderHistoryPolicy.noRecency] 哨兵（不是「现在」），
  /// 不冒充「刚读过」。位置字段本身照常写入。默认
  /// [ReaderHistoryPolicy.recording] = 现有行为。
  Future<void> save({
    required String bookUid,
    required int sectionIndex,
    required int normCharOffset,
    int? charOffset,
    ReaderHistoryPolicy history = ReaderHistoryPolicy.recording,
  }) async {
    final ReaderPositionRow? existing =
        (!history.advanceUpdatedAt || charOffset == null)
        ? await _db.getReaderPosition(bookUid)
        : null;
    // 精确锚（char_offset）与分数（norm_char_offset）是同一位置的两套坐标，
    // 恢复时精确锚优先。精确锚绝不能比分数陈旧：同 section 无新精确锚时，仅当
    // 位置未移动才保留旧锚；一旦分数变化，旧锚置 -1 失效。
    final Value<int> charOffsetValue;
    if (charOffset != null) {
      charOffsetValue = Value(charOffset);
    } else if (existing == null || existing.sectionIndex != sectionIndex) {
      charOffsetValue = const Value(-1);
    } else if (existing.normCharOffset != normCharOffset) {
      charOffsetValue = const Value(-1);
    } else {
      charOffsetValue = const Value.absent();
    }
    await _db.upsertReaderPosition(
      ReaderPositionsCompanion(
        bookUid: Value(bookUid),
        sectionIndex: Value(sectionIndex),
        normCharOffset: Value(normCharOffset),
        charOffset: charOffsetValue,
        updatedAt: Value(
          history.updatedAtFor(
            existing: existing?.updatedAt,
            now: DateTime.now().millisecondsSinceEpoch,
          ),
        ),
      ),
    );
  }

  Future<void> delete(String bookUid) => _db.deleteReaderPosition(bookUid);

  static ReaderPosition _rowToModel(ReaderPositionRow r) {
    final ReaderPosition pos = ReaderPosition();
    pos.id = r.id;
    pos.bookUid = r.bookUid;
    pos.sectionIndex = r.sectionIndex;
    pos.normCharOffset = r.normCharOffset;
    pos.charOffset = r.charOffset >= 0 ? r.charOffset : null;
    pos.updatedAt = r.updatedAt;
    return pos;
  }
}
