import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ticket 03：系统与关于的「启动页」设置入口已移除（反馈 #PwEC1evz1E 的 UI 下线），
/// 但已存偏好与启动落地逻辑保留——删的只是设置行，不是启动页能力。
void main() {
  test('startup page settings row is gone from the system schema', () {
    final String schema = File(
      'lib/src/settings/settings_schema_system.dart',
    ).readAsStringSync();

    expect(
      schema,
      isNot(contains("id: 'appearance.startup_default_dictionary_tab'")),
      reason: '「启动页」行不再出现在系统与关于 › 通用',
    );
    expect(schema, isNot(contains('t.startup_module')));
    expect(schema, isNot(contains('_startupModuleOptions')));
    expect(schema, isNot(contains('_startupModuleToken')));
    expect(schema, isNot(contains('setStartupModule(')),
        reason: '设置行是 setStartupModule 的唯一 UI 消费者；能力本身保留在 AppModel');
  });

  test('stored startup preference and startup fallback behavior are preserved', () {
    final String appModel = File('lib/src/models/app_model.dart').readAsStringSync();
    expect(appModel, contains('ModuleId? get startupModule'));
    expect(appModel, contains('Future<void> setStartupModule('));

    final String moduleId = File('lib/src/models/module_id.dart').readAsStringSync();
    expect(moduleId, contains("startupPrefKey = 'startup_module'"));

    final String preferences =
        File('lib/src/models/preferences_repository.dart').readAsStringSync();
    expect(preferences, contains('ModuleId? get startupModule'));
    expect(preferences, contains('Future<void> setStartupModule('));

    final String homePage =
        File('lib/src/pages/implementations/home_page.dart').readAsStringSync();
    expect(homePage, contains('homeInitialTab('),
        reason: '启动落地与回退仍走 homeInitialTab');
  });

  test('removed startup page i18n keys are gone from every locale', () {
    final List<File> files = Directory('lib/i18n')
        .listSync()
        .whereType<File>()
        .where((File file) => file.path.endsWith('.i18n.json'))
        .toList(growable: false);
    expect(files.length, 17, reason: '全部 17 个 locale 必须同步');

    for (final File file in files) {
      final String contents = file.readAsStringSync();
      for (final String key in <String>[
        '"startup_module"',
        '"startup_module_hint"',
        '"startup_module_default"',
      ]) {
        expect(
          contents,
          isNot(contains(key)),
          reason: '${file.path} 仍残留已下线的启动页文案 $key',
        );
      }
    }
  });
}
