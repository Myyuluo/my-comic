import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

/// ticket 03：系统与关于 › 通用不再有「访问官网」与「GitHub Sponsors」两行；
/// 保留的 GitHub 行仍打开仓库。侧栏品牌位由 ticket 02 单独覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> launchedUrls = <String>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async {
        if (call.method == 'launch') {
          final Map<Object?, Object?> args =
              Map<Object?, Object?>.from(call.arguments as Map);
          launchedUrls.add(args['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  List<SettingsItem> generalItems() => buildSystemDestination()
      .sections
      .singleWhere((SettingsSection s) => s.id == 'system.section.general')
      .items;

  test('system.website and system.github_sponsors rows are removed', () {
    final List<String> ids =
        generalItems().map((SettingsItem item) => item.id).toList();
    expect(ids, isNot(contains('system.website')));
    expect(ids, isNot(contains('system.github_sponsors')));
    expect(
      ids,
      isNot(contains('appearance.startup_default_dictionary_tab')),
      reason: '启动页行同时下线，但 startup_module 偏好与启动行为保留',
    );
    // 通用分组其余入口保持原位：GitHub 行仍保留（URL 由 ticket 02 改为 fork）。
    expect(ids, contains('system.github'));
  });

  test(
    'system.github opens the my-comic fork, not the upstream repository',
    () async {
      final SettingsActionItem github = generalItems()
          .whereType<SettingsActionItem>()
          .firstWhere((SettingsActionItem i) => i.id == 'system.github');

      await github.onTap(_StubSettingsContext());

      expect(launchedUrls, <String>[kMyComicRepositoryUrl]);
      expect(kMyComicRepositoryUrl, 'https://github.com/Myyuluo/my-comic');
    },
  );

  test('openOfficialDownloadPage 落在下载页，而不是首页', () async {
    expect(await openOfficialDownloadPage(), isTrue);

    // 独立发行版不再指向上游官网；下载入口落在 fork 仓库的 Releases 页。
    expect(launchedUrls, <String>[kOfficialDownloadPageUrl]);
    expect(
      kOfficialDownloadPageUrl,
      'https://github.com/Myyuluo/my-comic/releases',
    );
    expect(
      Uri.parse(kOfficialDownloadPageUrl).host,
      Uri.parse(kOfficialWebsiteUrl).host,
      reason: '下载页 URL 必须属于 fork 仓库域名',
    );
    expect(kOfficialDownloadPageUrl, startsWith(kOfficialWebsiteUrl));
  });
}

class _StubSettingsContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
