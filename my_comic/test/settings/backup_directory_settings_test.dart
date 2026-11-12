import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/models.dart';
import 'package:my_comic/src/media/sources/reader_my_comic_source.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/settings/settings_destination.dart';
import 'package:my_comic/src/pages/implementations/create_backup_page.dart';
import 'package:my_comic/src/settings/settings_schema_downloads.dart';
import 'package:my_comic/src/settings/settings_schema_system.dart';
import 'package:my_comic/src/settings/settings_schema_widgets.dart';

import '../helpers/test_platform_services.dart';

/// Ticket 07: the former 「导出 Mihon 备份」 placeholder row becomes
/// 「创建备份」 and opens the create-backup page (tickets 08–12 fill in more
/// sections there). No Automatic backup (scheduled) entry is offered.
///
/// Ticket 03: the whole Backup group moved from 「系统与关于」 to 「存储与下载」；
/// the import picker keeps defaulting to the Backup directory (covered by
/// test/backup_import/backup_directory_test.dart). Ticket 06: backup and the
/// download-index rows share the merged 「备份索引」 section (id stays
/// `system.section.backup`), and the backup rows remain visible on mobile.
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
                readerSource: ReaderMyComicSource.instance,
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

  testWidgets('Backup section has import plus an enabled create-backup entry', (
    WidgetTester tester,
  ) async {
    final AppLocale original = LocaleSettings.currentLocale;
    addTearDown(() => LocaleSettings.setLocale(original));
    LocaleSettings.setLocale(AppLocale.zhCn);
    await captureContext(tester);

    final SettingsSection section = backupSection();
    expect(section.id, 'system.section.backup', reason: '合并分组保留稳定 id');
    expect(section.title, '备份索引', reason: '备份与下载索引合并为「备份索引」');
    expect(section.visible, isNull, reason: '备份行在移动端仍可用：分组不能整组桌面专属');
    final List<SettingsItem> items = section.items;
    expect(items.map((SettingsItem item) => item.id).toList(), <String>[
      'system.import_mihon_backup',
      'system.export_mihon_backup',
      'storage.rebuild_index',
      'storage.scan_downloaded',
    ], reason: '合并分组的固定顺序：导入备份、创建备份、重建、检索');

    final SettingsActionItem importItem =
        items.firstWhere(
              (SettingsItem item) => item.id == 'system.import_mihon_backup',
            )
            as SettingsActionItem;
    expect(importItem.isEnabled(settings), isTrue);
    expect(importItem.visible, isNull, reason: '导入备份在所有平台可见');
    expect(importItem.title, '导入备份');
    expect(importItem.subtitle, '本应用支持导入Mihon的备份文件，请选择您的.tachibk文件。');

    final SettingsActionItem exportItem =
        items.firstWhere(
              (SettingsItem item) => item.id == 'system.export_mihon_backup',
            )
            as SettingsActionItem;
    expect(exportItem.title, '创建备份', reason: 'ticket 07 启用并更名创建备份');
    expect(exportItem.subtitle, '将书架数据导出为.tachibk文件。');
    expect(exportItem.isEnabled(settings), isTrue);
    expect(exportItem.visible, isNull, reason: '创建备份在所有平台可见');
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
  });

  testWidgets('create-backup row uses the new copy and opens its page', (
    WidgetTester tester,
  ) async {
    final AppLocale original = LocaleSettings.currentLocale;
    addTearDown(() => LocaleSettings.setLocale(original));
    LocaleSettings.setLocale(AppLocale.zhCn);
    await captureContext(tester);

    final SettingsActionItem exportItem =
        backupSection().items.firstWhere(
              (SettingsItem item) => item.id == 'system.export_mihon_backup',
            )
            as SettingsActionItem;
    expect(exportItem.title, '创建备份');
    expect(exportItem.subtitle, '将书架数据导出为.tachibk文件。');
    expect(exportItem.isEnabled(settings), isTrue);

    // Do not await: pushSettingsPage completes only when the page is popped.
    unawaited(Future<void>.sync(() => exportItem.onTap(settings)));
    await tester.pumpAndSettle();
    expect(find.byType(CreateBackupPage), findsOneWidget);
  });

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
                    readerSource: ReaderMyComicSource.instance,
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
