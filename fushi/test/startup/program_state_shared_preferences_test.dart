import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fushi/src/startup/program_state_shared_preferences.dart';
import 'package:fushi/src/startup/test_root_shared_preferences.dart';

/// Ticket 01：SharedPreferences 必须落在 Program state root 的 `state/` 下，
/// 与数据库、Mihon runtime 同一个根。
void main() {
  late Directory root;
  late SharedPreferencesStorePlatform original;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fushi_program_state_prefs_');
    original = SharedPreferencesStorePlatform.instance;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferences.resetStatic();
  });

  tearDown(() {
    SharedPreferencesStorePlatform.instance = original;
    SharedPreferences.resetStatic();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('程序状态根：prefs 落到 <programState>/state/shared_preferences.json', () async {
    final Directory programState = Directory(p.join(root.path, 'userdata'))
      ..createSync(recursive: true);

    expect(
      isolateSharedPreferencesUnderProgramStateRoot(
        programStateRoot: programState,
        isDesktop: true,
      ),
      isTrue,
    );

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('manga_reader_mode', 'paged');
    await prefs.setBool('incognito', true);

    final File prefsFile = File(p.join(programState.path, 'state',
        kProgramStateSharedPreferencesFileName));
    expect(prefsFile.existsSync(), isTrue,
        reason: 'prefs 必须落在 Program state root 的 state/ 下');

    final Map<String, dynamic> onDisk =
        jsonDecode(prefsFile.readAsStringSync()) as Map<String, dynamic>;
    expect(onDisk['flutter.manga_reader_mode'], 'paged');
    expect(onDisk['flutter.incognito'], true);

    // 模拟重启：新 store 从同一个 state 文件读回。
    SharedPreferencesStorePlatform.instance =
        TestRootSharedPreferencesStore(prefsFile);
    SharedPreferences.resetStatic();
    final SharedPreferences reopened = await SharedPreferences.getInstance();
    expect(reopened.getString('manga_reader_mode'), 'paged');
    expect(reopened.getBool('incognito'), isTrue);
  });

  test('测试根隔离：prefs 落到 <testRoot>/userdata/state/shared_preferences.json',
      () async {
    expect(
      isolateSharedPreferencesUnderTestRoot(
        environment: <String, String>{'FUSHI_TEST_ROOT': root.path},
        dartDefineRoot: '',
        isDesktop: true,
      ),
      isTrue,
    );
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('k', 'v');

    final File expected = File(p.join(
      root.path,
      'userdata',
      'state',
      kTestRootSharedPreferencesFileName,
    ));
    expect(expected.existsSync(), isTrue);
    expect(expected.readAsStringSync(), contains('flutter.k'));
  });

  test('重复调用幂等，不会换掉已装的 store', () {
    final Directory programState = Directory(p.join(root.path, 'userdata'));
    isolateSharedPreferencesUnderProgramStateRoot(
      programStateRoot: programState,
      isDesktop: true,
    );
    final SharedPreferencesStorePlatform first =
        SharedPreferencesStorePlatform.instance;
    isolateSharedPreferencesUnderProgramStateRoot(
      programStateRoot: programState,
      isDesktop: true,
    );
    expect(identical(SharedPreferencesStorePlatform.instance, first), isTrue);
  });

  test('非桌面 / 无程序状态根：不动平台 store', () {
    final SharedPreferencesStorePlatform before =
        SharedPreferencesStorePlatform.instance;
    expect(
      isolateSharedPreferencesUnderProgramStateRoot(
        programStateRoot: Directory(p.join(root.path, 'userdata')),
        isDesktop: false,
      ),
      isFalse,
    );
    expect(identical(SharedPreferencesStorePlatform.instance, before), isTrue);
  });
}
