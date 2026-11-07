import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 桌面端**原地改名升级**的数据连续性守卫。
///
/// 桌面不是跨包名迁移：同一个 Inno AppId、同一个安装目录、覆盖安装。用户什么都
/// 不做，app 就从 Hibiki 变成 Fushi。可 `path_provider` 的 app-support 根是**从
/// 二进制身份推出来的**：
///
/// - Windows `%APPDATA%\<CompanyName>\<ProductName>` ← `windows/runner/Runner.rc`
/// - macOS `~/Library/Application Support/<CFBundleIdentifier>`
///   ← `macos/Runner/Configs/AppInfo.xcconfig`
/// - Linux XDG_DATA_HOME 下的 `<APPLICATION_ID>` ← `linux/CMakeLists.txt`
///
/// 主库、`shared_preferences.json`（自定义数据根的**唯一**指针）、TLS 私钥全在这
/// 个根下。身份一改，路径就改，用户打开的是一个空 app —— 而且**没有任何报错**，
/// `flutter analyze` 与所有功能测试都照绿。唯一的防线是
/// `lib/src/storage/legacy_support_dir_migration.dart` 里那份「旧身份 → 新身份」
/// 对照表；本守卫的职责是：**任何一处身份再被改动，这份对照表必须同一个 commit
/// 里跟着改**，否则红。
///
/// 每条断言都从各自的真相源现读现比，不复制常量。
void main() {
  final File runnerRc = File('windows/runner/Runner.rc');
  final File macosAppInfo = File('macos/Runner/Configs/AppInfo.xcconfig');
  final File linuxCMake = File('linux/CMakeLists.txt');
  final File migration =
      File('lib/src/storage/legacy_support_dir_migration.dart');
  final File mainDart = File('lib/main.dart');

  /// Runner.rc 的 VERSIONINFO 字段（形如 VALUE "Key", "Value" 后跟 NUL 串）。
  String? versionInfoValue(String rc, String key) => RegExp(
        r'VALUE\s+"' + key + r'"\s*,\s*"([^"]*)"',
      ).firstMatch(rc)?.group(1);

  /// xcconfig 一行：KEY = value。
  String? xcconfigValue(String source, String key) => RegExp(
        r'^\s*' + key + r'\s*=\s*(\S+)\s*' + r'$',
        multiLine: true,
      ).firstMatch(source)?.group(1);

  /// CMake 一行：set(NAME "value")。
  String? cmakeSetValue(String source, String name) => RegExp(
        r'^\s*set\(\s*' + name + r'\s+"([^"]*)"\s*\)',
        multiLine: true,
      ).firstMatch(source)?.group(1);

  /// Dart 顶层字符串常量：const String NAME = 'value';
  String? dartStringConst(String source, String name) => RegExp(
        r'const\s+String\s+' + name + r"\s*=\s*'([^']*)'\s*;",
      ).firstMatch(source)?.group(1);

  /// Dart 顶层字符串列表常量。
  List<String>? dartStringListConst(String source, String name) {
    final RegExpMatch? match = RegExp(
      r'const\s+List<String>\s+' + name + r'\s*=\s*<String>\[([^\]]*)\]\s*;',
    ).firstMatch(source);
    if (match == null) return null;
    return RegExp(r"'([^']*)'")
        .allMatches(match.group(1)!)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
  }

  test('Windows：Runner.rc 的 CompanyName/ProductName 就是搬迁目标的两段', () {
    final String rc = runnerRc.readAsStringSync();
    final String? company = versionInfoValue(rc, 'CompanyName');
    final String? product = versionInfoValue(rc, 'ProductName');
    expect(company, isNotNull, reason: 'Runner.rc 必须声明 CompanyName。');
    expect(product, isNotNull, reason: 'Runner.rc 必须声明 ProductName。');

    final List<String>? target = dartStringListConst(
        migration.readAsStringSync(), 'kFushiWindowsAppDataSegments');
    expect(target, isNotNull,
        reason: 'legacy_support_dir_migration.dart 必须声明 '
            'kFushiWindowsAppDataSegments。');
    expect(
      target,
      <String>[company!, product!],
      reason: 'path_provider 在 Windows 上把 app-support 根解析成 APPDATA 下的 '
          'CompanyName/ProductName 两段，两个字符串取自 exe 版本资源。Runner.rc '
          '改了而搬迁代码没跟着改，存量用户的主库与 shared_preferences.json'
          '（自定义数据根的唯一指针）就会留在旧目录，app 静默打开一个空库。'
          '改名时必须同一个 commit 里更新 kFushiWindowsAppDataSegments，'
          '并把上一代身份加进旧根清单。',
    );
  });

  test('macOS：AppInfo.xcconfig 的 bundle id 就是搬迁目标目录名', () {
    final String? bundleId = xcconfigValue(
        macosAppInfo.readAsStringSync(), 'PRODUCT_BUNDLE_IDENTIFIER');
    expect(bundleId, isNotNull,
        reason: 'AppInfo.xcconfig 必须声明 PRODUCT_BUNDLE_IDENTIFIER。');

    final String source = migration.readAsStringSync();
    expect(
      dartStringConst(source, 'kFushiMacosBundleId'),
      bundleId,
      reason: 'macOS 的 app-support 根是 Library/Application Support 下以 '
          'CFBundleIdentifier 命名的目录。bundle id 改了而 kFushiMacosBundleId '
          '没跟着改，搬迁会认不出新根、直接 no-op。',
    );
    expect(
      dartStringConst(source, 'kLegacyMacosBundleId'),
      isNot(bundleId),
      reason: '旧 bundle id 必须与当前的不同，否则搬迁会把自己搬给自己。',
    );
  });

  test('Linux：CMake 身份与搬迁对照表的新身份一致（改身份必须同步补搬迁）', () {
    final String cmake = linuxCMake.readAsStringSync();
    final String? applicationId = cmakeSetValue(cmake, 'APPLICATION_ID');
    expect(applicationId, isNotNull,
        reason: 'linux/CMakeLists.txt 必须声明 APPLICATION_ID。');

    final String migrationSrc = migration.readAsStringSync();
    expect(
      applicationId,
      dartStringConst(migrationSrc, 'kFushiLinuxApplicationId'),
      reason: 'path_provider 在 Linux 上把 app-support 根解析成 XDG_DATA_HOME '
          '下以 APPLICATION_ID 命名的目录。PR #790 把 Linux 身份改成 fushi 后，'
          'legacy_support_dir_migration.dart 已补 Linux 搬迁分支——CMake 再改'
          '身份，这里的新身份常量必须同一个 commit 跟上，否则 Linux 用户的库'
          '会静默消失。',
    );
    expect(
      dartStringConst(migrationSrc, 'kLegacyLinuxApplicationId'),
      'com.example.hibiki',
      reason: '旧身份是历史事实（存量安装的落盘目录名），永远不许改。',
    );
  });

  test('fresh start：main() 不搬、不读旧 app-support / prefs 域', () {
    final String source = mainDart.readAsStringSync();
    expect(source.contains('migrateLegacySupportDir'), isFalse,
        reason: 'Ticket 01 起旧 Fushi/Hibiki 数据一律忽略，启动不得再搬旧根。');
    expect(source.contains('recoverLegacyMacosPrefs'), isFalse,
        reason: '旧 NSUserDefaults 域里的数据根锚点同样不得再被捞回。');

    // prefs store 必须抢在任何 SharedPreferences 读取之前装好（Ticket 01 起
    // 落 Program state root 的 state/）。
    final int storeInstallIndex =
        source.indexOf('isolateSharedPreferencesUnderProgramStateRoot();');
    final int firstPrefsUse =
        source.indexOf('DesktopWindowPlacement.applyInitialPlacement(');
    expect(storeInstallIndex, greaterThan(0),
        reason: 'main() 必须安装 Program state root 的 prefs store。');
    expect(firstPrefsUse, greaterThan(0),
        reason: '找不到 DesktopWindowPlacement.applyInitialPlacement( —— 守卫已'
            '失效，请重新确定 main() 里第一个读 SharedPreferences 的调用。');
    expect(storeInstallIndex, lessThan(firstPrefsUse),
        reason: 'prefs store 必须早于第一次 SharedPreferences 读取，否则会先在'
            '平台默认位置缓存一份。');
  });
}
