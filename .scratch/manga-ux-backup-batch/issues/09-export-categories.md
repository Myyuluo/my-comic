# 09: 导出分类（标签 → Mihon 分类）

**What to build:** 创建备份页增加「分类」勾选项；把 MyComic 的 Tag 导出为 Mihon 分类（名称与顺序），每部导出的 Manga 写入其 Tag 对应的分类 order；分类可以在不导出书架作品时单独导出。

**Blocked by:** 07（创建备份页与导出基础）

**Status:** ready-for-agent

- [ ] 创建备份页增加「分类」勾选项，默认勾选；「分类」可在未勾选「书架中的作品」时单独导出。
- [ ] 每个 Tag 导出为 Mihon 分类，name 为 Tag 名称，order 为 Tag 排序且唯一。
- [ ] 每部导出的 Manga 写入其 Tag 对应的分类 order 值；多 Tag 写入多个 order。
- [ ] Tag 颜色不导出；导出不新增或修改 Tag。
- [ ] 关闭「分类」时分类条目与每部作品的分类字段都不写入。
- [ ] 备份 seam 测试覆盖名称、顺序、多 Tag 与单独导出。
