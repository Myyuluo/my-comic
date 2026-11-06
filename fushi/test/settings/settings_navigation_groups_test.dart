import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';

SettingsDestination destination(SettingsDestinationId id, String title) =>
    SettingsDestination(
      id: id,
      title: title,
      icon: Icons.settings,
      sections: const <SettingsSection>[],
    );

void main() {
  test('visible destinations stay in schema order in one flat list', () {
    final List<SettingsDestination> visible = <SettingsDestination>[
      destination(SettingsDestinationId.appearance, '外观与交互'),
      destination(SettingsDestinationId.manga, '漫画'),
      destination(SettingsDestinationId.downloads, '存储与下载'),
      destination(SettingsDestinationId.system, '系统与关于'),
    ];

    final List<SettingsDestination> ordered = groupSettingsDestinations(
      visible,
    );

    // 设置首页不再按「界面 / 内容 / 连接 / 应用」切一级分组：所有二级分类
    // 收进唯一一张连续分组卡，顺序完全跟随 schema；helper 不再包一层分组对象。
    expect(ordered, visible);
    expect(() => ordered.clear(), throwsUnsupportedError);
  });

  test('empty input yields no rows (no empty heading or card)', () {
    expect(groupSettingsDestinations(const <SettingsDestination>[]), isEmpty);
  });
}
