import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/media_item.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart';

/// ticket 04：无痕阅读首次读一本从没读过的书时，`reader_positions` 新行的
/// `updatedAt = 0` 是「没有近期阅读」哨兵（见 `ReaderHistoryPolicy.noRecency`）。
/// 书架的继续阅读 hero 与首页「继续」都不能把它当成一次新的近期阅读——否则这次
/// 无痕阅读会让「继续」多出一张卡 / 换掉 hero，等于留下了历史痕迹。
MediaItem _item(String key) => MediaItem(
  mediaIdentifier: 'fushi://book/$key',
  mediaSourceIdentifier: 'reader',
  title: key,
  mediaTypeIdentifier: 'reader',
  // 在读：0 < position < duration。
  position: 20,
  duration: 100,
  canDelete: false,
  canEdit: true,
);

void main() {
  group('书架继续阅读 hero', () {
    test('updatedAt == 0 的无痕新行不参与选择；没有别的候选就整块隐藏', () {
      final MediaItem incognito = _item('incognito');
      expect(pickShelfContinueHero(<MediaItem>[incognito], (_) => 0), isNull);
      expect(
        pickShelfContinueHero(<MediaItem>[incognito], (_) => null),
        isNull,
      );
    });

    test('有历史记录的在读书仍按最后阅读时间选最大者', () {
      final MediaItem a = _item('a');
      final MediaItem b = _item('b');
      expect(
        pickShelfContinueHero(<MediaItem>[
          a,
          b,
        ], (MediaItem i) => i == a ? 100 : 200),
        b,
        reason: 'BUG-777：hero 选最后阅读时间最大者，而不是列表首位',
      );
    });

    test('无痕新行与有历史记录的书同场：hero 保持原书', () {
      final MediaItem old = _item('old');
      final MediaItem incognito = _item('incognito');
      expect(
        pickShelfContinueHero(<MediaItem>[
          old,
          incognito,
        ], (MediaItem i) => i == incognito ? 0 : 500),
        old,
        reason: '这次无痕阅读不得改变 continue hero',
      );
    });
  });

  group('首页「继续」', () {
    test('updatedAt == 0 的无痕新行不是「继续」条目', () {
      expect(
        isDashboardContinueEntry(_item('incognito'), <String>{}, 0),
        isFalse,
      );
    });

    test('有近期阅读时间且在读 → 「继续」条目', () {
      expect(isDashboardContinueEntry(_item('read'), <String>{}, 100), isTrue);
    });

    test('标了读完的书仍不进入「继续」', () {
      expect(
        isDashboardContinueEntry(_item('done'), <String>{'done'}, 100),
        isFalse,
      );
    });
  });
}
