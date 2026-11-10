import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/download/scan_downloaded_manga_service.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_schema_rebuild_index.dart';

import '../helpers/test_platform_services.dart';

/// 设置 →「存储与下载 → 下载索引」的「检索已下载」入口。
///
/// 整行可点的动作行（确认 → 进度/取消 → 结果摘要），与「重建下载索引」同一套
/// 组件与对话框壳；执行体通过测试缝替换，避免 widget 测试碰真实数据库/文件系统。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDown(() {
    debugRunScanDownloadedManga = null;
    LocaleSettings.setLocale(AppLocale.en);
  });

  SettingsSection scanSection() =>
      buildDownloadsDestination().sections.singleWhere(
        (SettingsSection section) => section.id == 'storage.rebuild.section',
      );

  SettingsActionItem scanItem() =>
      scanSection().items.singleWhere(
            (SettingsItem item) => item.id == 'storage.scan_downloaded',
          )
          as SettingsActionItem;

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

  ScanDownloadedMangaReport report({
    int foldersScanned = 5,
    int addedOnline = 2,
    int addedLocal = 1,
    int sourceMissing = 1,
    int promoted = 1,
    int revived = 1,
    int incomplete = 2,
    int ambiguous = 1,
    int failed = 1,
    bool cancelled = false,
  }) => ScanDownloadedMangaReport(
    foldersScanned: foldersScanned,
    addedOnline: addedOnline,
    addedLocal: addedLocal,
    addedLocalSourceMissing: sourceMissing,
    promoted: promoted,
    revivedTombstones: revived,
    skippedIncomplete: incomplete,
    skippedAmbiguous: ambiguous,
    failed: failed,
    cancelled: cancelled,
  );

  String expectedReportText(ScanDownloadedMangaReport value) =>
      t.scan_downloaded_report_body(
        scanned: value.foldersScanned,
        online: value.addedOnline,
        local: value.addedLocal,
        sourceMissing: value.addedLocalSourceMissing,
        promoted: value.promoted,
        revived: value.revivedTombstones,
        incomplete: value.skippedIncomplete,
        ambiguous: value.skippedAmbiguous,
        failed: value.failed,
      );

  testWidgets('下载索引下显示「检索已下载」整行动作入口，副标题精确', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = scanSection();

    expect(section.isVisible(settings), isTrue);
    expect(section.items.map((SettingsItem item) => item.id), <String>[
      'storage.rebuild_index',
      'storage.scan_downloaded',
    ], reason: '同一个下载索引小节下的第二个动作');
    final SettingsActionItem item = scanItem();
    expect(item.title, '检索已下载');
    expect(item.subtitle, '扫描 downloads 中已下载但未加入书架的漫画并加入书架。');
    expect(item.cli, isNotNull, reason: '动作行必须声明控制通道入口');
  });

  testWidgets('确认后显示可取消进度并给出结果摘要', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    int runnerCalls = 0;
    SettingsContext? seenContext;
    ScanDownloadedMangaCancelToken? seenToken;
    final List<ScanDownloadedMangaProgress> progress =
        <ScanDownloadedMangaProgress>[];
    debugRunScanDownloadedManga =
        (
          SettingsContext ctx,
          ScanDownloadedMangaCancelToken cancelToken,
          void Function(ScanDownloadedMangaProgress progress)? onProgress,
        ) async {
          runnerCalls++;
          seenContext = ctx;
          seenToken = cancelToken;
          const ScanDownloadedMangaProgress snapshot =
              ScanDownloadedMangaProgress(
                completed: 0,
                total: 1,
                currentTitle: 'Fixture series',
              );
          onProgress?.call(snapshot);
          progress.add(snapshot);
          return report();
        };

    final SettingsActionItem item = scanItem();
    final Future<void> action = Future<void>.sync(() => item.onTap(settings));
    await tester.pump();
    await tester.pumpAndSettle();

    // 先确认。
    expect(find.text('检索已下载？'), findsOneWidget);
    await tester.tap(find.text('检索'));
    await tester.pumpAndSettle();

    expect(runnerCalls, 1);
    expect(seenContext, same(settings));
    expect(seenToken!.isCancelled, isFalse);
    expect(progress, isNotEmpty);
    final ScanDownloadedMangaReport expected = report();
    expect(find.text(expectedReportText(expected)), findsOneWidget);

    // 关掉结果框，动作 Future 才完成。
    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await action;
  });

  testWidgets('进度框可取消，取消后仍给出已完成部分的摘要', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final Completer<ScanDownloadedMangaReport> pending =
        Completer<ScanDownloadedMangaReport>();
    ScanDownloadedMangaCancelToken? seenToken;
    debugRunScanDownloadedManga =
        (
          SettingsContext ctx,
          ScanDownloadedMangaCancelToken cancelToken,
          void Function(ScanDownloadedMangaProgress progress)? onProgress,
        ) {
          seenToken = cancelToken;
          onProgress?.call(
            const ScanDownloadedMangaProgress(
              completed: 0,
              total: 2,
              currentTitle: 'Fixture series',
            ),
          );
          return pending.future;
        };

    final SettingsActionItem item = scanItem();
    final Future<void> action = Future<void>.sync(() => item.onTap(settings));
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('检索'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.scan_downloaded_progress_title), findsOneWidget);
    expect(find.text('Fixture series'), findsOneWidget);
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(seenToken!.isCancelled, isTrue);

    pending.complete(report(cancelled: true));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '已取消，以下是已完成的部分：\n\n'
        '${expectedReportText(report(cancelled: true))}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(t.dialog_done));
    await tester.pumpAndSettle();
    await action;
  });
}
