import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';

import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/pages/implementations/ai_provider_settings_section.dart';
import 'package:fushi/src/pages/implementations/ai_web_knowledge_sites_section.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart' show settingsResetSpecFor;
import 'package:fushi/utils.dart';


/// 「AI」一级设置分类：用户自配的大模型提供商 + 每个功能用哪家。
///
/// 归在独立的「AI」模块（`ModuleId.ai`，2026-10-13 起；此前挂在 `services` 下）：
/// 用户要能把 AI 整块关掉而不连坐在线服务。判据表见 `module_registry.dart`，别在
/// 此另写一份。
///
/// 提供商与功能指派走 [SettingsDestination.body] 逃生口：提供商是一份**可增删的
/// 记录列表**（每条还带自己的探测状态与模型下拉），schema 的声明式 item 树表达
/// 不了；与 OPDS / Torznab 段同一条切法。body 之后再挂声明式 section（`AI 下视频`
/// 的画质 / 片源 / 码率 / 字幕语言默认值），`bodyBeforeSections` 让 body 排在前面。
///
/// **必须零参、返回纯字面量树**：schema 按 locale 缓存（见 `settings_schema.dart`
/// 的 `_SettingsSchemaCache`），任何构造期读运行状态的口子都会让缓存发陈旧数据，
/// 守卫 `test/settings/settings_schema_cache_test.dart` 钉死这条。
SettingsDestination buildAiDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.ai,
    // 「功能模块」门控：关掉本模块 = 整条分类不渲染 / 不进搜索索引 / 主从详情不可选
    // （三条渲染路径共用 isVisible）。
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.ai,
      c.appModel.moduleVisibility,
    ),
    title: t.ai_settings_title,
    summary: t.ai_settings_summary,
    icon: FushiIcons.aiAssistant,
    body: (SettingsContext settingsContext) =>
        const AiProviderSettingsSection(),
    bodyBeforeSections: true,
    sections: <SettingsSection>[
      // 联网资料：app 自己抓条目正文喂给 AI，与提供商有没有联网工具无关，所以不另设
      // 门控——整页已经过 AI 模块门，这一段跟着页面走。内置站是声明式开关；自定义
      // MediaWiki 站点是可增删的记录列表，走 custom 行（同提供商列表的切法）。
      //
      // 2026-10-08 所有者：AI 页外层只放总配置（提供商 / 默认提供商），各功能的单独
      // 配置折叠起来。下面两段都是功能级配置，默认折叠，收起时摘要报改过几项。
      SettingsSection(
        id: 'ai.web_knowledge',
        title: t.ai_web_knowledge_section,
        footer: t.ai_web_knowledge_section_hint,
        presentation: SettingsSectionPresentation.collapsed,
        summaryBuilder: (SettingsContext c) =>
            _aiSectionModifiedSummary('ai.web_knowledge', c),
        items: <SettingsItem>[
          for (final WebKnowledgeSite site in kBuiltinWebKnowledgeSites)
            SettingsSwitchItem(
              id: 'ai.web_knowledge.${site.id}',
              title: webKnowledgeSiteDisplayLabel(site),
              icon: FushiIcons.globe,
              value: (SettingsContext c) => c
                  .appModel
                  .prefsRepo
                  .aiWebKnowledgeEnabledSiteIds
                  .contains(site.id),
              onChanged: (SettingsContext c, bool value) =>
                  setWebKnowledgeSiteEnabled(
                    c.appModel.prefsRepo,
                    site.id,
                    enabled: value,
                  ),
              defaultValue: true,
            ),
          // 自定义站点是可增删的记录：每条一行，与上面内置站的开关行同组并列。
          SettingsCustomItem.rows(
            id: 'ai.web_knowledge.custom',
            searchTitle: t.ai_web_knowledge_custom_title,
            cliList: buildWebKnowledgeCustomCliList(),
            rowsBuilder: (SettingsContext c) => c.appModel.isPreferencesReady
                ? buildAiWebKnowledgeCustomSiteRows(
                    c.context,
                    c.appModel.prefsRepo,
                    c.refresh,
                  )
                : const <Widget>[],
          ),
        ],
      ),
    ],
    bodySearchEntries: <SettingsBodySearchEntry>[
      SettingsBodySearchEntry(
        id: 'ai.providers',
        title: t.ai_providers_section,
        subtitle: t.ai_providers_section_summary,
      ),
      SettingsBodySearchEntry(
        id: 'ai.features',
        title: t.ai_features_section,
        subtitle: t.ai_features_section_summary,
      ),
    ],
  );
}

/// 折叠分组的摘要：本组有几项改过默认值（判据与页级「恢复本页默认」同一个
/// [settingsResetSpecFor]）；一项都没改就不显示摘要。
///
/// 在渲染时按 id 回查本页 schema 的那一组，而不是在构造期捕获 item 列表——
/// [buildAiDestination] 必须保持零参的纯字面量树（见其文档）。
String? _aiSectionModifiedSummary(String sectionId, SettingsContext context) {
  if (!context.appModel.isPreferencesReady) return null;
  final SettingsSection section = buildAiDestination().sections.firstWhere(
    (SettingsSection candidate) => candidate.id == sectionId,
  );
  final int count = section.items
      .where(
        (SettingsItem item) =>
            settingsResetSpecFor(item, context)?.modified ?? false,
      )
      .length;
  return count == 0 ? null : t.settings_section_modified_count(n: count);
}
