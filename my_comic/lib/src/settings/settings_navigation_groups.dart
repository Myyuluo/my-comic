import 'package:flutter/widgets.dart';
import 'package:my_comic/src/settings/settings_destination.dart';

/// 设置首页唯一连续分组的稳定 key：窄屏分组卡与宽屏左侧导航列表共用。
const ValueKey<String> settingsHomeGroupKey = ValueKey<String>(
  'settings-home-group',
);

/// 接收经过平台和模块门控后的列表，保留 schema 顺序返回只读的扁平列表。
///
/// 一级分组（界面 / 内容 / 连接 / 应用）已移除，首页只剩一张连续分组卡，
/// 所以不再需要「分组对象」这层中间人（review D4）；空输入返回空列表，
/// 渲染器据此不画空分组卡。
List<SettingsDestination> groupSettingsDestinations(
  List<SettingsDestination> destinations,
) {
  if (destinations.isEmpty) return const <SettingsDestination>[];
  return List<SettingsDestination>.unmodifiable(destinations);
}
