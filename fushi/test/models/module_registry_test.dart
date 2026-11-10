// 「功能模块」值域与映射表的契约测试。
//
// 这些映射是模块门控的**唯一真值**：漏一条映射 = 某个入口永远关不掉（或者更糟，
// 某个恒在的面被误关）。穷尽 switch 已经让「加模块时漏写映射」编译不过；这里钉的
// 是编译器管不到的另一半——映射**内容**是否正确，以及那几条刻意判 null 的例外是不
// 是还在（它们每一条背后都有一个具体的产品决定，被人「顺手补全」就会静默回归）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomeTab;
import 'package:fushi/src/settings/settings_destination.dart'
    show SettingsDestinationId;
import 'package:fushi/src/shortcuts/shortcut_action.dart' show ShortcutScope;
import 'package:fushi_core/fushi_core.dart' show MediaKind;

void main() {
  group('ModuleId', () {
    test('持久化键唯一且不带 .name 巧合依赖', () {
      final Set<String> keys = ModuleId.allPrefKeys;
      expect(
        keys.length,
        ModuleId.values.length,
        reason: '两个模块共用一个 pref key 会让它们的开关互相覆盖',
      );
      for (final ModuleId id in ModuleId.values) {
        expect(
          id.prefKey,
          startsWith('module_'),
          reason: 'pref 键命名前缀是备份/Profile 排除名单与诊断日志的识别依据',
        );
      }
    });

    test('存量七个模块的持久化键逐字冻结（Never break userspace）', () {
      // 用户已经关掉的模块必须在升级后仍然是关的。这七个键改一个字，线上用户的
      // 设置就会静默回落成「全开」。lookup 的键是历史名 module_dictionaries_enabled，
      // 与枚举名不一致是**有意**的，别为了好看去改。
      expect(ModuleId.books.prefKey, 'module_books_enabled');
      expect(ModuleId.manga.prefKey, 'module_manga_enabled');
      expect(ModuleId.video.prefKey, 'module_video_enabled');
      expect(ModuleId.games.prefKey, 'module_games_enabled');
      expect(ModuleId.browse.prefKey, 'module_downloads_enabled');
      expect(ModuleId.lookup.prefKey, 'module_dictionaries_enabled');
      expect(
        ModuleId.browserExtension.prefKey,
        'module_browser_extension_enabled',
      );
    });

    test('平台判据只有 browserExtension / downloads 两条', () {
      for (final ModuleId id in ModuleId.values) {
        final bool onWindowsDesktop = id.availableOn(
          isWindows: true,
          isDesktop: true,
          isIOS: false,
          isAndroid: false,
        );
        // 判 Android 而不是笼统的「移动端」：downloads 的判据是 iOS 本身
        // （App Store 合规），两个移动平台在这条上结论相反。
        final bool onAndroid = id.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
          isAndroid: true,
        );
        expect(onWindowsDesktop, isTrue, reason: 'Windows 桌面上全部模块都可用');
        if (id == ModuleId.browserExtension) {
          expect(onAndroid, isFalse, reason: '$id 是桌面限定');
        } else {
          expect(
            onAndroid,
            isTrue,
            reason: '$id 在 Android 上可用（games 是串流接收端形态）',
          );
        }
      }
      // games 处处可用，只是形态不同：Windows 本机库，其余平台串流接收端
      // （形态断言见下面「games 的两种形态」）。
      expect(
        ModuleId.games.availableOn(
          isWindows: false,
          isDesktop: true,
          isIOS: false,
          isAndroid: false,
        ),
        isTrue,
      );
      expect(
        ModuleId.games.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
        isTrue,
      );
      // 浏览器扩展是「电脑才有」，非 Windows 桌面照样有。
      expect(
        ModuleId.browserExtension.availableOn(
          isWindows: false,
          isDesktop: true,
          isIOS: false,
          isAndroid: false,
        ),
        isTrue,
      );
      // 下载中心：唯一一条不是「这个平台做不做得到」的判据。完整边界与它的
      // 兄弟能力（发现源 / 在线漫画源）见 test/build/ios_store_compliance_guard_test.dart。
      expect(
        ModuleId.browse.availableOn(
          isWindows: false,
          isDesktop: false,
          isIOS: true,
          isAndroid: false,
        ),
        isFalse,
      );
    });

    test('games 的两种形态：Windows 本机库，其余平台都是串流接收端', () {
      expect(GamesModuleForm.on(isWindows: true), GamesModuleForm.localLibrary);
      expect(
        GamesModuleForm.on(isWindows: false),
        GamesModuleForm.streamClient,
      );
      for (final (bool desktop, bool ios, bool android) in <(bool, bool, bool)>[
        (true, false, false), // macOS / Linux
        (false, true, false), // iOS
        (false, false, true), // Android
      ]) {
        expect(
          ModuleId.games.availableOn(
            isWindows: false,
            isDesktop: desktop,
            isIOS: ios,
            isAndroid: android,
          ),
          isTrue,
        );
      }
    });
  });

  group('ModuleVisibility', () {
    test('Manga 与浏览常驻：旧的模块开关偏好（引导 / ctl 写入）不再隐藏它们', () {
      // 升级上来的库里可能存着 module_manga_enabled=false（旧版功能模块开关 /
      // 新手引导 / ctl 写入的）。一级导航常驻后这些偏好不再参与可见性合成。
      final ModuleVisibility legacyOff = ModuleVisibility.resolve(
        prefOf: (ModuleId _) => false,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
      );
      expect(legacyOff.enabled, <ModuleId>{ModuleId.manga, ModuleId.browse});
    });

    test('resolve 把平台不可用的模块直接剔除，与 pref 真值无关（my-comic 范围）', () {
      final ModuleVisibility ios = ModuleVisibility.resolve(
        prefOf: (ModuleId _) => true,
        isWindows: false,
        isDesktop: false,
        isIOS: true,
        isAndroid: false,
      );
      expect(ios.isEnabled(ModuleId.manga), isTrue);
      expect(
        ios.isEnabled(ModuleId.browse),
        isFalse,
        reason: 'App Store 合规：下载能力不可用的平台上浏览必须随之缺席',
      );
      expect(ios.enabled, <ModuleId>{ModuleId.manga});
    });

    test('非漫画域模块即使 pref 开着也不进入可见集合（my-comic 范围）', () {
      final ModuleVisibility all = ModuleVisibility.all(
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
      );
      expect(all.enabled, <ModuleId>{ModuleId.manga, ModuleId.browse});
    });

    test('isEnabledOrUngated：null 表示恒在', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(none.isEnabledOrUngated(null), isTrue);
      expect(none.isEnabledOrUngated(ModuleId.video), isFalse);
    });
  });

  group('HomeTab 映射', () {
    test('设置恒在——它是全部模块关光后的安全回退面', () {
      expect(moduleOfHomeTab(HomeTab.settings), isNull);
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(isHomeTabVisible(HomeTab.settings, none), isTrue);
    });

    test('历史 / 下载是恒在的一级导航项，不绑定任何模块（同设置）', () {
      // 历史与下载由 homeActiveTabs 固定在「浏览」之后、受同一条平台门禁约束；
      // 它们自己不是模块，不能被模块开关隐藏（见 home_page_tabs_test 的顺序用例）。
      for (final HomeTab tab in <HomeTab>[
        HomeTab.history,
        HomeTab.downloads,
      ]) {
        expect(moduleOfHomeTab(tab), isNull);
        for (final ModuleId id in ModuleId.values) {
          expect(homeTabOfModule(id), isNot(tab));
        }
        const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
        expect(isHomeTabVisible(tab, none), isTrue);
      }
    });

    test('首页是可关模块（2026-10-09 用户反馈「首页没用但偏偏不给关」）', () {
      expect(moduleOfHomeTab(HomeTab.home), ModuleId.home);
      expect(homeTabOfModule(ModuleId.home), HomeTab.home);
      expect(ModuleId.home.prefKey, 'module_home_enabled');
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(isHomeTabVisible(HomeTab.home, none), isFalse);
      expect(
        isHomeTabVisible(
          HomeTab.home,
          const ModuleVisibility(<ModuleId>{ModuleId.home}),
        ),
        isTrue,
      );
    });

    test('至少保留一个导航模块：最后一个有 tab 的模块才算「最后一个」', () {
      // 只剩首页 + 横切模块：首页是最后一个导航模块，关不掉。
      const ModuleVisibility onlyHome = ModuleVisibility(<ModuleId>{
        ModuleId.home,
        ModuleId.sync,
        ModuleId.listening,
      });
      expect(isLastNavigationModule(ModuleId.home, onlyHome), isTrue);
      // 横切模块没有 tab，永远不是「最后一个导航模块」。
      expect(isLastNavigationModule(ModuleId.sync, onlyHome), isFalse);
      expect(hasAnyNavigationModule(onlyHome), isTrue);

      // 首页 + 书架：两个都能单独关。
      const ModuleVisibility two = ModuleVisibility(<ModuleId>{
        ModuleId.home,
        ModuleId.books,
      });
      expect(isLastNavigationModule(ModuleId.home, two), isFalse);
      expect(isLastNavigationModule(ModuleId.books, two), isFalse);

      // 只剩书架：书架是最后一个；已经关着的首页不算。
      const ModuleVisibility onlyBooks = ModuleVisibility(<ModuleId>{
        ModuleId.books,
      });
      expect(isLastNavigationModule(ModuleId.books, onlyBooks), isTrue);
      expect(isLastNavigationModule(ModuleId.home, onlyBooks), isFalse);

      const ModuleVisibility crossCutOnly = ModuleVisibility(<ModuleId>{
        ModuleId.sync,
      });
      expect(hasAnyNavigationModule(crossCutOnly), isFalse);
    });

    test('homeTabOfModule 与 moduleOfHomeTab 互为逆映射', () {
      for (final ModuleId id in ModuleId.values) {
        final HomeTab? tab = homeTabOfModule(id);
        if (tab == null) continue;
        expect(
          moduleOfHomeTab(tab),
          id,
          reason: '$id → $tab → ${moduleOfHomeTab(tab)} 不闭合，两张表已漂移',
        );
      }
      for (final HomeTab tab in HomeTab.values) {
        final ModuleId? id = moduleOfHomeTab(tab);
        if (id == null) continue;
        expect(homeTabOfModule(id), tab);
      }
    });

    test('五个横切模块没有 tab（只有设置分类与散落入口）', () {
      expect(homeTabOfModule(ModuleId.listening), isNull);
      expect(homeTabOfModule(ModuleId.cardCreation), isNull);
      expect(homeTabOfModule(ModuleId.services), isNull);
      expect(homeTabOfModule(ModuleId.ai), isNull);
      expect(homeTabOfModule(ModuleId.sync), isNull);
    });
  });

  group('SettingsDestinationId 映射', () {
    test('全部模块关光时，恒在分类仍然可见', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      // 每一条都是一个具体的产品决定，不是「还没写」：appearance/system/
      // storage/profiles 是设备级，恒在。reading / lookup 在 my-comic 仍分别挂
      // books / lookup（随已移除的模块一起不可见），不再是恒在项。
      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.appearance,
        SettingsDestinationId.profiles,
        SettingsDestinationId.storage,
        SettingsDestinationId.system,
      ]) {
        expect(
          isSettingsDestinationVisible(id, none),
          isTrue,
          reason: '$id 必须恒在——它不属于任何模块',
        );
      }
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.reading),
        ModuleId.books,
      );
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.lookup),
        ModuleId.lookup,
      );
    });

    test('Manga 的设置分类不因旧开关偏好消失；存储与下载恒在', () {
      // ticket 01：设置里由 Manga 拥有的分类跟随常驻导航，旧偏好不再把它藏掉；
      // ticket 04 起「存储与下载」已与浏览模块拆绑，任何可见性下都恒在。
      final ModuleVisibility legacyOff = ModuleVisibility.resolve(
        prefOf: (ModuleId _) => false,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
      );
      expect(
        isSettingsDestinationVisible(SettingsDestinationId.manga, legacyOff),
        isTrue,
      );
      expect(
        isSettingsDestinationVisible(
          SettingsDestinationId.downloads,
          legacyOff,
        ),
        isTrue,
      );
    });

    test('四个 synthetic 分类不受模块门控（它们不是设置主页上的一级分类）', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      for (final SettingsDestinationId id in <SettingsDestinationId>[
        SettingsDestinationId.readerQuickSettings,
        SettingsDestinationId.appIcon,
        SettingsDestinationId.videoQuickSettings,
        SettingsDestinationId.shortcuts,
      ]) {
        expect(
          moduleOfSettingsDestination(id),
          isNull,
          reason: '$id 是合成面板，按模块藏它只会让整个面板消失',
        );
        expect(isSettingsDestinationVisible(id, none), isTrue);
      }
    });

    test('my-comic 移除在线服务 / 同步后：追踪与本地备份恒在，互联仍挂同步模块', () {
      // 原 Fushi 里 mediaTracking 与 services、interconnect 与 syncBackup 成对
      // 共享模块；my-comic 移除在线服务与云端同步后，追踪（漫画阅读进度发布）
      // 和本地备份导入/导出都属于漫画域，恒在。
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.mediaTracking),
        isNull,
        reason: 'my-comic 保留 Tracking（漫画阅读进度发布），它不再依赖在线服务模块',
      );
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.syncBackup),
        isNull,
        reason: '本地备份导入/导出属于漫画域，恒在',
      );
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.interconnect),
        ModuleId.sync,
        reason: '设备互联仍挂同步模块（my-comic 中该模块不在可见集合里）',
      );
    });

    test('AI 是独立模块：关 AI 只藏「设置 › AI」，不连坐在线服务', () {
      expect(
        moduleOfSettingsDestination(SettingsDestinationId.ai),
        ModuleId.ai,
      );
      final ModuleVisibility noAi = ModuleVisibility(
        ModuleId.values.toSet()..remove(ModuleId.ai),
      );
      expect(isAiModuleEnabled(noAi), isFalse);
      expect(
        isSettingsDestinationVisible(SettingsDestinationId.ai, noAi),
        isFalse,
      );
      expect(
        isSettingsDestinationVisible(SettingsDestinationId.services, noAi),
        isTrue,
      );
      final ModuleVisibility noServices = ModuleVisibility(
        ModuleId.values.toSet()..remove(ModuleId.services),
      );
      expect(isAiModuleEnabled(noServices), isTrue);
      expect(
        isSettingsDestinationVisible(SettingsDestinationId.ai, noServices),
        isTrue,
      );
    });

    test('模块关掉后它的分类确实不可见', () {
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      for (final SettingsDestinationId id in SettingsDestinationId.values) {
        final ModuleId? owner = moduleOfSettingsDestination(id);
        if (owner == null) continue;
        expect(
          isSettingsDestinationVisible(id, none),
          isFalse,
          reason: '$id 属于 $owner，模块关掉后不该还列在设置主页/搜索索引里',
        );
      }
    });
  });

  group('ShortcutScope 映射', () {
    test('划词弹窗内部导航恒在——它属于查词能力，不是查词页面', () {
      // 用户拍板：关掉「查词」只关页面入口，阅读器/视频里的划词弹窗要照常能用，
      // 弹窗里的「上/下一个词条」自然也得留着。
      expect(moduleOfShortcutScope(ShortcutScope.dictionaryPopup), isNull);
    });

    test('app 外系统级取词热键跟着 lookup 关——关掉模块不该还能装系统钩子', () {
      expect(
        moduleOfShortcutScope(ShortcutScope.globalExternal),
        ModuleId.lookup,
      );
    });

    test('通用作用域恒在', () {
      for (final ShortcutScope scope in <ShortcutScope>[
        ShortcutScope.global,
        ShortcutScope.universal,
        ShortcutScope.home,
        ShortcutScope.gamepad,
      ]) {
        expect(moduleOfShortcutScope(scope), isNull, reason: '$scope 跨模块常驻');
      }
    });
  });

  group('MediaKind 映射', () {
    test('epub 与 srt 都归 books（字幕书也是书）', () {
      expect(moduleOfMediaKind(MediaKind.epub), ModuleId.books);
      expect(moduleOfMediaKind(MediaKind.srt), ModuleId.books);
    });

    test('visibleMediaKinds 随模块收缩', () {
      const ModuleVisibility booksOnly = ModuleVisibility(<ModuleId>{
        ModuleId.books,
      });
      expect(visibleMediaKinds(booksOnly), <MediaKind>{
        MediaKind.epub,
        MediaKind.srt,
      });
      const ModuleVisibility none = ModuleVisibility(<ModuleId>{});
      expect(visibleMediaKinds(none), isEmpty);
    });
  });
}
