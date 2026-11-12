import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:my_comic/src/media/manga/manga_library_page.dart';
import 'package:my_comic/src/media/media_item.dart';
import 'package:my_comic/src/media/sources/manga_my_comic_source.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/pages/implementations/media_library_shell.dart';
import 'package:my_comic/src/pages/implementations/reader_my_comic_history_page.dart';

import '../helpers/source_guard.dart';

/// BUG-1164：PR#474 让书架按 `mangaOnly` 分流（普通书架排除漫画，漫画只在独立
/// 漫画书架出现），但全仓 `git grep 'MangaLibraryPage\|mangaOnly' -- my_comic/test`
/// 零命中——这条用户直接可见的行为一条测试都没有。
///
/// 这里守两件事：
/// 1. 分流谓词本身（互补、无遗漏、无重复）；
/// 2. 漫画库页确实带 `mangaOnly: true` 接进同一个书架实现，没有接反。
///
/// PR#594 落地后追加第 3 件：顶层视图列表不随扩展宿主分叉。2026-11-05 用户口径：
/// 发现 / 在线源 / Local import 全部搬到「浏览」，漫画页只留书架。

MediaItem _item(String identifier, String sourceKey) => MediaItem(
      mediaIdentifier: identifier,
      title: identifier,
      mediaTypeIdentifier: 'reader',
      mediaSourceIdentifier: sourceKey,
      position: 0,
      duration: 1,
      canDelete: false,
      canEdit: true,
    );

void main() {
  final MediaItem manga1 = _item('m1', MangaMyComicSource.kUniqueKey);
  final MediaItem manga2 = _item('m2', MangaMyComicSource.kUniqueKey);
  final MediaItem novel = _item('n1', ReaderMyComicSource.instance.uniqueKey);
  final MediaItem other = _item('o1', 'some_other_source');
  final List<MediaItem> corpus = <MediaItem>[manga1, novel, manga2, other];

  group('书架/漫画书架条目分流', () {
    test('普通书架排除全部漫画条目，其余原样保留（含顺序）', () {
      expect(
        filterShelfEntriesByMangaSplit(corpus, mangaOnly: false),
        <MediaItem>[novel, other],
      );
    });

    test('漫画书架只保留漫画条目（含顺序）', () {
      expect(
        filterShelfEntriesByMangaSplit(corpus, mangaOnly: true),
        <MediaItem>[manga1, manga2],
      );
    });

    test('两个书架互补：并集 = 全集，交集为空，没有条目凭空消失', () {
      final List<MediaItem> normal =
          filterShelfEntriesByMangaSplit(corpus, mangaOnly: false);
      final List<MediaItem> mangaShelf =
          filterShelfEntriesByMangaSplit(corpus, mangaOnly: true);
      expect(normal.length + mangaShelf.length, corpus.length,
          reason: '分流不得吞条目，也不得让条目同时出现在两个书架');
      expect(<MediaItem>{...normal, ...mangaShelf}, corpus.toSet());
      expect(normal.toSet().intersection(mangaShelf.toSet()), isEmpty);
    });

    test('空输入两侧都是空列表', () {
      expect(
          filterShelfEntriesByMangaSplit(const <MediaItem>[], mangaOnly: false),
          isEmpty);
      expect(
          filterShelfEntriesByMangaSplit(const <MediaItem>[], mangaOnly: true),
          isEmpty);
    });

    testWidgets('漫画库页只有书架视图，并接的是 mangaOnly: true 的书架实现（没接反）',
        (WidgetTester tester) async {
      // 只取 build 的产物，不真正挂载子树：整页依赖 DB / WebView / 一堆 provider，
      // 挂起来就成了「测环境」而不是测这条接线。2026-11-05 起漫画库页只声明书架。
      Widget? built;
      await tester.pumpWidget(
        Builder(builder: (BuildContext context) {
          built = const MangaLibraryPage().build(context);
          return const SizedBox.shrink();
        }),
      );
      expect(built, isA<MediaLibraryShell>());
      final MediaLibraryShell shell = built! as MediaLibraryShell;
      expect(
        shell.views.map((MediaLibraryViewSpec v) => v.kind).toList(),
        <MediaLibraryViewKind>[MediaLibraryViewKind.library],
      );
      final Widget shelf = shell.views.first.builder(
          tester.element(find.byType(SizedBox)), const SizedBox.shrink());
      expect(shelf, isA<ReaderMyComicHistoryPage>());
      expect((shelf as ReaderMyComicHistoryPage).mangaOnly, isTrue);
      // 反向锚：普通书架的默认值必须仍是 false，否则漫画会在两边都出现。
      expect(const ReaderMyComicHistoryPage().mangaOnly, isFalse);
    });

    test('漫画页只声明书架，不再按平台/合规门分叉', () {
      // 这条不 pump widget：它守的是**源码层面**没有任何条件视图。
      // 平台探测符号在 iOS/Linux 返回 false，一旦有人再把它塞回 MangaLibraryPage，
      // 导航结构就又分平台裂开了。
      //
      // 判据必须**先掩注释**（共享 maskComments，等长掩码）：本页的文档注释就在
      // 解释「不按平台分叉」，里面天然出现该符号名，裸 contains 会被自己的说明
      // 文字打成假红。
      final String source = maskComments(
        File(
          p.join('lib', 'src', 'media', 'manga', 'manga_library_page.dart'),
        ).readAsStringSync(),
      );
      expect(
        source.contains('MihonRuntimeFactory'),
        isFalse,
        reason: '漫画库页的视图列表必须是无条件常量，不得按平台/扩展可用性分叉',
      );
      // 漫画页只剩书架，不再有按合规门/平台增减的视图条件。
      final List<String> conditions =
          RegExp(r'if \((.*)\)\s*$', multiLine: true)
              .allMatches(source)
              .map((Match match) => match.group(1)!.trim())
              .toList();
      expect(
        conditions,
        isEmpty,
        reason: '漫画页只剩书架，不再有按平台/合规门分叉的视图条件',
      );
      for (final String removed in <String>[
        'mangaSources',
        'mangaExtensions',
        'sourceSettings',
        'settings',
      ]) {
        expect(
          MediaLibraryViewKind.values
              .map((MediaLibraryViewKind kind) => kind.name),
          isNot(contains(removed)),
          reason: '$removed 是四视图形态的残留 kind，必须随之删除，否则会被重新用上',
        );
      }
    });
  });
}
