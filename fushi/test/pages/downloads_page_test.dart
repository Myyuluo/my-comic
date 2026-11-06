import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/downloads/download_task_card.dart';
import 'package:fushi/src/media/manga/download/manga_download_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/source_guard.dart';

/// 一级「下载」页（2026-11-07 从浏览页的「下载」视图页签迁出）：
///
/// - 顶部只有外壳固定展开的「下载」标题（页内不画标题、不画视图页签）；
/// - 内容就是现有的简单漫画下载任务列表，没有任务时显示空态；
/// - 列表从标题下方开始，不消费浏览页那套浮动工具区留白（旧遮挡 bug 的成因）。
///
/// 外壳标题 / 保活 / 导航顺序的接线用源码守卫钉住（HomePage 在 headless 下无法
/// 稳定挂载），内容行为用真实页面 + 真实 37 表数据库验证。
void main() {
  late FushiDatabase db;
  late MangaDownloadService downloads;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    downloads = MangaDownloadService(
      database: db,
      // 本测试只读任务列表，不会触发下载 worker。
      serviceFor: (OnlineMangaRuntimeKind _) =>
          throw UnimplementedError('下载 worker 不应在本测试中运行'),
    );
  });

  tearDown(() async {
    downloads.dispose();
    await db.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: DownloadsPage(downloadsOverride: downloads)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> insertTask({
    String jobId = 'job-1',
    String title = '某作品',
    String chapterTitle = '第 1 话',
  }) async {
    await db.upsertMangaDownloadJob(
      MangaDownloadJobsCompanion.insert(
        jobId: jobId,
        kind: MangaDownloadJobKind.chapter,
        bookKey: 'book-1',
        chapterKey: 'chapter-$jobId',
        runtime: 'mihon',
        title: title,
        chapterTitle: chapterTitle,
        status: const Value<String>(MangaDownloadJobStatus.queued),
        pagesDone: const Value<int>(0),
        pagesTotal: const Value<int>(10),
        attemptCount: const Value<int>(0),
        autoOcr: const Value<bool>(false),
        createdAt: 1,
        updatedAt: 1,
      ),
    );
  }

  group('下载页内容', () {
    testWidgets('没有下载任务时显示空态提示', (WidgetTester tester) async {
      await pumpPage(tester);

      expect(find.text(t.anime_download_no_tasks), findsOneWidget);
      expect(find.byType(DownloadTaskCard), findsNothing);
    });

    testWidgets('有任务时显示与原先相同的任务卡片', (WidgetTester tester) async {
      await insertTask();
      await pumpPage(tester);

      expect(find.byType(DownloadTaskCard), findsOneWidget);
      expect(find.text('第 1 话'), findsOneWidget);
      expect(find.textContaining('某作品'), findsOneWidget);
      expect(find.text(t.anime_download_no_tasks), findsNothing);
    });

    testWidgets('页面内不显示视图页签', (WidgetTester tester) async {
      await insertTask();
      await pumpPage(tester);

      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
    });
  });

  group('下载页外壳接线', () {
    String homeSource() =>
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();

    String methodSlice(String source, String signature) {
      final int start = source.indexOf(signature);
      expect(start, isNonNegative, reason: '找不到 $signature');
      final int end = source.indexOf('\n  }', start);
      return end < 0 ? source.substring(start) : source.substring(start, end);
    }

    test('标题固定展开：只有下载页钉住展开态', () {
      expect(homeTabPinsExpandedTitle(HomeTab.downloads), isTrue);
      for (final HomeTab tab in HomeTab.values) {
        if (tab == HomeTab.downloads) continue;
        expect(homeTabPinsExpandedTitle(tab), isFalse, reason: '$tab');
      }
    });

    test('外壳标题条真正使用固定展开判据', () {
      final String body = methodSlice(
        homeSource(),
        'Widget _buildShellTitleBar()',
      );
      expect(body, contains('homeTabPinsExpandedTitle(_visibleTab)'));
    });

    test('下载页不被当成浮动工具区页签（列表从标题下方开始，不叠在标题下）', () {
      final String body = methodSlice(
        homeSource(),
        'static bool _tabHasFloatingChrome(HomeTab tab)',
      );
      expect(body, isNot(contains('HomeTab.downloads')));
    });

    test('下载页页面不消费浮动工具区留白', () {
      final String source = maskComments(
        File(
          'lib/src/pages/implementations/downloads_page.dart',
        ).readAsStringSync(),
      );
      expect(source, isNot(contains('FushiFloatingChromeInset')));
    });
  });
}
