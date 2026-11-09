import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeActiveTabs;
import 'package:fushi/src/platform/desktop/ctl/ctl_online_support.dart'
    show ctlNavigationName, ctlNavigationPages, homeTabFromCtlName;

/// `nav list`（`/api/admin/navigation`）的 `pages` 顺序：可用页必须按一级导航的
/// 固定顺序 Manga → Browse → History → Downloads → Settings 输出，旧的模块排序偏好
/// 不能改变它。
void main() {
  ModuleVisibility resolved({bool legacyPrefsOff = false}) =>
      ModuleVisibility.resolve(
        prefOf: (ModuleId _) => !legacyPrefsOff,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
      );

  test('可用页按固定导航顺序排在列表最前（Manga → Browse → History → Downloads → Settings）', () {
    final ModuleVisibility visibility = resolved(legacyPrefsOff: true);
    final List<HomeTab> active = homeActiveTabs(visibility);
    expect(active, <HomeTab>[
      HomeTab.manga,
      HomeTab.browse,
      HomeTab.history,
      HomeTab.downloads,
      HomeTab.settings,
    ]);

    final List<HomeTab> pages = ctlNavigationPages(active: active);
    expect(pages.take(active.length), active);
    expect(pages.take(5), <HomeTab>[
      HomeTab.manga,
      HomeTab.browse,
      HomeTab.history,
      HomeTab.downloads,
      HomeTab.settings,
    ]);
  });

  test('ctl 的 downloads / history / browse 指向对应页面', () {
    expect(homeTabFromCtlName('downloads'), HomeTab.downloads);
    expect(homeTabFromCtlName('browse'), HomeTab.browse);
    expect(homeTabFromCtlName('history'), HomeTab.history);
    expect(ctlNavigationName(HomeTab.downloads), 'downloads');
    expect(ctlNavigationName(HomeTab.browse), 'browse');
    expect(ctlNavigationName(HomeTab.history), 'history');
  });

  test('不可用页面仍保留在列表中（available=false），且不丢失 / 不重复', () {
    final List<HomeTab> active = homeActiveTabs(resolved());
    final List<HomeTab> pages = ctlNavigationPages(active: active);
    expect(pages.toSet(), HomeTab.values.toSet());
    expect(pages.length, HomeTab.values.length);
  });

  test('旧的排序偏好写入不再改变 nav list 的可用页顺序', () {
    // ctl `module order` 写的是 ModuleVisibility.order；导航合成忽略它。
    final List<HomeTab> active = homeActiveTabs(
      ModuleVisibility(
        resolved(legacyPrefsOff: true).enabled,
        order: const <ModuleId>[ModuleId.browse, ModuleId.manga],
      ),
    );
    expect(active, <HomeTab>[
      HomeTab.manga,
      HomeTab.browse,
      HomeTab.history,
      HomeTab.downloads,
      HomeTab.settings,
    ]);
  });
}
