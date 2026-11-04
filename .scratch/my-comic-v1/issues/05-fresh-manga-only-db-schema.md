# 05: 全新漫画-only DB schema

**What to build:** 把数据库切换到全新的漫画-only schema，不兼容 Fushi 旧 DB/`.fushi.zip`，只保留 my-comic 需要的表。这是 wide refactor：如果一次替换破坏太多 call sites，拆成 expand（新增 schema）→ migrate（按模块迁移）→ contract（删除旧 schema），共享 integration branch，并用一个最终 integrate-and-verify ticket 承诺 green。

**Blocked by:** 02: Manga-only shell：移除非漫画域；03: 移除阅读器内嵌的非漫画控件；04: 删除非漫画原生库并测量体积

**Status:** ready-for-agent

- [ ] 应用首次运行创建全新 schema，不读取或迁移 Fushi 旧 DB
- [ ] Library、Category、History、Reading progress、Download、Local source 持久化正常
- [ ] 未用表已删除，无旧表引用
- [ ] `.fushi.zip` 或旧 DB 导入路径不存在
- [ ] Windows build 和运行成功
