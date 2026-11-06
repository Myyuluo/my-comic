import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/settings/settings_search.dart';

import '../helpers/test_platform_services.dart';

/// 「功能模块」关掉一个模块之后，**设置页里属于它的一级分类必须整条消失**——
/// 列表里没有、搜索索引里也没有（用户拍板的隐藏强度：「看不见也到不了」）。
///
/// 这条是四个新模块（听书 / 制卡 / 在线服务 / 同步备份）唯一的落地面证据：它们
/// **没有底栏 tab**，`homeActiveTabs` 那套用例根本咬不到；开关翻转之后能观测到的
/// 全部效果就在这里。`settings_schema_coverage_test.dart` 的 `kCoveredElsewhere`
/// 指向本文件，删了这条会让那边直接红。
///
/// 归属真值是 [moduleOfSettingsDestination]（`module_registry.dart`），本测试
/// **不重抄一份名单**：期望值当场从映射表派生，映射改了这里自动跟着改。
void main() {
  /// 覆写可见性即可——`moduleVisibility` 是全 app 门控的唯一合成点，各 destination
  /// 的 `visible` 谓词读的就是它（`isSettingsDestinationVisible(id, ...)`）。
  late _ModuleGatingAppModel appModel;
  late SettingsContext sctx;

  Future<void> pumpContext(WidgetTester tester) async {
    appModel = _ModuleGatingAppModel();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sctx = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  Set<SettingsDestinationId> visibleIds() => buildSettingsSchema(sctx)
      .where((SettingsDestination d) => d.isVisible(sctx))
      .map((SettingsDestination d) => d.id)
      .toSet();

  testWidgets('全部模块开着时，每条一级分类都在（门控没有误伤恒在项）', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final List<SettingsDestination> all = buildSettingsSchema(sctx);
    final Set<SettingsDestinationId> visible = visibleIds();
    for (final SettingsDestination destination in all) {
      if (moduleOfSettingsDestination(destination.id) == null) continue;
      expect(
        visible,
        contains(destination.id),
        reason: '${destination.id} 的模块开着却不可见——门控写反了',
      );
    }
  });

  testWidgets('逐个关模块：只有它名下的分类消失，别的一条都不少', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final Set<SettingsDestinationId> baseline = visibleIds();

    for (final ModuleId module in ModuleId.values) {
      // 期望值从归属表派生，不重抄名单。
      final Set<SettingsDestinationId> owned = baseline
          .where(
            (SettingsDestinationId id) =>
                moduleOfSettingsDestination(id) == module,
          )
          .toSet();

      appModel.enabled = ModuleId.values.toSet()..remove(module);
      final Set<SettingsDestinationId> after = visibleIds();

      expect(
        after.intersection(owned),
        isEmpty,
        reason: '关掉 $module 之后 ${after.intersection(owned)} 还列在设置主页上',
      );
      expect(
        after,
        baseline.difference(owned),
        reason:
            '关掉 $module 波及了不属于它的分类。成对分类（在线服务+媒体追踪、'
            '同步备份+互联）必须同进同出，恒在分类一条都不能少。',
      );
    }
  });

  testWidgets('Manga 与浏览的旧关闭偏好不再藏掉它们的设置分类', (WidgetTester tester) async {
    await pumpContext(tester);
    // 走生产的可见性合成：库里可能存着旧版写下的 module_*_enabled=false。
    appModel.visibilityOverride = ModuleVisibility.resolve(
      prefOf: (ModuleId _) => false,
      isWindows: true,
      isDesktop: true,
      isIOS: false,
      isAndroid: false,
    );
    final Set<SettingsDestinationId> visible = visibleIds();
    expect(visible, contains(SettingsDestinationId.manga));
    expect(visible, contains(SettingsDestinationId.downloads));
  });

  testWidgets('关掉的模块在设置搜索索引里一条都不剩（看不见也到不了）', (WidgetTester tester) async {
    await pumpContext(tester);
    appModel.enabled = ModuleId.values.toSet();
    final List<SettingsDestination> all = buildSettingsSchema(sctx);

    for (final ModuleId module in ModuleId.values) {
      final List<SettingsDestination> owned = all
          .where(
            (SettingsDestination d) =>
                moduleOfSettingsDestination(d.id) == module,
          )
          .toList();
      if (owned.isEmpty) continue;

      appModel.enabled = ModuleId.values.toSet()..remove(module);
      expect(
        flattenVisibleSettings(owned, sctx),
        isEmpty,
        reason:
            '关掉 $module 之后它的设置行还能被搜出来。搜索命中会把用户送进一个'
            '本该不存在的分类详情页——「隐藏」就只剩视觉效果了。',
      );
    }
  });
}

class _ModuleGatingAppModel extends AppModel {
  _ModuleGatingAppModel() : super(testPlatformServices());

  /// 直接摆布合成结果，绕开 prefs 仓库与平台判据——本测试要钉的是「门控消费端
  /// 按可见性收缩」，pref 读取与平台剔除各有自己的用例（`module_registry_test`）。
  Set<ModuleId> enabled = ModuleId.values.toSet();

  /// 需要走真实 [ModuleVisibility.resolve] 合成时使用（常驻导航 / 平台门禁用例）。
  ModuleVisibility? visibilityOverride;

  @override
  ModuleVisibility get moduleVisibility =>
      visibilityOverride ?? ModuleVisibility(enabled);
}
