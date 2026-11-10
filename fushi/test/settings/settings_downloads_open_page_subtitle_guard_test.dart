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
/// 「下载」段（保存为CBZ压缩包）插在数据存储位置与备份之间——最终顺序为
/// 数据存储位置 → 下载 → 备份 → 下载索引。
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

  testWidgets('分类内容为存储位置 + 下载 + 备份 + 重建下载索引小节，没有导入本地漫画，'
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
        'downloads.section.download',
        'system.section.backup',
        'storage.rebuild.section',
      ],
      reason:
          '批量导入退役 + 备份分组搬入 + 下载开关后：'
          '存储位置 → 下载 → 备份 → 下载索引',
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
    );
    expect(
      destination.sections[2].items.map((SettingsItem item) => item.id),
      <String>['system.import_mihon_backup', 'system.export_mihon_backup'],
      reason: '备份分组整组搬入「存储与下载」',
    );
    expect(
      destination.sections.last.items.map((SettingsItem item) => item.id),
      <String>['storage.rebuild_index', 'storage.scan_downloaded'],
      reason: '下载索引同时提供重建（只重链书架）与检索已下载（发现并加入）',
    );
    expect(
      destination.sections
          .expand((SettingsSection section) => section.items)
          .whereType<SettingsNavigationItem>(),
      isEmpty,
      reason: '不得新增跳转到下载页的入口',
    );
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
