import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/browse_page.dart';

import '../helpers/source_guard.dart';

/// 浏览页顶层视图页签：2026-11-08 起只剩「图源 / 发现」。
///
/// 「在线源」改名为「图源」；「导入」子视图与它专用的一切（页面、枚举值、标签）
/// 退役；顶层枚举里从未被 `_visibleTabs` 产出的 legacy「扩展」值一并清掉。
/// 「来源 / 扩展」二级分段仍在「图源」页签内部（那是 `OnlineSourcesSection`，
/// 不是顶层页签）。
///
/// 真 widget 路径要起 Mihon / LNReader manager（`BrowseOnlineSourcesView` 一挂就
/// 碰 `databaseDirectory`），故这里钉枚举 + `_visibleTabs` / `_handOffFrom` 的源码形态。
void main() {
  String browseSource() => maskComments(
    File('lib/src/pages/implementations/browse_page.dart').readAsStringSync(),
  );

  test('浏览页只剩「图源 → 发现」两个视图页签', () {
    expect(BrowseTab.values.map((BrowseTab tab) => tab.name), <String>[
      'sources',
      'discover',
    ]);
  });

  test('导入子视图退役：页面、枚举值、标签与设置入口都不在了', () {
    final String source = browseSource();
    for (final String removed in <String>[
      'BrowseTab.localImport',
      'MangaSourcesPage',
      '_buildLocalImportTab',
      'library_view_import',
    ]) {
      expect(source, isNot(contains(removed)), reason: removed);
    }
    expect(
      File('lib/src/media/manga/manga_sources_page.dart').existsSync(),
      isFalse,
      reason: '浏览 › 导入的页面组件必须删除，而不是只断线',
    );
  });

  test('顶层枚举里无引用的 legacy「扩展」值已清理', () {
    expect(browseSource(), isNot(contains('BrowseTab.extensions')));
  });

  test('可见页签顺序仍是图源 → 发现，导入不再出现在任何返回值里', () {
    final String body = methodBody(
      browseSource(),
      'List<BrowseTab> _visibleTabs(AppModel appModel)',
    );
    final int sourcesIndex = body.indexOf('BrowseTab.sources');
    final int discoverIndex = body.indexOf('BrowseTab.discover');
    expect(sourcesIndex, isNonNegative, reason: '图源页签必须仍在可见序列里');
    expect(
      discoverIndex,
      greaterThan(sourcesIndex),
      reason: '最终可见页签顺序必须为「图源 → 发现」',
    );
    expect(body, isNot(contains('localImport')));
    expect(body, isNot(contains('extensions')));
  });

  test('浏览页删掉下载页签的标签、内容、状态与页头特例', () {
    final String source = browseSource();
    for (final String removed in <String>[
      'BrowseTab.downloads',
      'BrowseDownloadsSection',
      '_buildDownloadsTab',
      'MangaDownloadTasksSection',
      'resizeToAvoidBottomInset',
      '_downloadsSection',
      '_downloadsWorkFocus',
    ]) {
      expect(source, isNot(contains(removed)), reason: removed);
    }
  });

  test('_handOffFrom 先落目标页签的二级端，再切顶层页签', () {
    final String body = methodBody(
      browseSource(),
      'void _handOffFrom(BrowseTab from, int delta)',
    );
    final int setState = body.indexOf('setState(');
    final int animateTo = body.indexOf('controller.animateTo(target);');
    expect(setState, isNonNegative, reason: '接力必须先落二级端');
    expect(animateTo, isNonNegative, reason: '接力最终要切到目标页签');
    expect(
      animateTo,
      greaterThan(setState),
      reason: '二级端必须在动画开始前就位，否则拖动途中标签条与页面错位',
    );
    expect(body, contains('case BrowseTab.sources'));
    expect(body, contains('case BrowseTab.discover'));
  });
}
