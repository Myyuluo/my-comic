import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/download/rebuild_download_index_service.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_schema_rebuild_index.dart';

import '../helpers/test_platform_services.dart';

/// 设置 →「存储与下载 → 备份索引」的「重建下载索引」入口。
///
/// 整行可点的动作行（确认 → 进度/取消 → 结果摘要），复用现有设置组件与对话框
/// 壳；重建服务只接收当前 Content root 的两个根，测试缝替换执行体以免 widget
/// 测试碰真实数据库/文件系统。Ticket 06：下载索引与备份合并为「备份索引」，
/// 重建入口保留原 item id，桌面可见性从 section 下移到本行。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDown(() {
    debugRunRebuildDownloadIndex = null;
    LocaleSettings.setLocale(AppLocale.en);
  });

  SettingsSection rebuildSection() =>
      buildDownloadsDestination().sections.singleWhere(
        (SettingsSection section) => section.id == 'system.section.backup',
      );

  Future<SettingsContext> captureContext(WidgetTester tester) async {
    late SettingsContext captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              captured = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  RebuildDownloadIndexReport report({
    int booksScanned = 4,
    int booksMatched = 1,
    int booksRelinked = 1,
    int chaptersRelinked = 2,
    int booksMissing = 1,
    int chaptersMissing = 3,
    int booksSkipped = 2,
    int booksAmbiguous = 1,
    int skippedChapters = 2,
    int failed = 1,
    bool cancelled = false,
  }) => RebuildDownloadIndexReport(
    booksScanned: booksScanned,
    booksMatched: booksMatched,
    booksRelinked: booksRelinked,
    booksMissing: booksMissing,
    booksSkipped: booksSkipped,
    booksAmbiguous: booksAmbiguous,
    chaptersRelinked: chaptersRelinked,
    chaptersMissing: chaptersMissing,
    chaptersSkipped: skippedChapters,
    failed: failed,
    cancelled: cancelled,
  );

  String expectedReportText(RebuildDownloadIndexReport value) =>
      t.rebuild_download_index_report_body(
        scanned: value.booksScanned,
        matched: value.booksMatched,
        books: value.booksRelinked,
        chapters: value.chaptersRelinked,
        missingBooks: value.booksMissing,
        missingChapters: value.chaptersMissing,
        skippedBooks: value.booksSkipped,
        ambiguous: value.booksAmbiguous,
        skippedChapters: value.chaptersSkipped,
        failed: value.failed,
      );

  testWidgets('备份索引页显示「重建下载索引」整行动作入口', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = rebuildSection();

    expect(
      section.isVisible(settings),
      isTrue,
      reason: '合并后的备份索引分组在所有平台都渲染（备份行在移动端可见）',
    );
    expect(section.visible, isNull, reason: '桌面可见性不能挂在整组上');
    expect(section.title, '备份索引');
    // 整行可点的动作行，不再是带行尾按钮的状态行。
    final SettingsActionItem item =
        section.items.singleWhere(
              (SettingsItem item) => item.id == 'storage.rebuild_index',
            )
            as SettingsActionItem;
    expect(item.id, 'storage.rebuild_index', reason: 'item id 是稳定控制通道键');
    expect(item.title, '重建下载索引');
    expect(
      item.subtitle,
      '重新关联书架中已有漫画的下载章节，适用于导入备份后有本地下载章节却显示未下载；'
      '不会删除记录或文件。',
    );
    expect(item.cli, isNotNull, reason: '动作行必须声明控制通道入口');
    expect(item.visible, isNotNull, reason: '桌面可见性下移到重建行自身，不能把整组合并分组变成桌面专属');
    expect(item.isVisible(settings), isTrue, reason: '桌面测试主机上重建行可见');
    expect(
      buildDownloadsDestination().sections.map(
        (SettingsSection section) => section.id,
      ),
      <String>[
        'storage.location.section',
        'system.section.backup',
        'downloads.section.download',
      ],
      reason: 'ticket 06：数据存储位置 → 备份索引 → 下载',
    );
  });

  testWidgets('确认后显示进度并给出结果摘要', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    int runnerCalls = 0;
    SettingsContext? seenContext;
    RebuildDownloadIndexCancelToken? seenToken;
    final List<RebuildDownloadIndexProgress> progress =
        <RebuildDownloadIndexProgress>[];
    debugRunRebuildDownloadIndex =
        (
          SettingsContext ctx,
          RebuildDownloadIndexCancelToken cancelToken,
          void Function(RebuildDownloadIndexProgress progress)? onProgress,
        ) async {
          runnerCalls++;
          seenContext = ctx;
          seenToken = cancelToken;
          onProgress?.call(
            const RebuildDownloadIndexProgress(
              completed: 0,
              total: 1,
              currentTitle: 'Fixture series',
            ),
          );
          progress.add(
            const RebuildDownloadIndexProgress(
              completed: 0,
              total: 1,
              currentTitle: 'Fixture series',
            ),
          );
          return report();
        };

    final SettingsActionItem item =
        rebuildSection().items.singleWhere(
              (SettingsItem item) => item.id == 'storage.rebuild_index',
            )
            as SettingsActionItem;
    final Future<void> action = Future<void>.sync(() => item.onTap(settings));
    await tester.pump();
    await tester.pumpAndSettle();

    // 先确认。
    expect(find.text('重建下载索引？'), findsOneWidget);
    await tester.tap(find.text('重建'));
    await tester.pumpAndSettle();

    expect(runnerCalls, 1);
    expect(seenContext, same(settings));
    expect(seenToken!.isCancelled, isFalse);
    expect(progress, isNotEmpty);
    final RebuildDownloadIndexReport expected = report();
    expect(find.text(expectedReportText(expected)), findsOneWidget);

    // 关掉结果框，动作 Future 才完成。
    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await action;
  });

  testWidgets('进度框可取消，取消后仍给出已完成部分的摘要', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final Completer<RebuildDownloadIndexReport> pending =
        Completer<RebuildDownloadIndexReport>();
    RebuildDownloadIndexCancelToken? seenToken;
    debugRunRebuildDownloadIndex =
        (
          SettingsContext ctx,
          RebuildDownloadIndexCancelToken cancelToken,
          void Function(RebuildDownloadIndexProgress progress)? onProgress,
        ) {
          seenToken = cancelToken;
          onProgress?.call(
            const RebuildDownloadIndexProgress(
              completed: 0,
              total: 2,
              currentTitle: 'Fixture series',
            ),
          );
          return pending.future;
        };

    final SettingsActionItem item =
        rebuildSection().items.singleWhere(
              (SettingsItem item) => item.id == 'storage.rebuild_index',
            )
            as SettingsActionItem;
    final Future<void> action = Future<void>.sync(() => item.onTap(settings));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('重建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.rebuild_download_index_progress_title), findsOneWidget);
    expect(find.text('Fixture series'), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(seenToken!.isCancelled, isTrue);

    pending.complete(report(cancelled: true));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '已取消，以下是已完成的部分：\n\n${expectedReportText(report(cancelled: true))}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await action;
  });
}
