import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/updates/update_check_scheduler.dart';
import 'package:fushi/src/updates/update_feed_service.dart';
import 'package:fushi_engine/updates/update_feed_kind.dart';

/// v101 后台检查调度：到期判据、开关门控、失败照样记时刻、重入保护。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late DateTime clock;

  Future<PreferencesRepository> makePrefs() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository repo = PreferencesRepository(db);
    await repo.loadFromDb();
    return repo;
  }

  setUp(() {
    clock = DateTime.utc(2026, 9, 9, 12);
  });

  test('第一次运行即到期；跑过之后在间隔内不再跑', () async {
    prefs = await makePrefs();
    int calls = 0;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => true,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async => calls++,
      },
      now: () => clock,
    );

    expect(scheduler.isDue(UpdateFeedKind.mangaChapter), isTrue,
        reason: '没查过就是到期——第一次运行必须查一次');
    await scheduler.runDue();
    expect(calls, 1);

    clock = clock.add(const Duration(hours: 1));
    await scheduler.runDue();
    expect(calls, 1, reason: '漫画间隔 24 小时，一小时后不该再查');

    clock = clock.add(const Duration(hours: 22)); // 距上次 23 小时
    await scheduler.runDue();
    expect(calls, 1, reason: '没到 24 小时仍然不查');

    clock = clock.add(const Duration(hours: 1)); // 距上次 24 小时
    await scheduler.runDue();
    expect(calls, 2);
  });

  test('域开关关掉：既不跑 probe，也不记时刻（开回来立即到期）', () async {
    prefs = await makePrefs();
    int calls = 0;
    bool enabled = false;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => enabled,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async => calls++,
      },
      now: () => clock,
    );

    await scheduler.runDue();
    expect(calls, 0);

    enabled = true;
    await scheduler.runDue();
    expect(calls, 1, reason: '开关打开后应立刻补一次——关着的那段时间不算查过');
  });

  test('probe 抛异常：不炸调度器，且照样记时刻（断网时不连击源站）', () async {
    prefs = await makePrefs();
    int calls = 0;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => true,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async {
          calls++;
          throw StateError('source down');
        },
      },
      now: () => clock,
    );

    await scheduler.runDue();
    expect(calls, 1);

    clock = clock.add(const Duration(minutes: 30));
    await scheduler.runDue();
    expect(calls, 1, reason: '失败也算问过了，半小时后不该重试');
  });

  test('checkNow 绕过到期判据，但不绕过开关', () async {
    prefs = await makePrefs();
    int calls = 0;
    bool enabled = true;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => enabled,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async => calls++,
      },
      now: () => clock,
    );

    await scheduler.runDue();
    await scheduler.checkNow(UpdateFeedKind.mangaChapter);
    expect(calls, 2, reason: '「立即检查」必须无视间隔');

    enabled = false;
    await scheduler.checkNow(UpdateFeedKind.mangaChapter);
    expect(calls, 2, reason: '关掉的域连手动检查也不跑');
  });

  test('漫画新章提醒默认关闭：后台 probe 不跑，开启后才跑', () async {
    prefs = await makePrefs();
    final UpdateFeedService feed = UpdateFeedService(database: db, prefs: prefs);
    int calls = 0;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      // 生产装配：调度器直接用服务层的开关判据（AppModel.startUpdateChecks）。
      isKindEnabled: feed.isKindEnabled,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaChapter: () async => calls++,
      },
      now: () => clock,
    );

    await scheduler.runDue();
    expect(calls, 0,
        reason: '未存偏好 = 默认关闭；探针不跑，更新中心条目 / 通知 / 自动下载也就都不会发生');
    expect(
      prefs.containsKey(updateLastCheckPrefKey(UpdateFeedKind.mangaChapter)),
      isFalse,
      reason: '没查过就不该记「查过了」，否则用户开启后要白等 24 小时',
    );

    await feed.setKindEnabled(UpdateFeedKind.mangaChapter, true);
    await scheduler.runDue();
    expect(calls, 1, reason: '用户开启后立即补一次');
  });

  test('漫画扩展域默认仍开启：启动轮照常跑 probe', () async {
    prefs = await makePrefs();
    final UpdateFeedService feed = UpdateFeedService(database: db, prefs: prefs);
    int calls = 0;
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: feed.isKindEnabled,
      probes: <UpdateFeedKind, UpdateProbe>{
        UpdateFeedKind.mangaExtension: () async => calls++,
      },
      now: () => clock,
    );

    await scheduler.runDue();
    expect(calls, 1, reason: '扩展更新提醒默认值保持不变');
  });

  test('没有登记 probe 的域不跑（番剧走自己的相位节奏）', () async {
    prefs = await makePrefs();
    final UpdateCheckScheduler scheduler = UpdateCheckScheduler(
      prefs: prefs,
      isKindEnabled: (_) => true,
      probes: const <UpdateFeedKind, UpdateProbe>{},
      now: () => clock,
    );
    expect(scheduler.isDue(UpdateFeedKind.videoEpisode), isFalse,
        reason: 'videoEpisode 不在 intervals 里，恒不到期');
    await scheduler.runDue();
  });
}
