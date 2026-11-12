import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

/// 守卫：阅读器页面的统一 launch source 必须用 MyComicAppUiScaleNeutralizer 包裹；
/// 书架/历史页不得直接 push ReaderMyComicPage，必须走 ReaderMyComicSource -> AppModel
/// 的媒体入口，否则会绕开 source 层中和器和 currentMediaSource 注册。
void main() {
  String read(String p) => File(p).readAsStringSync();

  test('reader_my_comic_source wraps ReaderMyComicPage with neutralizer', () {
    final String src = read('lib/src/media/sources/reader_my_comic_source.dart');
    expect(src.contains('MyComicAppUiScaleNeutralizer'), isTrue,
        reason: 'reader_my_comic_source.dart 必须用中和器包裹 ReaderMyComicPage');
  });

  test('history page opens books through ReaderMyComicSource', () {
    final String src = readReaderHistorySource();
    expect(src.contains('appModel.openMedia('), isTrue,
        reason: '书架打开阅读器必须走 AppModel.openMedia 注册媒体源');
    expect(src.contains('mediaSource: ReaderMyComicSource.instance'), isTrue,
        reason: '书架入口必须走 ReaderMyComicSource，由 source 层包裹中和器');
    expect(src.contains('ReaderMyComicPage('), isFalse,
        reason: '书架/历史页不得直接构造 ReaderMyComicPage');
  });
}
