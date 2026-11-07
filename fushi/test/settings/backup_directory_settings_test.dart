import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 11: Settings exposes the `.tachibk` export entry as a visible but
/// disabled/placeholder row until v1.5. No Automatic backup (scheduled) entry
/// is offered in v1.
///
/// Ticket 03: the whole Backup group moved from 「系统与关于」 to 「存储与下载」；
/// item copy / enabled state stay verbatim, and the import picker keeps
/// defaulting to the Backup directory (covered by
/// test/backup_import/backup_directory_test.dart).
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
      buildDownloadsDestination().sections.singleWhere(
        (SettingsSection section) => section.id == 'system.section.backup',
      );

  testWidgets(
    'Backup section lives in storage & downloads, not in system/about',
    (WidgetTester tester) async {
      await captureContext(tester);

      // 「系统与关于」不再保留备份分组。
      expect(
        buildSystemDestination().sections.where(
          (SettingsSection section) => section.id == 'system.section.backup',
        ),
        isEmpty,
        reason: '备份分组整组搬入「存储与下载」',
      );
      expect(
        buildSystemDestination().sections
            .expand((SettingsSection section) => section.items)
            .map((SettingsItem item) => item.id)
            .where(
              (String id) =>
                  id == 'system.import_mihon_backup' ||
                  id == 'system.export_mihon_backup',
            ),
        isEmpty,
        reason: '系统与关于不得残留备份条目',
      );
    },
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
