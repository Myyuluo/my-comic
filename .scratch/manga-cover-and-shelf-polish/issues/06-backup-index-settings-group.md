# 06: 设置页合并备份索引并重排下载分组

**What to build:** 在「设置 → 存储与下载」中，把备份与下载索引合并为一个「备份索引」分组；组内顺序为导入备份、创建备份、重建下载索引、检索已下载；把「下载」分组移到「备份索引」下方，数据存储位置保持最上方。

**Blocked by:** None（can start immediately）

**Status:** ready-for-agent

- [ ] 「存储与下载」section 顺序为：数据存储位置 → 备份索引 → 下载。
- [ ] 合并后的 section 保留稳定 id `system.section.backup`，标题为「备份索引」；旧 `storage.rebuild.section` 不再渲染。
- [ ] 组内 item 顺序固定为 `system.import_mihon_backup`、`system.export_mihon_backup`、`storage.rebuild_index`、`storage.scan_downloaded`；item id 全部保持不变。
- [ ] 备份功能在移动端仍然可见；重建/检索的桌面可见性下移到两个 item 自身，不把整个合并 section 变成桌面专属。
- [ ] CLI/桌面控制的 item key、确认框、进度框、报告行为保持不变；CLI breadcrumb 可变为 Backup index。
- [ ] 新增/重命名「备份索引」section 标题 key，补齐全部 locale；移除不再使用的 `rebuild_download_index_section` 或明确标记；重新生成访问器。
- [ ] 更新顺序 guard：下载视图 section 顺序、合并 section item 顺序、备份设置、CBZ 设置、重建/检索设置测试。
- [ ] 不改变设置页视觉组件与交互风格，遵守 ADR 0008。
