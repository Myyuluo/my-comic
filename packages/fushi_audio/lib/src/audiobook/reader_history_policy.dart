/// 阅读历史（History）写入策略：普通阅读 vs 无痕阅读。
///
/// 三个阅读器（EPUB / PDF / 漫画）每次落库时用 [forIncognito] 取**一次**策略，
/// 不再各自读偏好、各写一套守卫。策略只决定「写不写 History 的可见信号」，
/// 续读位置（章节 / 页码 / 页内偏移、在线漫画当前章 `updatedAt`）永远照常写：
///
/// - [advanceUpdatedAt]：是否推进 `reader_positions.updatedAt`。它是书架「最近
///   阅读」排序 / 继续阅读 hero / 互联 LWW 的唯一 recency 信号。
/// - [autoMarkChapterRead]：翻到章尾是否自动写 `manga_chapter_states.readAt`
///   （章节已读标记是 History 的可见信号）。
/// - [autoMarkBookCompleted]：是否自动写 `EpubBooks.completedAt`（书级完成标记
///   是 History 的可见信号）。
///
/// 手动「标记已读 / 取消已读」是用户显式动作，不走本策略，始终生效。
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
  /// 「现在」：continue 表面（最近阅读排序 / 继续阅读 hero / 首页「继续」）
  /// 必须把它当「无阅读历史」，不能当成一次新的近期阅读。
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
