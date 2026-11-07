import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 11: Settings exposes the `.tachibk` export entry as a visible but
/// disabled/placeholder row until v1.5. No Automatic backup (scheduled) entry
/// is offered in v1.
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

  SettingsSection backupSection() =>
      buildSystemDestination().sections.singleWhere(
        (SettingsSection section) => section.id == 'system.section.backup',
      );

  testWidgets(
    'Backup section has import plus a disabled .tachibk export entry',
    (WidgetTester tester) async {
      await captureContext(tester);

      final SettingsSection section = backupSection();
      final List<SettingsItem> items = section.items;
      expect(items.map((SettingsItem item) => item.id).toList(), <String>[
        'system.import_mihon_backup',
        'system.export_mihon_backup',
      ]);

      final SettingsActionItem importItem =
          items.firstWhere(
                (SettingsItem item) => item.id == 'system.import_mihon_backup',
              )
              as SettingsActionItem;
      expect(importItem.isEnabled(settings), isTrue);
      expect(importItem.subtitle, t.backup_import_mihon_subtitle);

      final SettingsActionItem exportItem =
          items.firstWhere(
                (SettingsItem item) => item.id == 'system.export_mihon_backup',
              )
              as SettingsActionItem;
      expect(exportItem.title, t.backup_export_mihon_title);
      expect(exportItem.subtitle, t.backup_export_mihon_subtitle);
      expect(exportItem.isEnabled(settings), isFalse);
      expect(exportItem.cli?.unsupportedHint, isNotNull);

      // v1 does not offer Automatic backup: no scheduled-backup toggle exists.
      expect(
        items.where(
          (SettingsItem item) =>
              item.id.contains('automatic') ||
              item.id.contains('auto_backup') ||
              item.id.contains('schedul'),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('disabled action row is greyed out and cannot be tapped', (
    WidgetTester tester,
  ) async {
    bool tapped = false;
    final SettingsActionItem disabled = SettingsActionItem(
      id: 'test.disabled_action',
      title: 'Disabled action',
      onTap: (SettingsContext _) {
        tapped = true;
      },
      enabled: (SettingsContext _) => false,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (BuildContext context, WidgetRef ref, Widget? _) {
                return SettingsSchemaItem(
                  item: disabled,
                  settingsContext: SettingsContext(
                    context: context,
                    appModel: AppModel(testPlatformServices()),
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () {},
                  ),
                  showIcons: false,
                  routeBuilder: (BuildContext context, WidgetBuilder builder) =>
                      MaterialPageRoute<void>(builder: builder),
                );
              },
            ),
          ),
        ),
      ),
    );

    final Finder opacity = find.ancestor(
      of: find.text('Disabled action'),
      matching: find.byType(Opacity),
    );
    expect(opacity, findsWidgets);
    expect(
      tester
          .widgetList<Opacity>(opacity)
          .any((Opacity widget) => widget.opacity == 0.38),
      isTrue,
    );

    await tester.tap(find.text('Disabled action'));
    await tester.pump();
    expect(tapped, isFalse);
  });
}
