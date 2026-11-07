import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fushi/src/startup/json_file_shared_preferences.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/storage/app_paths.dart';

export 'package:fushi/src/startup/json_file_shared_preferences.dart'
    show JsonFileSharedPreferencesStore;

/// 测试根下 SharedPreferences 的文件名（与桌面插件的默认文件名一致，方便取证对照）。
const String kTestRootSharedPreferencesFileName = 'shared_preferences.json';

/// 兼容旧引用：测试根与生产程序状态根共用同一个 JSON 文件 store。
typedef TestRootSharedPreferencesStore = JsonFileSharedPreferencesStore;

/// `FUSHI_TEST_ROOT` 生效时，把桌面端 SharedPreferences 换成落在
/// `<测试根>/userdata/state/shared_preferences.json` 的文件存储。
///
/// 为什么需要：Drift / [AppPaths] 早就按测试根隔离了，但 SharedPreferences 不是——
/// Windows 插件经 `SHGetKnownFolderPath(RoamingAppData)` 取目录，不看
/// `run_windows_itest.ps1` 改掉的 `APPDATA` 环境变量；macOS 走 bundle id 域的
/// NSUserDefaults。于是集成测试写的设置会落进用户真实 prefs。
///
/// 测试根下的目录形态与生产一致：prefs 属于 Program state root 的 `state/`，与
/// 数据库、Mihon runtime 同根。
///
/// 必须在进程内**第一次** `SharedPreferences.getInstance()` 之前调用（插件会缓存
/// 首次读到的整份数据）；重复调用是幂等的。移动端各 app 自带沙盒、不装。
/// 返回是否已处于隔离状态。
bool isolateSharedPreferencesUnderTestRoot({
  Map<String, String>? environment,
  String dartDefineRoot = const String.fromEnvironment('FUSHI_TEST_ROOT'),
  bool? isDesktop,
}) {
  if (SharedPreferencesStorePlatform.instance
      is JsonFileSharedPreferencesStore) {
    return true;
  }
  final bool desktop =
      isDesktop ?? (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  if (!desktop) return false;
  final Directory? programState = fushiTestDirectory(
    'userdata',
    environment: environment,
    dartDefineRoot: dartDefineRoot,
  );
  if (programState == null) return false;
  final File prefsFile = File(p.join(
    programState.path,
    AppPaths.stateDirName,
    kTestRootSharedPreferencesFileName,
  ));
  SharedPreferencesStorePlatform.instance =
      JsonFileSharedPreferencesStore(prefsFile);
  return true;
}
