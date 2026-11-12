import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 导入页统一（TODO-2930）遗留守卫。
///
/// 2026-11-08：漫画批量导入子视图退役、书 / 视频导入页随非漫画模块移除后，
/// 本文件只保留仍然成立的部分——在线来源 / 扩展只住在浏览模块，不在任何导入
/// 页；「来源 / 扩展 / 发现」的二级选择是标签页而不是分段按钮。
///
/// 为什么用源码扫描：这些页面从 `appProvider` 拿整个 `AppModel`，widget 测试
/// 测的是环境不是接线；这里要守的恰恰是接线与入口位置本身。读源码并**掩掉
/// 注释**（共享 [maskComments]，等长掩码不打乱下标），防止「实现删光、注释里
/// 留字面量」的假绿。
String _read(String path) => maskComments(File(path).readAsStringSync());

void main() {
  /// 2026-09-19 用户口径：「统一一下视频和动画的导入页，重新设计一下对源和仓库的
  /// UI」——当时落地为两页顶部同一条分段选择器（本地 / 仓库 / 扩展 / 在线源）。
  ///
  /// 2026-09-27 起在线来源 / 扩展 / 仓库整体搬进顶层「浏览」模块（Mihon Browse
  /// 形态，`browse_page.dart` 的图源页签 + `browse_online_sources_view.dart`）。
  /// 本组钉的是这次收拢不被回退：在线来源面只有浏览模块一份。
  group('在线源 / 扩展只住在浏览模块', () {
    final String online = _read(
      'lib/src/pages/implementations/browse_online_sources_view.dart',
    );
    final String mangaOnline = _read(
      'lib/src/media/manga/manga_online_sources_view.dart',
    );
    final String browse = _read(
      'lib/src/pages/implementations/browse_page.dart',
    );

    test('在线来源只住在浏览模块的漫画视图，视频独立页与入口卡已删', () {
      expect(online, contains('MangaOnlineSourcesView('));
      expect(
        online,
        contains(r"ValueKey<String>('manga_online_${widget.section.name}')"),
      );
      expect(online, isNot(contains('VideoOnlineSourcesPage')));
      expect(online, isNot(contains('video_online_sources_entry')));
      expect(
        File(
          'lib/src/media/video/online/video_online_sources_page.dart',
        ).existsSync(),
        isFalse,
        reason: '视频域已删除；在线来源只剩漫画一份',
      );
    });

    test('扩展节 widget key 固定、浏览页按域保活，切页签 / 切域不丢状态', () {
      expect(
        mangaOnline,
        contains(r"ValueKey<String>('manga_mihon_extensions_${section.name}')"),
      );
      // 各域是可横滑的 TabBarView 页，经 _BrowseTabKeepAlive 保活（离屏不丢状态）。
      expect(browse, contains('_BrowseSwipeSections<OnlineSourcesDomain>('));
      // 来源 / 扩展同在图源页签里，按分区各自保活。
      expect(browse, contains(r"'browse-${section.name}-${domain.name}'"));
      expect(browse, contains('bool get wantKeepAlive => true;'));
    });

    test('漫画在线源点行进源；不再有内置 mokuro.moe 行', () {
      expect(mangaOnline, contains('MihonInstalledSourcesSection('));
      expect(mangaOnline, contains('onOpenSource: _openMihonSource'));
      expect(mangaOnline, contains('MihonSourceBrowsePage('));
      expect(mangaOnline, isNot(contains('MokuroMoeSourceRow')));
      expect(mangaOnline, isNot(contains('mokuro_moe')));
    });

    test('来源 / 扩展 / 发现的二级选择是标签页，不再是分段按钮', () {
      expect(browse, isNot(contains('MyComicSegmentedStrip')));
      expect(browse, isNot(contains('ButtonSegment<')));
      expect(
        RegExp(
          r'_BrowseSwipeSections<(?:OnlineSourcesDomain|_DownloadsResourceDomain)>\(',
        ).allMatches(browse),
        hasLength(2),
        reason: '来源 / 扩展共用一处 + 发现，共两处二级标签条（下载是独立一级页，无视图页签）',
      );
      // One additional generic constructor belongs only to the explicit
      // widget-test seam. Keep a total budget so new production domains cannot
      // silently escape the typed-site assertions above.
      expect(
        RegExp(r'_BrowseSwipeSections<\w+>\(').allMatches(browse),
        hasLength(3),
      );
      final String seam = methodBody(
        browse,
        'Widget debugBrowseSwipeSections<',
      );
      expect(
        RegExp(r'_BrowseSwipeSections<T>\(').allMatches(seam),
        hasLength(1),
      );
      expect(
        'secondary: true'.allMatches(browse),
        hasLength(2),
        reason:
            '两处二级标签条共用 _BrowseSwipeSections 里同一份 secondary tabs；'
            '另一处是在图源二级行右侧的来源 / 扩展页签',
      );
      for (final String key in <String>[
        r"'browse-${tab.name}-domain-picker'",
        "'downloads-resource-type-picker'",
      ]) {
        expect(browse, contains(key), reason: '二级标签条保留稳定 key：$key');
      }
    });
  });

  group('术语统一：「本地扫描根」并入「常驻来源」', () {
    test('i18n 里 media_source_local_roots key 已删除', () {
      final String zh = File(
        'lib/i18n/strings_zh-CN.i18n.json',
      ).readAsStringSync();
      final String en = File('lib/i18n/strings.i18n.json').readAsStringSync();
      expect(zh, isNot(contains('media_source_local_roots')));
      expect(en, isNot(contains('media_source_local_roots')));
      expect(zh, isNot(contains('本地扫描根')));
    });
  });
}
