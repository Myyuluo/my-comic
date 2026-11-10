import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';

/// 设置里的「下载」分类已更名为「存储与下载」：名称来自专用字符串资源，不写死
/// 在 schema 里。Ticket 08 起内容为存储位置小节（Content root / Program state
/// root），不新增跳转到下载页的入口；副标题保留原有 summary。
///
/// 2026-11-08：「导入本地漫画」段随批量导入退役删除；本地漫画改由图源列表里的
/// 「本地图源」承担。Ticket 03：三个文件夹入口移除，备份分组搬入本页。Ticket 08：
/// 「下载」段（保存为CBZ压缩包）插在数据存储位置与备份之间。Ticket 06（本批）：
/// 备份与下载索引合并为「备份索引」，下载分组移到它下方——最终顺序为
/// 数据存储位置 → 备份索引 → 下载。
void main() {
  AppLocale currentLocale() => LocaleSettings.currentLocale;

  testWidgets('分类标题「存储与下载」来自专用字符串资源', (WidgetTester tester) async {
    final AppLocale original = currentLocale();
    addTearDown(() => LocaleSettings.setLocale(original));

    LocaleSettings.setLocale(AppLocale.zhCn);
    expect(
      buildDownloadsDestination().title,
      '存储与下载',
      reason: '中文界面的分类标题必须是「存储与下载」',
    );
    expect(
      buildDownloadsDestination().title,
      t.settings_destination_downloads,
      reason: '标题必须取自字符串资源，不能在 schema 里写死',
    );

    LocaleSettings.setLocale(AppLocale.en);
    expect(
      buildDownloadsDestination().title,
      'Storage & downloads',
      reason: '英文界面的分类标题跟随字符串资源',
    );
  });

  testWidgets('分类内容为存储位置 + 备份索引 + 下载，没有导入本地漫画，'
      '没有打开下载页的入口', (WidgetTester tester) async {
    final AppLocale original = currentLocale();
    addTearDown(() => LocaleSettings.setLocale(original));
    LocaleSettings.setLocale(AppLocale.zhCn);

    final SettingsDestination destination = buildDownloadsDestination();
    expect(
      destination.summary,
      t.download_settings,
      reason: '现有副标题（分类 summary）必须保留',
    );
    expect(
      destination.sections.map((SettingsSection section) => section.id),
      <String?>[
        'storage.location.section',
        'system.section.backup',
        'downloads.section.download',
      ],
      reason: 'ticket 06：数据存储位置 → 备份索引 → 下载',
    );
    expect(
      destination.sections.expand((SettingsSection section) => section.items),
      isNot(
        contains(
          isA<SettingsItem>().having(
            (SettingsItem item) => item.id,
            'id',
            'storage.import_local_comics',
          ),
        ),
      ),
      reason: '设置里不得再有「导入本地漫画」入口',
    );
    expect(
      File('lib/src/settings/settings_schema_local_import.dart').existsSync(),
      isFalse,
      reason: '导入本地漫画段落的 schema 文件必须删除',
    );
    expect(
      destination.sections.first.items.map((SettingsItem item) => item.id),
      <String>[
        'storage.content_root',
        'storage.program_state_root',
        'storage.clear_cache',
        'storage.clear_database',
      ],
      reason: '数据存储位置保持最上方',
    );

    final SettingsSection backupIndex = destination.sections[1];
    expect(
      backupIndex.id,
      'system.section.backup',
      reason: '合并分组保留稳定 id，CLI / 搜索锚点不变',
    );
    expect(backupIndex.title, '备份索引', reason: '备份与下载索引合并为「备份索引」');
    expect(backupIndex.items.map((SettingsItem item) => item.id), <String>[
      'system.import_mihon_backup',
      'system.export_mihon_backup',
      'storage.rebuild_index',
      'storage.scan_downloaded',
    ], reason: '组内顺序：导入备份、创建备份、重建下载索引、检索已下载');
    expect(backupIndex.visible, isNull, reason: '备份索引分组本身不能整组桌面专属：备份在移动端仍可见');
    final SettingsItem importItem = backupIndex.items[0];
    final SettingsItem exportItem = backupIndex.items[1];
    final SettingsItem rebuildItem = backupIndex.items[2];
    final SettingsItem scanItem = backupIndex.items[3];
    expect(importItem.visible, isNull, reason: '导入备份在所有平台可见');
    expect(exportItem.visible, isNull, reason: '创建备份在所有平台可见');
    expect(rebuildItem.visible, isNotNull, reason: '重建下载索引仍只在桌面可见');
    expect(scanItem.visible, isNotNull, reason: '检索已下载仍只在桌面可见');

    final SettingsSection download = destination.sections[2];
    expect(download.id, 'downloads.section.download');
    expect(download.items.map((SettingsItem item) => item.id), <String>[
      'downloads.save_as_cbz',
    ], reason: '「下载」分组移到备份索引下方');
    expect(
      destination.sections
          .expand((SettingsSection section) => section.items)
          .whereType<SettingsNavigationItem>(),
      isEmpty,
      reason: '不得新增跳转到下载页的入口',
    );
    expect(
      File('lib/i18n/strings.i18n.json').readAsStringSync(),
      isNot(contains('"rebuild_download_index_section"')),
      reason: '旧「下载索引」section 标题 key 必须移除，不能再被引用',
    );
  });

  testWidgets('「备份索引」标题在简中、繁中、英文都有真实翻译，不用英文占位', (WidgetTester tester) async {
    final AppLocale original = currentLocale();
    addTearDown(() => LocaleSettings.setLocale(original));

    final Map<AppLocale, String> expected = <AppLocale, String>{
      AppLocale.zhCn: '备份索引',
      AppLocale.zhHk: '備份索引',
      AppLocale.en: 'Backup & index',
    };
    for (final MapEntry<AppLocale, String> entry in expected.entries) {
      LocaleSettings.setLocale(entry.key);
      expect(
        buildDownloadsDestination().sections[1].title,
        entry.value,
        reason: '${entry.key}：合并分组标题必须是真实翻译，不能英文占位或空缺',
      );
    }
    for (final AppLocale locale in AppLocale.values) {
      if (locale == AppLocale.en) continue;
      expect(
        locale.translations.backup_index_section,
        isNot('Backup & index'),
        reason: '${locale.name}：新增 section 标题不能留英文占位',
      );
    }
  });

  testWidgets('the subtitle text itself differs from the category summary', (
    WidgetTester tester,
  ) async {
    final AppLocale original = currentLocale();
    addTearDown(() => LocaleSettings.setLocale(original));
    for (final AppLocale locale in <AppLocale>[AppLocale.en, AppLocale.zhCn]) {
      LocaleSettings.setLocale(locale);
      expect(
        t.settings_downloads_open_page_hint,
        isNot(t.download_settings),
        reason: '$locale：副标题说的是它打开的那个页面，不是本分类的 summary',
      );
    }
  });
}
