import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:my_comic/src/utils/misc/official_links.dart';
import 'package:my_comic/src/utils/misc/platform_updater.dart';
import 'package:my_comic_engine/utils/net/app_user_agent.dart';

/// Ticket 09：用户可见身份与 Windows 安装/运行身份统一为 MyComic。
///
/// 这些断言覆盖 Dart 侧能独立验证的身份值：对外 User-Agent、官网/更新链接、
/// 更新资产前缀、Windows runner 标题/互斥量、安装器与 CI 产物名。真正的窗口、
/// 快捷方式和通知行为仍由 Windows 构建 + 冷启动冒烟验收。
void main() {
  String readRepoFile(String relative) {
    final File file = File(relative);
    expect(file.existsSync(), isTrue, reason: 'missing $relative');
    return file.readAsStringSync().replaceAll('\r\n', '\n');
  }

  test('outbound User-Agent reports MyComic, not the upstream name', () {
    final String ua = myComicUserAgent('custom-fonts');
    expect(ua, startsWith('mycomic/custom-fonts '));
    expect(ua, contains('github.com/Myyuluo/my-comic'));
    expect(ua.toLowerCase(), isNot(contains('mycomic.moe')));
  });

  test('official links stay inside the fork repository', () {
    expect(kOfficialWebsiteUrl, 'https://github.com/Myyuluo/my-comic');
    expect(kOfficialDownloadPageUrl, '$kOfficialWebsiteUrl/releases');
    expect(kOfficialWebsiteUrl, isNot(contains('mycomic.moe')));
  });

  test('update assets use the mycomic- prefix and reject unrelated prefixes',
      () {
    expect(kMyComicAssetPrefix, 'mycomic-');
    expect(assetBelongsToThisProduct('mycomic-1.0.0-windows-setup.exe'), isTrue);
    expect(assetBelongsToThisProduct('other-1.0.0-windows-setup.exe'), isFalse);
    expect(
      synthesizeStableAssetNames('1.0.0'),
      contains('mycomic-1.0.0-windows-setup.exe'),
    );
  });

  test('installer uses MyComic identity while keeping the same AppId', () {
    final String iss = readRepoFile('windows/installer/mycomic.iss');
    expect(iss, contains('AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}'));
    expect(iss, contains('AppName=MyComic'));
    expect(iss, contains(r'DefaultDirName={localappdata}\MyComic'));
    expect(iss, contains('DefaultGroupName=MyComic'));
    expect(iss, contains('UsePreviousAppDir=no'));
    expect(
      iss,
      contains(r'OutputBaseFilename=mycomic-{#AppVersion}-windows-setup'),
    );
    expect(iss, contains(r'Name: "{group}\MyComic"'));
    expect(iss, contains(r'Name: "{userdesktop}\MyComic"'));
    expect(iss, isNot(contains('URL:MyComic Lookup')));
    // Old protocol key may still appear once as an unconditional cleanup entry,
    // but it must never be registered as a URL handler again.
    expect(iss, isNot(contains('ValueName: "URL Protocol"')));
    expect(iss, isNot(contains(r'Software\Classes\my_comic\shell\open\command')));
  });

  test('Windows runner looks up the MyComic window and mutex', () {
    final String main = readRepoFile('windows/runner/main.cpp');
    expect(main, contains('L"MyComicSingleInstanceMutex"'));
    expect(main, contains('::FindWindowW(nullptr, L"MyComic")'));
    expect(main, contains('dev_side_by_side ? L"MyComic Dev" : L"MyComic"'));
  });

  test('release workflow names assets and titles after MyComic', () {
    final String workflow =
        readRepoFile('../.github/workflows/release-desktop.yml');
    expect(workflow, contains(r'ASSET_GLOB: mycomic-*-windows-setup.exe'));
    expect(workflow, contains('mycomic-*-windows-setup.exe'));
    expect(workflow, contains(r'NAME="${NAME:-MyComic '));
  });
}
