import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';

// BUG-3001：阅读器实时 hook（按钮布局 / 反转底栏 / 样式 / 排版热更新）是
// ReaderMyComicSource 上的静态回调。旧实现每个阅读器页 dispose 时无条件置 null；
// 切卷走 pushReplacement，新页 initState 先登记、旧页转场结束才 dispose，于是
// 仍在显示的新阅读器的 hook 被抹掉——之后在书内设置里改按钮位置，偏好写进去了
// 阅读器却不重建，退出重进才生效。现在按持有者栈登记 / 注销，hook 恒指向栈顶。
void main() {
  final List<String> calls = <String>[];

  ReaderLiveHooks hooksOf(String owner) => ReaderLiveHooks(
    settingsChanged: () => calls.add('$owner.settings'),
    layoutReload: () => calls.add('$owner.layout'),
    chromeReload: () => calls.add('$owner.chrome'),
    chromeReanchor: () => calls.add('$owner.reanchor'),
  );

  void fireAll() {
    ReaderMyComicSource.onSettingsChangedLive?.call();
    ReaderMyComicSource.onLayoutReloadLive?.call();
    ReaderMyComicSource.onChromeReloadLive?.call();
    ReaderMyComicSource.onChromeReanchorLive?.call();
  }

  setUp(calls.clear);

  tearDown(() {
    expect(
      ReaderMyComicSource.debugLiveHookOwnerCount,
      0,
      reason: '每个用例都应注销干净，否则静态 hook 泄漏到别的用例',
    );
  });

  test('切卷：新页先登记、旧页后注销，hook 仍指向新页', () {
    final ReaderLiveHooks oldPage = hooksOf('old');
    final ReaderLiveHooks newPage = hooksOf('new');
    ReaderMyComicSource.attachLiveHooks(oldPage);
    ReaderMyComicSource.attachLiveHooks(newPage);
    ReaderMyComicSource.detachLiveHooks(oldPage);

    fireAll();
    expect(calls, <String>[
      'new.settings',
      'new.layout',
      'new.chrome',
      'new.reanchor',
    ]);

    ReaderMyComicSource.detachLiveHooks(newPage);
    expect(ReaderMyComicSource.onChromeReanchorLive, isNull);
    expect(ReaderMyComicSource.onChromeReloadLive, isNull);
    expect(ReaderMyComicSource.onSettingsChangedLive, isNull);
    expect(ReaderMyComicSource.onLayoutReloadLive, isNull);
  });

  test('叠开阅读器：上层关闭后 hook 回落到下层阅读器', () {
    final ReaderLiveHooks lower = hooksOf('lower');
    final ReaderLiveHooks upper = hooksOf('upper');
    ReaderMyComicSource.attachLiveHooks(lower);
    ReaderMyComicSource.attachLiveHooks(upper);

    ReaderMyComicSource.onChromeReanchorLive?.call();
    ReaderMyComicSource.detachLiveHooks(upper);
    ReaderMyComicSource.onChromeReanchorLive?.call();
    expect(calls, <String>['upper.reanchor', 'lower.reanchor']);

    ReaderMyComicSource.detachLiveHooks(lower);
    expect(ReaderMyComicSource.onChromeReanchorLive, isNull);
  });

  test('单个阅读器：注销后四个 hook 都置空', () {
    final ReaderLiveHooks only = hooksOf('only');
    ReaderMyComicSource.attachLiveHooks(only);
    fireAll();
    expect(calls, hasLength(4));
    ReaderMyComicSource.detachLiveHooks(only);
    calls.clear();
    fireAll();
    expect(calls, isEmpty);
  });

  test('重复注销同一组是无害的', () {
    final ReaderLiveHooks a = hooksOf('a');
    final ReaderLiveHooks b = hooksOf('b');
    ReaderMyComicSource.attachLiveHooks(a);
    ReaderMyComicSource.attachLiveHooks(b);
    ReaderMyComicSource.detachLiveHooks(a);
    ReaderMyComicSource.detachLiveHooks(a);
    ReaderMyComicSource.onChromeReloadLive?.call();
    expect(calls, <String>['b.chrome']);
    ReaderMyComicSource.detachLiveHooks(b);
  });
}
