import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';

/// 设置 › 系统与关于 的分组顺序守卫（manga-shelf-download-ux ticket 04）。
///
/// 用户要求「更新提醒」整组置顶，但分组内部条目顺序（含末尾的无痕阅读）以及
/// 其余分组的相对顺序都不能被顺手重排。这里按 stable id 锁定两件事：
/// 系统与关于的子视图顺序，以及更新提醒分组内部的条目顺序。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  List<String?> sectionIds() => buildSystemDestination().sections
      .map((SettingsSection section) => section.id)
      .toList();

  test('更新提醒分组置顶，其余分组保持原顺序', () {
    expect(sectionIds(), <String?>[
      'system.section.update_notifications',
      'system.section.general',
      'system.section.network',
      'system.section.diagnostics',
    ], reason: '「更新提醒」必须是系统与关于子视图的第一个分组，且其余分组不重排');
  });

  test('更新提醒分组内部条目顺序不变：无痕阅读仍是最后一项', () {
    final SettingsSection section = buildSystemDestination().sections
        .singleWhere(
          (SettingsSection candidate) =>
              candidate.id == 'system.section.update_notifications',
        );
    expect(section.items.map((SettingsItem item) => item.id).toList(), <String>[
      'system.updates.mangaChapter',
      'system.updates.mangaExtension',
      'system.updates.extension_auto_update',
      'system.updates.system_notifications',
      'system.incognito_reading',
    ], reason: '分组内部顺序被锁定，无痕阅读保持最后一项');
  });
}
