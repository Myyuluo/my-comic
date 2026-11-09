# 12: 导出插件商店与图源设置

**What to build:** 创建备份页增加「插件商店」「图源设置」；导出全部 Extension store 与按 Source 组织的配置；跳过空配置组与导入生成的不可用占位源；图源配置复用 11 的敏感过滤规则。

**Blocked by:** 11（导出应用设置与敏感设置过滤）

**Status:** ready-for-agent

- [ ] 创建备份页增加「插件商店」「图源设置」勾选项，默认勾选。
- [ ] 插件商店导出全部 Extension store，包含 index URL、名称、badge、联系站点、签名 key、Discord、legacy 与扩展列表 URL。
- [ ] 图源设置按 Source 导出配置，sourceKey 为 `source_<sourceId>`；跳过空配置组与不可用占位源。
- [ ] 未勾选敏感设置时排除图源配置中的密码、Token 等敏感键；勾选时包含。
- [ ] 关闭对应勾选项时不写入该类数据。
- [ ] 备份 seam 测试覆盖商店字段、源配置键、占位源跳过与敏感过滤。
