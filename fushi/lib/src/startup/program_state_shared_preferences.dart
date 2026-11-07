import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fushi/src/startup/json_file_shared_preferences.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

/// Program state root 下 `state/shared_preferences.json` 的文件名。
const String kProgramStateSharedPreferencesFileName = 'shared_preferences.json';

/// 把桌面端 SharedPreferences 落到 `<programState>/state/shared_preferences.json`。
///
/// 必须在进程内**第一次** `SharedPreferences.getInstance()` 之前调用（插件会缓存
/// 首次读到的整份数据）；重复调用幂等。移动端平台 store 自身就落在 app 私有沙盒，
/// 不替换。
///
/// 返回是否已处于文件存储状态。
bool isolateSharedPreferencesUnderProgramStateRoot({
  Directory? programStateRoot,
  bool? isDesktop,
}) {
  if (!(isDesktop ?? isDesktopPlatform)) return false;
  if (SharedPreferencesStorePlatform.instance
      is JsonFileSharedPreferencesStore) {
    return true;
  }
  final Directory? root =
      programStateRoot ?? AppPaths.programStateRootDirectorySync();
  if (root == null) return false;
  final Directory state =
      Directory(p.join(root.path, AppPaths.stateDirName));
  try {
    state.createSync(recursive: true);
  } on FileSystemException {
    return false;
  }
  SharedPreferencesStorePlatform.instance = JsonFileSharedPreferencesStore(
    File(p.join(state.path, kProgramStateSharedPreferencesFileName)),
  );
  return true;
}
