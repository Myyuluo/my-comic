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
  test('all visible destinations form one continuous group in schema order', () {
    final List<SettingsDestination> visible = <SettingsDestination>[
      destination(SettingsDestinationId.appearance, '外观与交互'),
      destination(SettingsDestinationId.manga, '漫画'),
      destination(SettingsDestinationId.downloads, '下载'),
      destination(SettingsDestinationId.system, '系统与关于'),
    ];

    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      visible,
    );

    // 设置首页不再按「界面 / 内容 / 连接 / 应用」切一级分组：所有二级分类
    // 收进唯一一个连续分组，顺序完全跟随 schema。
    expect(groups, hasLength(1));
    expect(groups.single.destinations, visible);
    expect(() => groups.single.destinations.clear(), throwsUnsupportedError);
  });

  test('empty input yields no group (no empty heading or card)', () {
    expect(groupSettingsDestinations(const <SettingsDestination>[]), isEmpty);
  });
}
