import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// Ticket 09：About / 版本页必须显示 MyComic 身份、GPL-3.0 与
/// “基于 Fushi v3.0.0” 来源署名，同时保留上游与 MyComic 两份版权。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  List<SettingsItem> generalItems() => buildSystemDestination()
      .sections
      .singleWhere((SettingsSection s) => s.id == 'system.section.general')
      .items;

  test('general section exposes a MyComic about row after the version row', () {
    final List<String> ids =
        generalItems().map((SettingsItem item) => item.id).toList();
    expect(ids, contains('system.about'));
    expect(ids.indexOf('system.about'), greaterThan(ids.indexOf('system.app_version')));
  });

  testWidgets('about row carries attribution and both copyright lines', (
    WidgetTester tester,
  ) async {
    final SettingsCustomItem about = generalItems()
        .whereType<SettingsCustomItem>()
        .firstWhere((SettingsCustomItem item) => item.id == 'system.about');
    final Widget row = about.builder(_StubSettingsContext());

    expect(row, isA<AdaptiveSettingsRow>());
    final AdaptiveSettingsRow settingsRow = row as AdaptiveSettingsRow;
    expect(settingsRow.title, 'MyComic');
    final String subtitle = settingsRow.subtitle ?? '';
    expect(subtitle, contains('Fushi v3.0.0'));
    expect(subtitle, contains('GPL-3.0'));
    expect(subtitle, contains('Fushi'));
    expect(subtitle, contains('MyComic'));
  });
}

class _StubSettingsContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
