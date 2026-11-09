import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_database_clear.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/src/storage/manga_database_clear_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 13：设置 →「存储与下载」→「数据存储位置」的「清理数据库」动作行。
///
/// 页面级测试覆盖：Source 列表与数量、多选、默认开启「保留有阅读记录的作品」、
/// 关闭开关的警告、将删除的作品/History 数量、取消不执行、进度、结果 toast 与
/// 不重启。删除范围本身由服务层测试覆盖。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDown(() {
    debugMeasureMangaDatabaseClearSources = null;
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

  const MangaDatabaseClearSource sourceA = MangaDatabaseClearSource(
    key: 'source-a',
    kind: MangaDatabaseClearSourceKind.online,
    name: 'Source A',
    runtime: OnlineMangaRuntimeKind.mihon,
    sourceId: '101',
    nonLibraryWorks: 3,
    readWorks: 1,
    historyEntries: 4,
    readHistoryEntries: 2,
  );
  const MangaDatabaseClearSource sourceB = MangaDatabaseClearSource(
    key: 'source-b',
    kind: MangaDatabaseClearSourceKind.online,
    name: 'Source B',
    runtime: OnlineMangaRuntimeKind.mihon,
    sourceId: '102',
    nonLibraryWorks: 1,
    readWorks: 0,
    historyEntries: 1,
    readHistoryEntries: 0,
  );

  testWidgets('「清理数据库」行排在「清除缓存」之后，使用破坏性样式', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    final SettingsSection section = buildContentRootsSection();

    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'storage.content_root',
      'storage.program_state_root',
      'storage.clear_cache',
      'storage.clear_database',
    ]);

    final SettingsActionItem item = clearDatabaseItem();
    expect(item.title, '清理数据库');
    expect(
      item.subtitle,
      '按来源清理未加入书架的作品记录与历史；默认保留有阅读记录的作品。书架、下载文件与本地图源文件都会保留。',
    );
    expect(item.destructive, isTrue, reason: '清理数据库必须使用 destructive 红色样式');
    expect(item.isEnabled(settings), isTrue);
    expect(item.cli, isNotNull, reason: '动作行必须在控制通道声明入口');
  });

  testWidgets('没有非书架作品时给出空状态提示且不弹确认框', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );
    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        const <MangaDatabaseClearSource>[];
    bool ran = false;
    debugRunMangaDatabaseClear =
        (SettingsContext _, Set<String> _, bool _, _) async {
          ran = true;
          return const MangaDatabaseClearCounts(
            works: 0,
            historyEntries: 0,
            readingStateRows: 0,
          );
        };

    await clearMangaDatabase(settings);
    await tester.pumpAndSettle();

    expect(find.text(t.database_clear_nothing), findsOneWidget);
    expect(find.text(t.database_clear_confirm_title), findsNothing);
    expect(ran, isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('确认框列出 Source 与数量；多选、默认保留已读作品并显示删除数量', (
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

    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        const <MangaDatabaseClearSource>[sourceA, sourceB];
    Set<String>? receivedSources;
    bool? receivedKeepRead;
    final Completer<MangaDatabaseClearCounts> pending =
        Completer<MangaDatabaseClearCounts>();
    debugRunMangaDatabaseClear =
        (
          SettingsContext _,
          Set<String> sourceKeys,
          bool keepRead,
          void Function(MangaDatabaseClearProgress progress)? onProgress,
        ) {
          receivedSources = sourceKeys;
          receivedKeepRead = keepRead;
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

    expect(find.text(t.database_clear_confirm_title), findsOneWidget);
    expect(find.text(t.database_clear_dialog_intro), findsOneWidget);
    expect(find.text('Source A'), findsOneWidget);
    expect(find.text('Source B'), findsOneWidget);
    expect(find.text(t.database_clear_source_count(count: 3)), findsOneWidget);
    expect(find.text(t.database_clear_source_count(count: 1)), findsOneWidget);
    expect(find.text(t.database_clear_keep_read_title), findsOneWidget);
    expect(find.text(t.database_clear_keep_read_warning), findsNothing);
    expect(
      find.text(t.database_clear_confirm_body(works: 0, history: 0)),
      findsOneWidget,
    );

    // 未选择 Source 时确认按钮不生效。
    await tester.tap(find.text(t.database_clear_button));
    await tester.pumpAndSettle();
    expect(find.text(t.database_clear_confirm_title), findsOneWidget);
    expect(receivedSources, isNull);

    // 多选：A 的 3 部（其中 1 部有阅读记录）→ 默认删除 2 部 / 2 条历史。
    await tester.tap(find.text('Source A'));
    await tester.pumpAndSettle();
    expect(
      find.text(t.database_clear_confirm_body(works: 2, history: 2)),
      findsOneWidget,
    );

    await tester.tap(find.text('Source B'));
    await tester.pumpAndSettle();
    expect(
      find.text(t.database_clear_confirm_body(works: 3, history: 3)),
      findsOneWidget,
    );

    // 关闭保留开关：已读/进度会丢失，给出警告并显示全量删除数量。
    await tester.tap(find.text(t.database_clear_keep_read_title));
    await tester.pumpAndSettle();
    expect(find.text(t.database_clear_keep_read_warning), findsOneWidget);
    expect(
      find.text(t.database_clear_confirm_body(works: 4, history: 5)),
      findsOneWidget,
    );

    await tester.tap(find.text(t.database_clear_button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(receivedSources, <String>{'source-a', 'source-b'});
    expect(receivedKeepRead, isFalse);
    expect(find.text(t.database_clear_progress_title), findsOneWidget);
    expect(find.text(t.database_clear_step_works), findsOneWidget);

    pending.complete(
      const MangaDatabaseClearCounts(
        works: 4,
        historyEntries: 5,
        readingStateRows: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(t.database_clear_done(works: 4, history: 5)),
      findsOneWidget,
    );
    expect(lifecycle.restartCalled, isFalse, reason: '清理数据库不需要重启');
    await action;
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('默认开启保留开关：确认时传 keepRead=true 且保留已读作品的数量', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );

    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        const <MangaDatabaseClearSource>[sourceA];
    bool? receivedKeepRead;
    Set<String>? receivedSources;
    debugRunMangaDatabaseClear =
        (
          SettingsContext _,
          Set<String> sourceKeys,
          bool keepRead,
          void Function(MangaDatabaseClearProgress progress)? onProgress,
        ) async {
          receivedSources = sourceKeys;
          receivedKeepRead = keepRead;
          return const MangaDatabaseClearCounts(
            works: 2,
            historyEntries: 2,
            readingStateRows: 0,
          );
        };

    final Future<void> action = Future<void>.sync(
      () => clearMangaDatabase(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source A'));
    await tester.pumpAndSettle();

    expect(find.text(t.database_clear_keep_read_warning), findsNothing);
    expect(
      find.text(t.database_clear_confirm_body(works: 2, history: 2)),
      findsOneWidget,
    );

    await tester.tap(find.text(t.database_clear_button));
    await tester.pumpAndSettle();

    expect(receivedSources, <String>{'source-a'});
    expect(receivedKeepRead, isTrue);
    expect(
      find.text(t.database_clear_done(works: 2, history: 2)),
      findsOneWidget,
    );
    await action;
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('取消不执行清理', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        const <MangaDatabaseClearSource>[sourceA];
    bool ran = false;
    debugRunMangaDatabaseClear =
        (SettingsContext _, Set<String> _, bool _, _) async {
          ran = true;
          return const MangaDatabaseClearCounts(
            works: 0,
            historyEntries: 0,
            readingStateRows: 0,
          );
        };

    final Future<void> action = Future<void>.sync(
      () => clearMangaDatabase(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pumpAndSettle();

    expect(ran, isFalse);
    expect(find.text(t.database_clear_confirm_title), findsNothing);
    await action;
  });

  testWidgets('读取 Source 失败时提示错误', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );
    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        throw StateError('fixture measure failure');

    await clearMangaDatabase(settings);
    await tester.pumpAndSettle();

    expect(find.textContaining('fixture measure failure'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('执行失败时提示错误且不重启', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final FakeLifecycleService lifecycle = FakeLifecycleService()
      ..supportsRestartValue = true;
    final SettingsContext settings = await captureContext(
      tester,
      lifecycle: lifecycle,
      navigatorKey: navKey,
    );

    debugMeasureMangaDatabaseClearSources = (SettingsContext _) async =>
        const <MangaDatabaseClearSource>[sourceA];
    debugRunMangaDatabaseClear =
        (SettingsContext _, Set<String> _, bool _, _) async =>
            throw StateError('fixture failure');

    final Future<void> action = Future<void>.sync(
      () => clearMangaDatabase(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Source A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.database_clear_button));
    await tester.pumpAndSettle();

    expect(find.textContaining('fixture failure'), findsOneWidget);
    expect(lifecycle.restartCalled, isFalse);
    await action;
    await tester.pump(const Duration(seconds: 3));
  });
}
