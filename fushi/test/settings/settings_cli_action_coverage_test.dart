import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_cli_values.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';

import '../helpers/test_platform_services.dart';

/// 控制通道（`fushi_cli config run`）只走动作声明的 [SettingsActionItem.cli]，
/// 不再去调可能弹确认框 / 选择器的 onTap。于是「新加一个动作却忘了声明 cli」在
/// CLI 上表现为「只能在设置页里点」——静默的覆盖缺口。本守卫遍历整棵 schema
/// （含子页）与逃生口页面条目，要求每个动作都显式声明怎么在 CLI 上执行。
void main() {
  late SettingsContext settings;

  Future<void> captureContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              settings = SettingsContext(
                context: context,
                appModel: AppModel(testPlatformServices()),
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

  List<SettingsItem> allItems() {
    final List<SettingsItem> items = <SettingsItem>[];
    void walk(SettingsDestination page, int depth) {
      for (final SettingsSection section in page.sections) {
        for (final SettingsItem item in section.items) {
          items.add(item);
          if (item is SettingsNavigationItem &&
              item.child != null &&
              depth < 3) {
            walk(item.child!(), depth + 1);
          }
        }
      }
    }

    for (final SettingsDestination destination in buildSettingsSchema(
      settings,
    )) {
      walk(destination, 0);
    }
    for (final CtlBodyPage page in buildCtlBodyPages()) {
      items.addAll(page.items);
    }
    return items;
  }

  testWidgets('每个动作行都声明了控制通道入口', (WidgetTester tester) async {
    await captureContext(tester);
    final List<SettingsActionItem> actions = allItems()
        .whereType<SettingsActionItem>()
        .toList();
    expect(actions.length, greaterThan(20), reason: '遍历没走到 schema');
    final List<String> missing = <String>[
      for (final SettingsActionItem action in actions)
        if (action.cli == null) action.id,
    ];
    expect(missing, isEmpty, reason: '这些动作没有 cli：$missing');
    for (final SettingsActionItem action in actions) {
      final SettingsCliAction cli = action.cli!;
      final int modes =
          (cli.run != null ? 1 : 0) +
          (cli.sameAsTap ? 1 : 0) +
          (cli.unsupportedHint != null ? 1 : 0);
      expect(modes, 1, reason: '${action.id} 的 cli 必须恰好是三种之一');
      if (cli.unsupportedHint != null) {
        expect(cli.unsupportedHint, isNotEmpty, reason: action.id);
      }
      final Set<String> names = <String>{};
      for (final SettingsCliParam param in cli.params) {
        expect(names.add(param.name), isTrue, reason: '${action.id} 参数重名');
      }
    }
  });

  // 上游 Fushi 在这里点名检查视频 / 阅读器 / AI 的若干自绘行必须声明
  // cliValue / cliList。manga-only shell（ff3f2df0）把视频、游戏、阅读器与
  // AI 分类整体移出主设置 schema（`buildSettingsSchema` 只剩外观 / 漫画 /
  // 下载 / 系统与关于，可选 Tracking），这些 id 在 CLI 索引里已不存在；
  // 当前可达的自绘行都没有 CLI 读写需求。将来若给可达自绘行加 CLI 读写，
  // 在此恢复逐 id 的 cliValue / cliList 守卫。

  test('颜色写法：#RRGGBB 补不透明、#AARRGGBB 原样、坏写法抛 FormatException', () {
    expect(parseSettingsCliColor('#112233'), 0xFF112233);
    expect(parseSettingsCliColor('#80112233'), 0x80112233);
    expect(parseSettingsCliColor('0xff000000'), 0xFF000000);
    expect(() => parseSettingsCliColor('red'), throwsFormatException);
    expect(() => parseSettingsCliColor('#12345'), throwsFormatException);
    expect(formatSettingsCliColor(0x80112233), '#80112233');
  });
}
