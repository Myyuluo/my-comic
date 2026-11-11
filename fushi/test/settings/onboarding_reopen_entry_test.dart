import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/onboarding_wizard_page.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

/// Ticket 07：设置 →「系统与关于」的「重新打开新手引导」入口。
///
/// 入口复用现有设置行组件（SettingsNavigationItem），文案来自四语言 l10n；点击
/// 推入的页面就是首次启动用的同一个三步向导。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  List<SettingsItem> generalItems() => buildSystemDestination().sections
      .singleWhere(
        (SettingsSection section) => section.id == 'system.section.general',
      )
      .items;

  test('系统与关于 › 通用里有「重新打开新手引导」入口', () {
    final SettingsNavigationItem item = generalItems()
        .whereType<SettingsNavigationItem>()
        .singleWhere(
          (SettingsNavigationItem item) => item.id == 'system.onboarding',
        );

    expect(item.title, t.settings_onboarding_reopen_title);
    expect(item.title, 'Reopen the onboarding guide');
    expect(item.subtitle, t.settings_onboarding_reopen_subtitle);
    expect(item.icon, FushiIcons.help);
    expect(item.builder, isNotNull);
  });

  testWidgets('入口 builder 返回三步向导本体', (WidgetTester tester) async {
    final SettingsNavigationItem item = generalItems()
        .whereType<SettingsNavigationItem>()
        .singleWhere(
          (SettingsNavigationItem item) => item.id == 'system.onboarding',
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            // builder 只构造页面，不在此挂载；挂载行为由向导自己的测试覆盖。
            expect(item.builder!(context), isA<OnboardingWizardPage>());
            return const SizedBox.shrink();
          },
        ),
      ),
    );
  });
}
