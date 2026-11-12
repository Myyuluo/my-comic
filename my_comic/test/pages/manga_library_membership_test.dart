import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic_core/my_comic_core.dart';
import 'package:material_ui/material_ui.dart';

import 'manga_library_page_harness.dart';

/// Library membership（manga-library-membership 票 01）页面级 seam：
/// 挂真实漫画书架页 + 真 37 表内存 DB，**不覆写** `myComicBooksProvider`，
/// 让书架走生产路径 `ReaderMyComicSource.getBooksFromDb`。断言只落在用户可见
/// 结果上：哪些卡出现在书架、Tag 页签计数、继续阅读胶囊是否出现。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(
    () => MangaLibraryPageHarness.setUpPathProvider(
      binding,
      tempPrefix: 'my_comic_manga_membership_pp',
    ),
  );
  tearDownAll(() => MangaLibraryPageHarness.tearDownPathProvider(binding));

  late MangaLibraryPageHarness<AppModel> harness;

  setUp(() async {
    harness = await MangaLibraryPageHarness.create<AppModel>(
      tempPrefix: 'my_comic_manga_membership',
    );
  });

  tearDown(() => harness.dispose());

  Future<String> seedHiddenManga(
    String bookKey,
    String title, {
    int chapterCount = 3,
    int sectionIndex = 1,
    int? lastReadAt,
  }) async {
    final String uid = 'uid_$bookKey';
    await harness.db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: bookKey,
        uid: Value<String>(uid),
        title: title,
        epubPath: '${harness.pathProviderDir.path}/$bookKey/manga.json',
        extractDir: '${harness.pathProviderDir.path}/$bookKey',
        chapterCount: chapterCount,
        chaptersJson: '[]',
        importedAt: 0,
        format: Value<String>(BookFormat.manga.dbValue),
        inLibrary: const Value<bool>(false),
      ),
    );
    if (lastReadAt != null) {
      await harness.db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: uid,
          sectionIndex: sectionIndex,
          normCharOffset: 0,
          updatedAt: lastReadAt,
        ),
      );
    }
    return uid;
  }

  Finder mangaCard(String bookKey) => find.byKey(
    ValueKey<String>(
      'book_entry_${ReaderMyComicSource.mediaIdentifierFor(bookKey)}',
    ),
  );

  String countText(WidgetTester tester, String scope) => tester
      .widget<Text>(find.byKey(ValueKey<String>('manga_tag_tab_count_$scope')))
      .data!;

  testWidgets('非书架 Manga 不出现在书架、Tag 计数与继续阅读', (WidgetTester tester) async {
    await harness.seedManga('library', '书架作品');
    // 非书架行拥有更晚的阅读位置：如果按「行存在 = 在书架」实现，它会成为
    // 继续阅读候选并出现在书架；membership 过滤必须让它彻底消失。
    await seedHiddenManga('hidden', '非书架作品', lastReadAt: 2000);
    final int tagId = await harness.db.createTag('隐藏标签', 0xFF112233);
    await harness.db.addTagToBook('hidden', tagId);

    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(harness.buildApp(overrideBooks: false));
    // 真实 `myComicBooksProvider` 走 Drift 异步查询；FakeAsync 的 pump 收不到
    // 真实事件循环投递的 Future，放行一次真实 async 再让新书架渲染出来。
    // 页面壳上的加载动效是无限循环的，不能 pumpAndSettle，固定帧推进即可。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(mangaCard('library'), findsOneWidget);
    expect(
      mangaCard('hidden'),
      findsNothing,
      reason: 'membership=false 的行不得出现在书架',
    );
    expect(countText(tester, 'shelf'), '1');
    expect(countText(tester, '$tagId'), '0', reason: 'Tag 页签计数只统计书架里的 Manga');
    expect(
      find.byKey(const ValueKey<String>('reader_shelf_continue_pill')),
      findsNothing,
      reason: 'Home / 书架的继续阅读只看 membership=true 的作品',
    );

    // 卸载页面：ProviderScope 释放 Drift watch stream 时会排一个零时长定时器，
    // FakeAsync 收尾前要把它跑掉（同 `manga_library_tag_refresh_test`）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 10));
  });
}
