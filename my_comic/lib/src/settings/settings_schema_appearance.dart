import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:my_comic/src/utils/adaptive/nav_bar_style.dart';
import 'package:my_comic/src/utils/my_comic_icons.dart';
import 'package:my_comic/pages.dart';
import 'package:my_comic/src/models/module_id.dart';
import 'package:my_comic/src/models/module_registry.dart';
import 'package:my_comic/src/settings/settings_actions.dart';
import 'package:my_comic/src/settings/settings_context.dart';
import 'package:my_comic/src/settings/settings_destination.dart';
import 'package:my_comic/src/utils/misc/app_icon_preferences.dart'
    show currentAppIconSelection;
import 'package:my_comic/utils.dart';

SettingsDestination buildAppearanceDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.appearance,
    title: t.settings_destination_appearance_interaction,
    summary: t.design_system_hint,
    icon: MyComicIcons.appearance,
    sections: <SettingsSection>[
      SettingsSection(
        id: 'appearance.section.interface',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.section_interface,
        items: <SettingsItem>[
          // searchTitle 复用各自绘制行的既有标题（无新 key），让这些自定义选择器
          // 进入设置搜索（主题/语言/明暗等此前搜不到）。
          SettingsCustomItem(
            id: 'appearance.design_system',
            icon: MyComicIcons.devices,
            searchTitle: t.design_system_label,
            builder: buildDesignSystemSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.theme',
            icon: Icons.color_lens_outlined,
            searchTitle: t.reader_theme,
            builder: buildThemeSelector,
          ),
          SettingsCustomItem(
            id: 'appearance.brightness',
            icon: Icons.contrast_outlined,
            searchTitle: t.dark_mode,
            builder: buildBrightnessSelector,
          ),
          // 「纯黑深色背景」：原「纯黑」预设的语义（2026-10 预设只决定种子色、不再
          // 自带明暗 / 纯黑），改成明暗旁的独立开关；对系统取色 / 预设 / 自定义主题
          // 一律生效，只在深色下起作用。
          SettingsSwitchItem(
            id: 'appearance.pure_black_dark',
            title: t.theme_pure_black,
            subtitle: t.theme_pure_black_hint,
            icon: MyComicIcons.darkMode,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.pureBlackDark,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setPureBlackDark(value);
              notifyReaderSettingsChanged(settingsContext);
            },
            defaultValue: false,
          ),
          // 墨水屏模式：全局单开关（设备属性，不随 Profile 快照），叠加在主题/
          // 明暗机制之上——开=纯黑白+无动画+线式高亮，关=还原原主题。
          SettingsSwitchItem(
            id: 'appearance.eink_mode',
            title: t.eink_mode,
            subtitle: t.eink_mode_hint,
            icon: Icons.filter_b_and_w_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.einkMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setEinkMode(value);
              // BUG-2329：einkMode 是正文 CSS 的入参（ReaderContentStyles.css 的
              // einkMode），开着书切换必须重注入，否则正文要退出重进才变黑白。
              notifyReaderSettingsChanged(settingsContext);
            },
            defaultValue: false,
          ),
          // 玻璃材质档位：只在设计系统选「玻璃」时出现（设计系统行负责开关玻璃，
          // 这里只在毛玻璃 / 液态之间选）。正文、视频画面不变；墨水屏、系统增强
          // 对比度 / 降低透明度下自动回退实心，liquid 在引擎不支持着色器
          // ImageFilter 时降级为 frosted。随 Profile 走。
          //
          // 2026-10-06 用户拍板：Apple 设计系统固定毛玻璃，液态玻璃入口先关掉
          // ——本行恒不可见（设置页与设置搜索都走 visible 谓词，一并消失），
          // 生效值由 ThemeNotifier.glassMaterialTier 钉死（2026-10-12 起为 off：
          // 原生 Cupertino 实色，无玻璃特效）。schema 项、
          // 偏好键 `glass_material` 与液态渲染代码都保留，恢复时把 visible 改回
          // `designSystem == 'glass'` 并撤掉 glassMaterialTier 的钉死即可。
          SettingsSegmentedItem<MyComicGlassMaterial>(
            id: 'appearance.glass_material',
            title: t.glass_material,
            subtitle: t.glass_material_hint,
            icon: Icons.blur_on_outlined,
            visible: (SettingsContext settingsContext) => false,
            options: <SettingsSegmentOption<MyComicGlassMaterial>>[
              SettingsSegmentOption<MyComicGlassMaterial>(
                value: MyComicGlassMaterial.frosted,
                label: t.glass_material_frosted,
              ),
              SettingsSegmentOption<MyComicGlassMaterial>(
                value: MyComicGlassMaterial.liquid,
                label: t.glass_material_liquid,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.glassMaterialTier,
            onChanged:
                (SettingsContext settingsContext, MyComicGlassMaterial value) =>
                    settingsContext.appModel.setGlassMaterial(value),
            defaultValue: MyComicGlassMaterial.frosted,
          ),
          // 「界面大小」滑条：commitOnRelease——本滑条位于受 MyComicAppUiScale 的
          // Transform.scale 缩放的子树内，拖动逐帧提交会让整树立刻按新比例重排、
          // 滑块在手指下位移、手势断裂（TODO-374 旧 _AppUiScaleSliderRow 注释）。
          // 渲染层 _CommitOnReleaseSlider 拖动只更新本地预览值（跟手 + 标题读数
          // 实时），松手才经 onChanged 一次性提交真实缩放；键盘/手柄步进每按即提交。
          // 一等 schema 项同时带来静止常驻读数（titleReadout）与搜索索引，替代原
          // 自定义 custom 行双实现。id/持久化路径不变。
          SettingsSliderItem(
            id: 'appearance.app_ui_scale',
            title: t.app_ui_scale,
            subtitle: t.app_ui_scale_hint,
            icon: Icons.format_size_outlined,
            min: MyComicAppUiScale.minScale,
            max: MyComicAppUiScale.maxScale,
            divisions: 27,
            label: (double value) => '${(value * 100).round()}%',
            titleReadout: true,
            commitOnRelease: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.appUiScale,
            onChanged: (SettingsContext settingsContext, double value) async {
              await settingsContext.appModel.setAppUiScale(value);
            },
          ),
          // 「界面语言」从系统分类归位到这里：它改的是界面呈现语言，与主题/明暗/
          // 缩放同属界面外观；id/持久化 key 不变（本就带 appearance 前缀）。
          SettingsCustomItem(
            id: 'appearance.language',
            icon: Icons.translate_outlined,
            searchTitle: t.options_language,
            builder: buildLanguageSelector,
          ),
        ],
      ),
      // 字体库：界面字体仍是 MyComic 的现存能力（CustomFontsPage 的字体目录
      // 含 appUi 用途）。EPUB / 词典排版与内容语言随非漫画域删除，因此这里只保留
      // 字体库入口，不再有正文/词典字体分区。
      SettingsSection(
        id: 'appearance.section.typography',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.section_typography,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.font_catalog',
            title: t.custom_fonts_catalog_title,
            icon: MyComicIcons.font,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const CustomFontsPage(),
              );
              notifyReaderSettingsChanged(settingsContext);
            },
          ),
        ],
      ),
      // my-comic：内容语言（EPUB/词典排版）、功能模块开关、首页 dashboard
      // 面板都属于已移除的非漫画域，不再出现在设置里。
      SettingsSection(
        id: 'appearance.section.navigation',
        presentation: SettingsSectionPresentation.alwaysExpanded,
        title: t.settings_section_app_shell,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'appearance.app_icon',
            title: t.app_icon_label,
            icon: MyComicIcons.widgets,
            visible: (_) => Platform.isAndroid || Platform.isWindows,
            builder: (_) => const MiscellaneousSettingsPage(),
          ),
          // 应用图标 ↔ 主题色的两个开关，紧挨「应用图标」入口，默认都关。
          // ①「图标跟随主题色」：内置吉祥物 logo（宽屏 rail 品牌位、悬浮球）按
          // 强调色换色；关 = 始终原图。对用户自定义的图标图片从不换色。
          SettingsSwitchItem(
            id: 'appearance.tint_app_logo',
            title: t.theme_logo_tint_enabled,
            subtitle: t.theme_logo_tint_hint,
            icon: MyComicIcons.widgets,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.tintAppLogo,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.themeNotifier.setTintAppLogo(
                value,
              );
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          // ②「主题色跟随图标」：设置了自定义图标图片时才出现；开着时从该图
          // 取种子色覆盖生效主题（不改写主题偏好，关掉即恢复原主题）。
          SettingsSwitchItem(
            id: 'appearance.follow_app_icon_accent',
            title: t.theme_icon_accent_follow,
            subtitle: t.theme_icon_accent_hint,
            icon: MyComicIcons.appearance,
            visible: (_) => currentAppIconSelection.value.usesCustomFile,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.themeNotifier.followAppIconAccent,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.themeNotifier
                  .setFollowAppIconAccent(value);
              notifyReaderSettingsChanged(settingsContext);
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          SettingsSwitchItem(
            id: 'appearance.reverse_navigation_bar',
            title: t.reverse_navigation_bar,
            icon: Icons.swap_horiz_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.reverseNavigationBar,
            onChanged: (SettingsContext settingsContext, bool value) {
              settingsContext.appModel.toggleReverseNavigationBar();
              settingsContext.refresh();
            },
            defaultValue: false,
          ),
          // MD3 悬浮底栏（手机竖屏）图标下的标签；默认关 = M3E floating toolbar
          // 的纯图标形态（标签进 tooltip）。Apple 设计系统的标签栏不读它。
          SettingsSwitchItem(
            id: 'appearance.nav_bar_labels',
            title: t.home_nav_bar_labels,
            icon: MyComicIcons.textFields,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.navBarLabelsVisible,
            onChanged: (SettingsContext settingsContext, bool value) {
              unawaited(
                settingsContext.appModel
                    .setNavBarLabelsVisible(value)
                    .then((_) => settingsContext.refresh()),
              );
            },
            defaultValue: false,
          ),
          // 手机底栏形态：平铺（放不下收进「更多」）/ 分页滑动（所有入口同级，
          // 底栏横滑翻页、按住拖选）。
          SettingsSegmentedItem<AdaptiveNavBarStyle>(
            id: 'appearance.nav_bar_style',
            title: t.home_nav_bar_style,
            icon: MyComicIcons.swipe,
            options: <SettingsSegmentOption<AdaptiveNavBarStyle>>[
              SettingsSegmentOption<AdaptiveNavBarStyle>(
                value: AdaptiveNavBarStyle.flat,
                label: t.home_nav_bar_style_flat,
              ),
              SettingsSegmentOption<AdaptiveNavBarStyle>(
                value: AdaptiveNavBarStyle.pager,
                label: t.home_nav_bar_style_pager,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.navBarStyle,
            onChanged:
                (SettingsContext settingsContext, AdaptiveNavBarStyle value) =>
                    settingsContext.appModel
                        .setNavBarStyle(value)
                        .then((_) => settingsContext.refresh()),
            defaultValue: AdaptiveNavBarStyle.defaultStyle,
          ),
          // 「启动页」(id 'appearance.startup_default_dictionary_tab'，前身是开关
          // 「启动时打开查词」) 在「系统 · 通用」分区（它管的是启动落地页/导航行为，
          // 与主题/明暗等外观无关）；id 保持不变（历史命名 appearance 前缀）。
        ],
      ),
    ],
  );
}

