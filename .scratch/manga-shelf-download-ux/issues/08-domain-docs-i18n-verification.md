# 08: Domain docs、i18n 与全量验证

**What to build:** 把本批的领域术语、架构决策与文案收口：更新 GLOSSARY 与 ADR，清理废弃 i18n key，确认全部 locale 与生成访问器同步，并跑通完整测试套件。

**Blocked by:** 01（继续阅读与「读完」语义修正）、02（重建下载索引只重链书架成员）、03（检索已下载扫描 downloads 并加入书架）、04（更新提醒分组置顶）、05（刷新失败横幅文案）、06（在线封面元数据刷新与 URL 合并）、07（在线封面持久字节缓存）

**Status:** ready-for-agent

- [ ] GLOSSARY 新增「Scan downloaded（检索已下载）」：用户手动触发的发现扫描，只读当前 Content root 的 `downloads`，把已下载但未加入书架的作品加入 Library；源未安装时原地登记为本地条目；不移动文件；显式执行时可复活 tombstone。
- [ ] GLOSSARY 修订「Rebuild download index（重建下载索引）」：只重链 Library 成员，不再补建条目；发现新作品由 Scan downloaded 负责。
- [ ] GLOSSARY 修订「Unindexed（未索引）」相关表述：未索引内容不再由 Rebuild 自动登记，仍可被 Scan downloaded 发现。
- [ ] 补 ADR：重建与检索的职责拆分，以及「书架归属只能由用户显式动作改变」的原则。
- [ ] 补 ADR：在线封面持久化与 Program state 封面缓存；明确封面不属于 Download library。
- [ ] 所有新增/修改文案在全部支持语言中同步，生成访问器已重新生成；废弃的「显示的是本机已保存的章节」key 已删除或明确标记。
- [ ] 本批未引入数据库 schema 变更；如实现中不可避免，补充迁移说明与兼容性验证。
- [ ] 完整测试套件通过，包括本批新增的继续阅读、重建、检索、封面与横幅测试。
- [ ] 实现遵守 ADR 0008（UI fidelity）与既有下载/封面边界，不新增平行实现。
