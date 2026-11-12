import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 2026-10 动效重做的接入面守卫：PR #1905 只给书架散书网格接了错峰进场，
/// 用户实测「视频那块手感还是之前那样、设置页也要做」（2026-10-04）。这里钉住
/// 设置（分类列表 / 详情分组）与其余库页 / 浏览页网格都在
/// [MyComicEntranceScope] 下用 [MyComicStaggeredEntrance] 包卡，防止重构时静默丢掉。
///
/// my-comic 只保留漫画域后，视频 / 游戏 / 媒体服务器 / 字幕遥控器的页面已从
/// 仓库删除；对应条目随之移除，下表只覆盖仍存在的页面。
void main() {
  String read(String path) => File(path).readAsStringSync();

  test('设置分类列表与详情分组都接入错峰进场', () {
    final String src = read('lib/src/settings/material_settings_renderer.dart');
    expect(
      RegExp(r'MyComicEntranceScope\(').allMatches(src).length,
      greaterThanOrEqualTo(3),
      reason: '分类列表 / shrinkWrap 详情 / 自滚动详情三处各一个窗口',
    );
    expect(
      RegExp(r'MyComicStaggeredEntrance\(').allMatches(src).length,
      greaterThanOrEqualTo(2),
    );
  });

  // 2026-10-04 用户追加「所有功能全部都要做」：其余库页 / 浏览页网格同样接入。
  // 每个文件都要同时有窗口（scope）与逐项包装，缺 scope 时窗口常开、懒加载
  // 滚出的每一格都会淡入（拖影）。
  test('其余库页与浏览页网格都在进场窗口内错峰进场', () {
    for (final String path in <String>[
      'lib/src/pages/implementations/history_reader_page.dart',
      'lib/src/media/online/online_source_browse_page.dart',
      'lib/src/media/manga/discovery/manga_discovery_page.dart',
      // 2026-10 漫画阅读器重做：「全部页面」缩略图网格。
      'lib/src/media/manga/reader/manga_reader_page_grid.dart',
      // 2026-10 字体库重做：样张卡网格 / 列表（含拖拽重排两种形态）。
      'lib/src/pages/implementations/custom_fonts_page.dart',
      // 2026-11-07 一级「下载」页：漫画章节任务卡片列表。
      'lib/src/pages/implementations/downloads_page.dart',
    ]) {
      final String src = read(path);
      expect(src, contains('MyComicEntranceScope('), reason: path);
      expect(
        src.contains('MyComicStaggeredEntrance(') ||
            src.contains('myComicStaggeredItemBuilder('),
        isTrue,
        reason: path,
      );
    }
  });

}
