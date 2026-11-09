# 14: 领域文档与 ADR 同步

**What to build:** 更新领域文档，记录 Library membership、非书架 Manga、非破坏移出、下载身份与 Mihon 风格清理数据库的语义，并同步相关 ADR。

**Blocked by:** 01（Library membership 基础）、02（非书架行与在线阅读）、03（显式加入书架翻转 membership）、04（非破坏移出书架）、05（非书架阅读功能）、06（下载身份与文件夹复用）、07（已下载状态脱离书架）、08（非书架下载与删除下载）、09（失败下载取消）、10（导入非书架行与 History 修复）、11（导入后自动匹配下载）、12（重建下载索引）、13（清理数据库 Mihon 对齐）

**Status:** ready-for-agent

- [ ] GLOSSARY 新增/更新：Library membership、Non-library Manga、Remove from Library（非破坏）、Download identity、Clear database（Mihon 对齐）、History（仍每 Manga 一条）。
- [ ] 新增 ADR：Library membership 与非书架行模型、非破坏移出、非书架功能边界。
- [ ] 更新 ADR 0012：文件夹身份与复用规则（manifest 身份优先，无 manifest 保持 `(2)`）。
- [ ] 更新 ADR 0017：失败下载同时提供重试与取消。
- [ ] 更新 ADR 0018：History 身份、旧快照兼容与导入修复。
- [ ] 更新 ADR 0005/0019：`favorite=false` 导入为非书架行及导出边界。
- [ ] 在 ADR 0008 下记录移出文案、清理数据库 UI、加入书架提示的批准。
- [ ] 文档只描述用户可见行为与领域语义，不写会过时的实现细节。
- [ ] 不修改代码、测试或 spec。
