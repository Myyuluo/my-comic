import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';

/// 「下载」设置分类里那条直达下载页的导航项随 my-comic v1 下载页入口收敛移除；
/// 这里只保留文案不变式：副标题说的是它打开的那个页面，不是本分类的 summary。
void main() {
  testWidgets('the subtitle text itself differs from the category summary',
      (WidgetTester tester) async {
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
