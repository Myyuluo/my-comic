import 'package:flutter/widgets.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// 设置首页唯一连续分组的稳定 key：窄屏分组卡与宽屏左侧导航列表共用。
const ValueKey<String> settingsHomeGroupKey = ValueKey<String>(
  'settings-home-group',
);

/// 设置首页的连续分组单元。一级分组标题（界面 / 内容 / 连接 / 应用）已移除，
/// 分组只承载按 schema 顺序排列的二级分类。
class SettingsNavigationGroup {
  SettingsNavigationGroup(Iterable<SettingsDestination> destinations)
    : destinations = List<SettingsDestination>.unmodifiable(destinations);

  final List<SettingsDestination> destinations;
}

/// 接收经过平台和模块门控后的列表，保留 schema 顺序返回唯一的连续分组；
/// 空输入返回空列表，渲染器据此不画空分组卡。
List<SettingsNavigationGroup> groupSettingsDestinations(
  List<SettingsDestination> destinations,
) {
  if (destinations.isEmpty) return const <SettingsNavigationGroup>[];
  return <SettingsNavigationGroup>[SettingsNavigationGroup(destinations)];
}
