import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-898：应用更新手动检查源码守卫（manga-only shell 之后）。
///
/// 不变量：
/// - 上游 MyComic 的 `system.check_update_now` / `system.update_auto_install`
///   设置行已随 manga-only shell 移除，不得重新出现在系统设置 schema。
/// - 编排函数 `checkAppUpdateNow`（`updates/app_update_check.dart`，更新中心与
///   反馈流程共用）传 `neverRemind: false` + `autoInstall: false`（手动语义，防
///   回归成「点一下就静默自动装」/「被免提醒吞掉」）。
/// - 防连点靠模块级 `_manualCheckInFlight` 旗标。
/// - 更新中心的 app 新版本条目落到同一条应用内链路，不 `launchUrl` 跳浏览器。
/// - `UpdateChecker.scheduleCheck` 仍带默认 null 的 onUpToDate/onError 回调
///   （向后兼容，自动检查零变化）。
void main() {
  test('manga-only system settings do not expose app-update rows', () {
    // ff3f2df0（manga-only shell）移除了上游 MyComic 的应用更新设置分区；应用
    // 更新入口只保留在更新中心与反馈流程。这个守卫防止把已移除的设置行加回来。
    final String src =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    expect(src, isNot(contains("id: 'system.check_update_now'")));
    expect(src, isNot(contains("id: 'system.update_auto_install'")));
    expect(src, isNot(contains('title: t.settings_check_update_now')));
  });

  test('manual orchestration uses manual semantics (no silent auto-install)',
      () {
    final String src =
        File('lib/src/updates/app_update_check.dart').readAsStringSync();
    final String orchestration = _functionSource(
      src,
      'Future<void> checkAppUpdateNow(',
      'UpdateChannel appUpdateChannelOf(',
    );
    // 应用更新设置入口已随 manga-only shell 移除；手动编排由更新中心 /
    // 反馈流程调用。
    expect(orchestration, contains('neverRemind: false'), reason: '手动检查无视免提醒');
    expect(orchestration, contains('autoInstall: false'),
        reason: '手动检查走确认弹窗，不静默自动装');
    expect(orchestration, contains('onUpToDate:'));
    expect(orchestration, contains('onError:'));
    expect(orchestration, contains('t.update_checking_now'), reason: '点击即时反馈');
    expect(orchestration, contains('t.update_already_latest'));
    expect(orchestration, contains('t.update_check_failed'));
    // 防连点旗标。
    expect(src, contains('bool _manualCheckInFlight = false;'));
    // 在飞时不是静默早退：更新中心 / 系统通知也从这里进来，得有一句反馈。
    expect(orchestration, contains('if (_manualCheckInFlight) {'));
    expect(orchestration, contains('_manualCheckInFlight = true;'));
    expect(orchestration, contains('_manualCheckInFlight = false;'));
  });

  test('updates center lands app release on in-app update, not the browser',
      () {
    final String src =
        File('lib/src/pages/implementations/updates_center_open.dart')
            .readAsStringSync();
    final String appRelease = _functionSource(
      src,
      'case UpdateFeedKind.appRelease:',
      'case UpdateFeedKind.videoEpisode:',
    );
    expect(appRelease, contains('checkAppUpdateNow('),
        reason: 'app 新版本必须走应用内检查 → 下载 → 安装');
    expect(src, isNot(contains('launchUrl(')),
        reason: '更新中心的落点全在 app 内，不该把用户送到浏览器');
  });

  test('update dialog / download are one per-version exclusive flow', () {
    // BUG-2487 审查：启动期自动检查弹对话框的同时更新中心 toast 已发出，点 toast
    // 触发第二轮检查——不按版本互斥就是两个「发现新版本」叠在一起。
    final String src = File('lib/src/utils/misc/update_checker_release.dart')
        .readAsStringSync();
    final String check = _functionSource(
      src,
      'static Future<void> _check(',
      'static Future<bool> _shouldBackOffWindowsAutoInstall(',
    );
    expect('_notifyIfUpdateFlowActive(context, version)'.allMatches(check),
        hasLength(2),
        reason: '有包 / 无包两条弹框路径都要先问该版本的流是否已活跃');
    for (final String fn in <String>[
      'static Future<void> _showUpdateDialog(',
      'static Future<void> _showFallbackDialog(',
      'static Future<void> _downloadAndInstall(',
    ]) {
      final int at = src.indexOf(fn);
      expect(at, isNonNegative, reason: fn);
      final String body = src.substring(at, at + 1200);
      expect(body, contains('_runExclusiveUpdateFlow('), reason: '$fn 必须走互斥流');
      expect(body, contains('_updateFlowKey(version)'),
          reason: '$fn 必须挂在同一把版本锁上');
    }
  });

  test('scheduleCheck keeps default-null callbacks (auto-check unchanged)', () {
    final String src = File('lib/src/utils/misc/update_checker_release.dart')
        .readAsStringSync();
    expect(src, contains('void Function()? onUpToDate,'));
    expect(src, contains('void Function(Object error)? onError,'));
    // 三条「无可更新版本」早退都要触发 onUpToDate（必修1）。
    final int upToDateCalls = 'onUpToDate?.call();'.allMatches(src).length;
    expect(upToDateCalls, greaterThanOrEqualTo(3),
        reason: 'onUpToDate 必须覆盖三条无更新早退（selection==null / tag空 / 已最新）');
    expect(src, contains('onError?.call(e)'), reason: 'onError 挂在 catch 分支');
    // 可注入 fetcher seam（必修2），不拆网络层。
    expect(src, contains('fetchReleases'));
    expect(
        src,
        contains(
            'await (fetchReleases ?? _fetchReleasesForChannel)(client, channel)'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
