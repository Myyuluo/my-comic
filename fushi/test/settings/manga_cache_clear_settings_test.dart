import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_cache_clear.dart';
import 'package:fushi/src/settings/settings_schema_storage_locations.dart';
import 'package:fushi/src/storage/manga_cache_clear_service.dart';
import 'package:fushi/src/storage/manga_webview_cache_clear.dart';
import 'package:fushi/src/utils/misc/fushi_byte_format.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

import '../helpers/fake_platform_services.dart';
import '../helpers/test_platform_services.dart';

/// Ticket 11：设置 →「存储与下载」→「数据存储位置」的「清除缓存」动作行。
///
/// 页面级测试覆盖：副标题显示占用、确认框显示占用、进度框复用、完成 toast
/// 释放量、部分成功提示、不重启。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
    debugResetMangaCacheUsage();
  });

  tearDown(() {
    debugBuildMangaCacheClearService = null;
    debugMeasureMangaCacheBytes = null;
    debugResetMangaCacheUsage();
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

  SettingsSection locationSection() => buildContentRootsSection();

  SettingsStatusItem clearItem(SettingsSection section) =>
      section.items.singleWhere(
            (SettingsItem item) => item.id == 'storage.clear_cache',
          )
          as SettingsStatusItem;

  testWidgets('「清除缓存」行排在两个存储位置之后，副标题显示当前占用', (WidgetTester tester) async {
    final SettingsContext settings = await captureContext(tester);
    debugMeasureMangaCacheBytes = (SettingsContext _) async => 1536;

    final SettingsSection section = locationSection();
    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'storage.content_root',
      'storage.program_state_root',
      'storage.clear_cache',
    ]);

    final SettingsStatusItem item = clearItem(section);
    expect(item.title, '清除缓存');
    expect(item.actionLabel, '清除');
    expect(item.resolveAction(settings), isNotNull);

    // liveListenable 在真实分组渲染时触发一次占用测量。
    expect(section.liveListenable, isNotNull);
    section.liveListenable!(settings);
    await tester.pump();
    await tester.pump();

    expect(FushiByteFormat.bytes(1536), '1.5 KB');
    expect(item.resolveSubtitle(settings), contains('1.5 KB'));
  });

  testWidgets('确认框显示占用，进度框展示当前步骤，完成后 toast 释放量且不重启', (
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

    final Completer<MangaCacheClearStepResult> pending =
        Completer<MangaCacheClearStepResult>();
    final _FakeStep step = _FakeStep(
      id: 'fixture',
      label: 'Fixture cache',
      measured: 2048,
      onClear: () => pending.future,
    );
    debugBuildMangaCacheClearService = (SettingsContext _) =>
        MangaCacheClearService(steps: <MangaCacheClearStep>[step]);

    final SettingsStatusItem item = clearItem(locationSection());
    final Future<void> action = Future<void>.sync(
      () => item.resolveAction(settings)!(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('清除缓存？'), findsOneWidget);
    expect(
      find.textContaining(FushiByteFormat.bytes(2048)),
      findsOneWidget,
      reason: '确认框必须显示当前占用',
    );

    await tester.tap(find.text('清除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(t.cache_clear_progress_title), findsOneWidget);
    expect(find.text('Fixture cache'), findsOneWidget);

    pending.complete(
      const MangaCacheClearStepResult(id: 'fixture', freedBytes: 2048),
    );
    await tester.pumpAndSettle();

    expect(find.text(t.cache_clear_done(size: '2.0 KB')), findsOneWidget);
    expect(lifecycle.restartCalled, isFalse, reason: '清缓存不需要重启');
    await action;
    // 让 toast 自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('部分文件删除失败时继续清理并提示部分成功与释放量', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );

    debugBuildMangaCacheClearService = (SettingsContext _) =>
        MangaCacheClearService(
          steps: <MangaCacheClearStep>[
            _FakeStep(
              id: 'fixture',
              label: 'Fixture cache',
              measured: 1024,
              onClear: () async => const MangaCacheClearStepResult(
                id: 'fixture',
                freedBytes: 1024,
                failedEntries: 2,
              ),
            ),
          ],
        );

    final SettingsStatusItem item = clearItem(locationSection());
    final Future<void> action = Future<void>.sync(
      () => item.resolveAction(settings)!(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(
      find.text(t.cache_clear_partial(size: '1.0 KB')),
      findsOneWidget,
      reason: '部分成功必须提示释放量',
    );
    await action;
    // 让 toast 自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('WebView profile 无法安全清理时跳过并提示部分成功', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    FushiToast.navigatorKey = navKey;
    final SettingsContext settings = await captureContext(
      tester,
      navigatorKey: navKey,
    );

    debugBuildMangaCacheClearService = (SettingsContext _) =>
        MangaCacheClearService(
          steps: <MangaCacheClearStep>[
            MangaWebViewCacheClearStep(
              id: 'webview_http',
              label: 'WebView cache',
              profiles: <MangaWebViewCacheProfile>[
                MangaWebViewCacheProfile(
                  id: 'default',
                  sessionSource: MangaWebViewCacheSessionSource(
                    openHeadless: () async =>
                        _FakeWebViewCacheSession(clearError: StateError('CDP')),
                  ),
                ),
                MangaWebViewCacheProfile(
                  id: 'manga',
                  sessionSource: MangaWebViewCacheSessionSource(
                    openHeadless: () async => _FakeWebViewCacheSession(),
                  ),
                ),
              ],
            ),
          ],
        );

    final SettingsStatusItem item = clearItem(locationSection());
    final Future<void> action = Future<void>.sync(
      () => item.resolveAction(settings)!(settings),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(
      find.text(t.cache_clear_partial(size: '0 B')),
      findsOneWidget,
      reason: 'WebView 某 profile 失败不应当作整体失败',
    );
    await action;
    // 让 toast 自动消失计时器跑完，避免 pending-timer。
    await tester.pump(const Duration(seconds: 3));
  });
}

class _FakeWebViewCacheSession implements MangaWebViewCacheSession {
  _FakeWebViewCacheSession({this.clearError});

  @override
  String get profileId => 'fixture';

  final Error? clearError;
  bool disposed = false;

  @override
  Future<void> clearHttpCache() async {
    final Error? error = clearError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

class _FakeStep extends MangaCacheClearStep {
  _FakeStep({
    required this.id,
    required this.label,
    required this.measured,
    required this.onClear,
  });

  @override
  final String id;

  @override
  final String label;

  final int measured;
  final Future<MangaCacheClearStepResult> Function() onClear;

  @override
  Future<int> measureBytes() async => measured;

  @override
  Future<MangaCacheClearStepResult> clear() async => onClear();
}
