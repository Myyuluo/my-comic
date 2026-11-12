import 'package:flutter_test/flutter_test.dart';
import 'package:my_comic/i18n/strings.g.dart';
import 'package:my_comic/src/models/module_id.dart';
import 'package:my_comic/src/pages/implementations/home_page.dart';
import 'package:my_comic/src/utils/adaptive/adaptive_navigation.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';

/// 测试用：把「一串具名 bool」翻成一个可见性快照。迁移前 [homeActiveTabs] 收的正是
/// 这串具名 bool（`videoEnabled` 必填，books/manga/downloads/lookup 默认开，
/// games/browserExtension 默认关），默认值在这里逐字保留，用例语义不变。
///
/// `downloads` 指的是「浏览 / 下载能力」（[ModuleId.browse]）：一级导航的「浏览」
/// 与「下载」两页共用同一条平台 / 合规门禁，所以一个布尔同时决定两页的出现与消失。
///
/// games/browserExtension 的平台判据在这里**显式给出**（[ModuleVisibility] 直接收
/// 最终可见集合），与生产的 [ModuleVisibility.resolve] 同语义——生产侧平台判据在
/// [ModuleId.availableOn]。
ModuleVisibility _visibility({
  required bool video,
  bool books = true,
  bool manga = true,
  bool games = false,
  bool downloads = true,
  bool lookup = true,
  bool browserExtension = false,
}) => ModuleVisibility(<ModuleId>{
  // 首页 2026-10-09 起是可关模块；这些用例的语义是「首页开着」。
  ModuleId.home,
  if (books) ModuleId.books,
  if (manga) ModuleId.manga,
  if (video) ModuleId.video,
  if (games) ModuleId.games,
  if (downloads) ModuleId.browse,
  if (lookup) ModuleId.lookup,
  if (browserExtension) ModuleId.browserExtension,
});

/// 守卫首页顶层导航的 tab 身份建模与启动逻辑。v23 起首页用 [HomeTab] 枚举建模 tab 身份
/// （不再用魔数索引）；galgame UX 统一后独立 texthooker tab 已删，条件 tab 只剩 video
/// （常驻）与 games（galgame 库，仅 Windows）。games 的可见性/位置由 home_tab_games_test
/// 单独守卫，本文件守 startup 逻辑 + 「无 games 时词典与设置相邻」。
void main() {
  group('startup module', () {
    test('未选启动页（null）时落默认：可见列表第一项', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      // 固定导航 Manga → 浏览 → 历史 → 下载打头，默认落点因此是漫画。
      expect(homeInitialTab(startupModule: null, tabs: tabs), HomeTab.manga);
      final List<HomeTab> noManga = homeActiveTabs(
        const ModuleVisibility(<ModuleId>{ModuleId.video, ModuleId.browse}),
      );
      expect(
        homeInitialTab(startupModule: null, tabs: noManga),
        HomeTab.browse,
      );
    });

    test('选了可见模块就冷启动进入它（查词 / 视频 / 漫画）', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(
        homeInitialTab(startupModule: ModuleId.lookup, tabs: tabs),
        HomeTab.dictionaries,
      );
      expect(
        homeInitialTab(startupModule: ModuleId.video, tabs: tabs),
        HomeTab.video,
      );
      expect(
        homeInitialTab(startupModule: ModuleId.manga, tabs: tabs),
        HomeTab.manga,
      );
    });

    test('所选模块被关掉时回退第一个可见页，不把初始 tab 指到隐藏 tab', () {
      // 渲染侧有 _visibleTab 兜底，但 _currentTab 会从第一帧起就是脏的
      // （底栏高亮与 _previousTab 都跟着错），所以门控必须在取值处。
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: false, lookup: false),
      );
      final HomeTab lookupOff = homeInitialTab(
        startupModule: ModuleId.lookup,
        tabs: tabs,
      );
      expect(lookupOff, HomeTab.manga);
      expect(tabs, contains(lookupOff));
      expect(
        homeInitialTab(startupModule: ModuleId.video, tabs: tabs),
        HomeTab.manga,
      );
      // 首页也关掉：回退到底栏第一个启用模块（固定导航的 Manga）。
      final List<HomeTab> withoutHome = homeActiveTabs(
        const ModuleVisibility(<ModuleId>{ModuleId.books, ModuleId.manga}),
      );
      expect(
        homeInitialTab(startupModule: ModuleId.video, tabs: withoutHome),
        HomeTab.manga,
      );
    });

    test('回退跟随用户排序：排在最前的可见模块', () {
      final List<HomeTab> tabs = homeActiveTabs(
        const ModuleVisibility(
          <ModuleId>{ModuleId.books, ModuleId.video},
          order: <ModuleId>[ModuleId.video, ModuleId.books],
        ),
      );
      expect(
        homeInitialTab(startupModule: ModuleId.lookup, tabs: tabs),
        HomeTab.video,
      );
    });

    test('没有 tab 的横切模块不会成为落点', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(
        homeInitialTab(startupModule: ModuleId.sync, tabs: tabs),
        HomeTab.manga,
      );
    });

    test('反向导航和视频 tab 插入只影响视觉索引，不改变启动逻辑 tab', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      final HomeTab initial = homeInitialTab(
        startupModule: ModuleId.lookup,
        tabs: tabs,
      );

      expect(initial, HomeTab.dictionaries);
      expect(
        homeTabForVisualIndex(
          tabs: tabs,
          visualIndex: homeVisualIndexForTab(
            tabs: tabs,
            tab: initial,
            reversed: true,
          ),
          reversed: true,
        ),
        HomeTab.dictionaries,
      );
    });
  });

  group('home dashboard tab', () {
    test('HomeTab 枚举包含 home；固定导航让 Manga 排在可见列表首位', () {
      expect(HomeTab.values, contains(HomeTab.home));
      expect(homeActiveTabs(_visibility(video: false)).first, HomeTab.manga);
      expect(homeActiveTabs(_visibility(video: true)).first, HomeTab.manga);
    });

    test('冷启动（未选启动页）落在固定导航首项 Manga', () {
      expect(
        homeInitialTab(
          startupModule: null,
          tabs: homeActiveTabs(_visibility(video: true)),
        ),
        HomeTab.manga,
      );
    });
  });

  group('downloads home tab', () {
    test('HomeTab 枚举包含独立的 downloads 一级导航项', () {
      expect(HomeTab.values, contains(HomeTab.downloads));
    });

    test('下载固定排在历史之后、设置之前，与浏览共用平台门禁', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs.indexOf(HomeTab.downloads), tabs.indexOf(HomeTab.browse) + 2);
      expect(tabs[tabs.indexOf(HomeTab.browse) + 1], HomeTab.history);
      expect(tabs.last, HomeTab.settings);

      // 浏览 / 下载能力不可用（如 iOS 合规限制）时浏览、历史、下载一起消失。
      final List<HomeTab> withoutBrowse = homeActiveTabs(
        _visibility(video: true, downloads: false),
      );
      expect(withoutBrowse, isNot(contains(HomeTab.browse)));
      expect(withoutBrowse, isNot(contains(HomeTab.history)));
      expect(withoutBrowse, isNot(contains(HomeTab.downloads)));
    });

    test('历史是独立一级导航项：固定插在浏览与下载之间，标签 / 图标来自资源', () {
      expect(HomeTab.values, contains(HomeTab.history));
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs.indexOf(HomeTab.history), tabs.indexOf(HomeTab.browse) + 1);
      expect(
        tabs.indexOf(HomeTab.history),
        tabs.indexOf(HomeTab.downloads) - 1,
      );

      final AdaptiveNavItem item = homeNavItemFor(HomeTab.history);
      expect(item.label, t.nav_history);
      expect(item.icon, MyComicIcons.history);
      expect(item.selectedIcon, MyComicIcons.filled(MyComicIcons.history));
    });

    test('下载导航项标签来自字符串资源，图标复用下载图标', () {
      final AdaptiveNavItem item = homeNavItemFor(HomeTab.downloads);
      expect(item.label, t.nav_downloads);
      expect(item.icon, MyComicIcons.download);
      expect(item.selectedIcon, MyComicIcons.filled(MyComicIcons.download));
    });
  });

  group('manga home tab', () {
    test('漫画是固定导航首项，浏览紧随其后，且有独立导航项', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs.first, HomeTab.manga);
      expect(tabs.indexOf(HomeTab.browse), 1);

      final AdaptiveNavItem item = homeNavItemFor(HomeTab.manga);
      expect(item.icon, MyComicIcons.manga);
      expect(item.selectedIcon, MyComicIcons.filled(MyComicIcons.manga));
      expect(item.label, t.manga_library);
    });
  });

  group('module tab visibility (功能模块显隐)', () {
    test('默认参数下漫画/视频可见（升级用户行为不变）', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      expect(tabs, contains(HomeTab.manga));
      expect(tabs, contains(HomeTab.video));
    });

    test('manga=false 只隐藏漫画 tab，其余不动', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, manga: false),
      );
      expect(tabs, isNot(contains(HomeTab.manga)));
      expect(tabs, contains(HomeTab.books));
      expect(tabs, contains(HomeTab.video));
      expect(tabs, contains(HomeTab.browse));
      expect(tabs, contains(HomeTab.dictionaries));
      expect(tabs, contains(HomeTab.settings));
    });

    test('books=false 只隐藏书架 tab，首页/词典/设置不动', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, books: false),
      );
      expect(tabs, isNot(contains(HomeTab.books)));
      expect(tabs, contains(HomeTab.home));
      expect(tabs, contains(HomeTab.dictionaries));
      expect(tabs, contains(HomeTab.settings));
    });

    test('browserExtension=false 隐藏扩展 tab', () {
      final List<HomeTab> withExt = homeActiveTabs(
        _visibility(video: true, browserExtension: true),
      );
      final List<HomeTab> withoutExt = homeActiveTabs(
        _visibility(video: true, browserExtension: false),
      );
      expect(withExt, contains(HomeTab.browserExtension));
      expect(withoutExt, isNot(contains(HomeTab.browserExtension)));
    });

    test('五个模块全关时首页/词典/设置/下载仍恒在（安全回退面）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(
          video: false,
          books: false,
          manga: false,
          games: false,
          browserExtension: false,
        ),
      );
      expect(tabs, <HomeTab>[
        HomeTab.browse,
        HomeTab.history,
        HomeTab.downloads,
        HomeTab.home,
        HomeTab.dictionaries,
        HomeTab.settings,
      ]);
    });

    test('downloads=false 同时隐藏浏览、历史与下载，词典仍紧随最后一个媒体库页', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, games: true, downloads: false),
      );
      expect(tabs, isNot(contains(HomeTab.browse)));
      expect(tabs, isNot(contains(HomeTab.history)));
      expect(tabs, isNot(contains(HomeTab.downloads)));
      expect(
        tabs.indexOf(HomeTab.dictionaries),
        tabs.indexOf(HomeTab.games) + 1,
      );
      expect(tabs, contains(HomeTab.settings));
    });

    test('lookup=false 只隐藏查词 tab，固定导航与扩展顺序不变', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: true, browserExtension: true, lookup: false),
      );
      expect(tabs, isNot(contains(HomeTab.dictionaries)));
      expect(tabs.take(2), <HomeTab>[HomeTab.manga, HomeTab.browse]);
      expect(tabs.last, HomeTab.settings);
      expect(tabs[tabs.length - 2], HomeTab.browserExtension);
    });

    test('七个模块全关时只剩首页/设置（安全回退面）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(
          video: false,
          books: false,
          manga: false,
          games: false,
          downloads: false,
          lookup: false,
          browserExtension: false,
        ),
      );
      expect(tabs, <HomeTab>[HomeTab.home, HomeTab.settings]);
    });

    test('隐藏 tab 后越界视觉索引回退到第一个可见页（浏览）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        _visibility(video: false, books: false, manga: false),
      );
      expect(
        homeTabForVisualIndex(tabs: tabs, visualIndex: 99, reversed: false),
        HomeTab.browse,
      );
    });
  });

  group('首页可关（2026-10-09）', () {
    test('首页关掉：首页不在可见列表，默认落地改为第一个启用的模块', () {
      final List<HomeTab> withoutHome = homeActiveTabs(
        const ModuleVisibility(<ModuleId>{
          ModuleId.books,
          ModuleId.manga,
          ModuleId.video,
        }),
      );
      expect(withoutHome, isNot(contains(HomeTab.home)));
      expect(homeLandingTab(withoutHome), HomeTab.manga);
      expect(
        homeLandingTab(
          homeActiveTabs(
            const ModuleVisibility(<ModuleId>{ModuleId.video, ModuleId.lookup}),
          ),
        ),
        HomeTab.video,
      );
      // 越界视觉索引也回落到默认落地 tab，而不是已隐藏的首页。
      expect(
        homeTabForVisualIndex(
          tabs: withoutHome,
          visualIndex: 99,
          reversed: false,
        ),
        HomeTab.manga,
      );
    });

    test('首页开着：默认落地是固定导航首项 Manga', () {
      expect(
        homeLandingTab(homeActiveTabs(_visibility(video: true))),
        HomeTab.manga,
      );
    });

    test('导航模块全关：只剩设置，落地设置（设置恒在）', () {
      final List<HomeTab> tabs = homeActiveTabs(
        const ModuleVisibility(<ModuleId>{ModuleId.sync}),
      );
      expect(tabs, <HomeTab>[HomeTab.settings]);
      expect(homeLandingTab(tabs), HomeTab.settings);
    });
  });

  group('固定导航（Manga / 浏览 / 历史 / 下载常驻）', () {
    test('旧的模块开关偏好全关，导航仍是 Manga → 浏览 → 历史 → 下载 → 设置', () {
      final List<HomeTab> tabs = homeActiveTabs(
        ModuleVisibility.resolve(
          prefOf: (ModuleId _) => false,
          isWindows: true,
          isDesktop: true,
          isIOS: false,
          isAndroid: false,
        ),
      );
      expect(tabs, <HomeTab>[
        HomeTab.manga,
        HomeTab.browse,
        HomeTab.history,
        HomeTab.downloads,
        HomeTab.settings,
      ]);
    });

    test('iOS 上浏览 / 历史 / 下载按合规门禁一起不出现，漫画不受影响', () {
      final List<HomeTab> tabs = homeActiveTabs(
        ModuleVisibility.resolve(
          prefOf: (ModuleId _) => true,
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
      );
      expect(tabs, <HomeTab>[HomeTab.manga, HomeTab.settings]);
    });
  });

  group('home tab structure', () {
    test('HomeTab 枚举不再含已删的 texthooker', () {
      expect(
        HomeTab.values.map((HomeTab t) => t.name),
        isNot(contains('texthooker')),
      );
    });

    test('无 games 时词典与设置相邻', () {
      final List<HomeTab> tabs = homeActiveTabs(_visibility(video: true));
      final int dict = tabs.indexOf(HomeTab.dictionaries);
      final int settings = tabs.indexOf(HomeTab.settings);
      expect(settings, equals(dict + 1));
    });

    test('游戏导航使用 Hook 工作台标签与手柄图标', () {
      final AdaptiveNavItem item = homeNavItemFor(HomeTab.games);
      expect(item.icon, MyComicIcons.games);
      expect(item.selectedIcon, MyComicIcons.filled(MyComicIcons.games));
      expect(item.label, t.nav_game);
    });
  });
}
