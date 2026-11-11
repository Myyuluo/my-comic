/// Mihon 备份交换用的 tracking 词表（provider / 媒体类型 / 追踪种类 / 进度模式）。
///
/// 原住在 `media/tracking/media_tracking_repository.dart`（追踪域）。我的漫画只保留
/// Mihon Backup 的导入/导出兼容面（`.tachibk` 里的 tracking 行仍按原词表读写），
/// 追踪服务与 Bangumi 同步已删除。这里只留稳定的字符串枚举，值不可改——它们直接
/// 落 `media_tracking_mappings` / `media_tracking_outbox` 表并与 Mihon 备份互认。
library;

const String kTrackingProviderBangumi = 'bangumi';

enum TrackingMediaType {
  book('book'),
  bookChapter('book_chapter'),
  video('video'),
  videoCollection('video_collection'),
  game('game');

  const TrackingMediaType(this.value);
  final String value;
}

enum TrackingKind {
  anime('anime'),
  novel('novel'),
  manga('manga'),
  game('game');

  const TrackingKind(this.value);
  final String value;
}

enum TrackingProgressMode {
  episode('episode'),
  chapter('chapter'),
  volume('volume'),

  /// 只同步收藏状态，没有话数/卷数进度。
  status('status');

  const TrackingProgressMode(this.value);
  final String value;

  static TrackingProgressMode? tryParse(String value) {
    for (final TrackingProgressMode mode in TrackingProgressMode.values) {
      if (mode.value == value) return mode;
    }
    return null;
  }
}
