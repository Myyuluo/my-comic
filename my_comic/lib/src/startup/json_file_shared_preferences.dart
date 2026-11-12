import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// 整份 JSON 落单文件的 `SharedPreferencesStorePlatform` 实现。
///
/// 桌面端 `shared_preferences` 默认把 JSON 写在 `getApplicationSupportDirectory()`
/// （Windows = `%APPDATA%\<pkg>`）。my-comic 的 Program state root 要求 prefs 与
/// 数据库、Mihon runtime 一起住在 `<programState>/state/`，因此启动早期用本类替换
/// 平台 store。
///
/// 写盘走「临时文件 + rename」，避免进程被杀时留下半截 JSON。测试根隔离
/// （`isolateSharedPreferencesUnderTestRoot`）与生产程序状态根共用同一实现。
class JsonFileSharedPreferencesStore extends SharedPreferencesStorePlatform {
  JsonFileSharedPreferencesStore(this.file);

  final File file;
  Map<String, Object>? _cache;

  static const String _defaultPrefix = 'flutter.';

  Map<String, Object> _read() {
    final Map<String, Object>? cached = _cache;
    if (cached != null) return cached;
    final Map<String, Object> data = <String, Object>{};
    if (file.existsSync()) {
      final String raw = file.readAsStringSync();
      if (raw.trim().isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((Object? key, Object? value) {
            if (key is! String || value == null) return;
            data[key] = value is List ? value.cast<String>().toList() : value;
          });
        }
      }
    }
    return _cache = data;
  }

  bool _write(Map<String, Object> data) {
    file.parent.createSync(recursive: true);
    final File staging = File('${file.path}.tmp');
    staging.writeAsStringSync(jsonEncode(data), flush: true);
    staging.renameSync(file.path);
    return true;
  }

  bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) &&
      (filter.allowList == null || filter.allowList!.contains(key));

  @override
  Future<bool> remove(String key) async {
    final Map<String, Object> data = _read();
    data.remove(key);
    return _write(data);
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final Map<String, Object> data = _read();
    data[key] = value;
    return _write(data);
  }

  @override
  Future<bool> clear() => clearWithParameters(
        ClearParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
      );

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final Map<String, Object> data = _read();
    data.removeWhere((String key, _) => _matches(key, parameters.filter));
    return _write(data);
  }

  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(
        GetAllParameters(filter: PreferencesFilter(prefix: _defaultPrefix)),
      );

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final Map<String, Object> result = Map<String, Object>.from(_read());
    result.removeWhere((String key, _) => !_matches(key, parameters.filter));
    return result;
  }
}
