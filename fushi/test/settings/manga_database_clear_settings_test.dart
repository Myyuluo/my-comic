import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_database_clear.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 13：设置 →「存储与下载」→「数据存储位置」的「清除数据库」动作行。
///
/// 页面级测试覆盖：破坏性行位于「清除缓存」之后、确认框显示将删除的数量、
/// 进度框、完成 toast 与不重启；删除本身由服务层测试覆盖。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDown(() {
    debugMeasureMangaDatabaseClearCounts = null;
    debugRunMangaDatabaseClear = null;
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<SettingsContext> captureContext(
    WidgetTester tester, {
    FakeLifecycleService? lifecycle,
    GlobalKey<NavigatorState>? navigatorKey,
  }) async {
    late SettingsContext captured;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              captured = SettingsContext(
                context: context,
                appModel: AppModel(
                  lifecycle == null
                      ? testPlatformServices()
                      : fakePlatformServices(lifecycle: lifecycle),
                ),
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

  SettingsActionItem clearDatabaseItem() =>
      buildContentRootsSection().items.singleWhere(
            (SettingsItem item) => item.id == 'storage.clear_database',
          )
          as SettingsActionItem;

  const MangaDatabaseClearCounts fixtureCounts = MangaDatabaseClearCounts(
    works: 2,
    historyEntries: 5,
    readingRecords: 3,
  );

  testWidgets('「清除数据库」行排在「清除缓存」之后，使用破坏性样式', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = buildContentRootsSection();

    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'storage.content_root',
      'storage.program_state_root',
      'storage.clear_cache',
      'storage.clear_database',
    ]);

    final SettingsActionItem item = clearDatabaseItem();
    expect(item.title, '清除数据库');
    expect(item.destructive, isTrue, reason: '清除数据库必须使用 destructive 红色样式');
    expect(item.isEnabled(settings), isTrue);
    expect(item.cli, isNotNull, reason: '动作行必须在控制通道声明入口');
  });

  testWidgets('确认框显示将删除的作品/历史/阅读记录数量，完成后 toast 且不重启', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final FakeLifecycleService lifecycle = FakeLifecycleService()
      ..supportsRestartValue = true;
    final SettingsContext settings = await captureContext(
      tester,
      lifecycle: lifecycle,
      navigatorKey: navKey,
    );

    debugMeasureMangaDatabaseClearCounts = (SettingsContext _) async =>
        fixtureCounts;
    final Completer<MangaDatabaseClearCounts> pending =
        Completer<MangaDatabaseClearCounts>();
    debugRunMangaDatabaseClear =
        (
          SettingsContext _,
          void Function(MangaDatabaseClearProgress progress)? onProgress,
        ) {
          onProgress?.call(
            const MangaDatabaseClearProgress(
              step: MangaDatabaseClearStep.works,
              fraction: 0.1,
            ),
          );
          return pending.future;
        };

    final Future<void> action = Future<void>.sync(
      () => clearMangaDatabase(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('清除数据库？'), findsOneWidget);
    expect(
      find.text(
        t.database_clear_confirm_body(works: 2, history: 5, records: 3),
      ),
      findsOneWidget,
      reason: '确认框必须显示将删除的作品/历史/阅读记录数量',
    );

    await tester.tap(find.text('清除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.database_clear_progress_title), findsOneWidget);
    expect(find.text('正在删除未入书架的作品'), findsOneWidget);

    pending.complete(fixtureCounts);
    await tester.pumpAndSettle();

    expect(
      find.text(t.database_clear_done(works: 2, history: 5, records: 3)),
      findsOneWidget,
    );
    expect(lifecycle.restartCalled, isFalse, reason: '清除数据库不需要重启');
    await action;
    // 让 toast 自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('删除失败时提示错误且不重启', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final FakeLifecycleService lifecycle = FakeLifecycleService()
      ..supportsRestartValue = true;
    final SettingsContext settings = await captureContext(
      tester,
      lifecycle: lifecycle,
      navigatorKey: navKey,
    );

    debugMeasureMangaDatabaseClearCounts = (SettingsContext _) async =>
        fixtureCounts;
    debugRunMangaDatabaseClear =
        (
          SettingsContext _,
          void Function(MangaDatabaseClearProgress progress)? onProgress,
        ) async => throw StateError('fixture failure');

    final Future<void> action = Future<void>.sync(
      () => clearMangaDatabase(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('fixture failure'),
      findsOneWidget,
      reason: '失败必须给出可见反馈',
    );
    expect(lifecycle.restartCalled, isFalse);
    await action;
    await tester.pump(const Duration(seconds: 3));
  });
}
