# 15: 领域文档与 ADR 同步

**What to build:** 更新领域文档，使 GLOSSARY 与 ADR 反映本次交付：移出书架可显式删除本地原作、Tag 与 Mihon 分类的双向映射、MyComic 可以创建 Backup，以及导出与导入补齐的边界。

**Blocked by:** 01（统一移出书架弹窗与单本删除语义）、04（加入书架前选择标签：核心选择器与在线作品页）、07（创建备份页与导出基础）、13（导入：Mihon 分类恢复为标签）、14（导入：应用设置与未入书架已读作品）

**Status:** ready-for-agent

- [ ] GLOSSARY 的 Remove from Library 明确：Local source 文件默认保留，但用户显式勾选时可以删除。
- [ ] GLOSSARY 的 Category 与 Tag 明确双向备份映射：Tag 导出为 Mihon 分类，Mihon 分类导入为 Tag；「书架」等价于 Mihon 的 Default 分类。
- [ ] GLOSSARY 的 Backup/Export 明确 MyComic 可以生成 `.tachibk`。
- [ ] GLOSSARY 新增或澄清 Reading statistics（阅读统计），说明其与 History、Reading progress 的区别。
- [ ] ADR 0005 更新：导出已交付；导入补齐范围。
- [ ] 新增 ADR：记录 gzip + protobuf 导出、标准偏好值类型、Tag/Category 映射、应用设置使用 MyComic 键名且不做 Mihon 键名映射、未入架已读作品的导入边界。
- [ ] 文档只描述用户可见行为与领域语义，不写会过时的实现细节。
