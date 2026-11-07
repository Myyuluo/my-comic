import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_downloads.dart';

/// 设置里的「下载」分类已更名为「存储与下载」：名称来自专用字符串资源，不写死
/// 在 schema 里。Ticket 08 起内容为存储位置小节（Content root / Program state
/// root / 三个文件夹入口），不新增跳转到下载页的入口；副标题保留原有 summary。
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

  testWidgets('分类内容为存储位置小节，没有打开下载页的入口', (WidgetTester tester) async {
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
      <String?>['storage.location.section'],
      reason: '分类内容为存储位置小节',
    );
    expect(
      destination.sections.single.items.map((SettingsItem item) => item.id),
      <String>[
        'storage.content_root',
        'storage.program_state_root',
        'storage.open_downloads',
        'storage.open_local_comic',
        'storage.open_autobackup',
      ],
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
