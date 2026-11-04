# 05: 全新漫画-only DB schema

**What to build:** 把数据库切换到全新的漫画-only schema，不兼容 Fushi 旧 DB/`.fushi.zip`，只保留 my-comic 需要的表。这是 wide refactor：如果一次替换破坏太多 call sites，拆成 expand（新增 schema）→ migrate（按模块迁移）→ contract（删除旧 schema），共享 integration branch，并用一个最终 integrate-and-verify ticket 承诺 green。

**Blocked by:** 02: Manga-only shell：移除非漫画域；03: 移除阅读器内嵌的非漫画控件；04: 删除非漫画原生库并测量体积

**Status:** resolved

- [x] 应用首次运行创建全新 schema，不读取或迁移 Fushi 旧 DB
- [x] Library、Category、History、Reading progress、Download、Local source 持久化正常
- [x] 运行时只创建 37 张漫画表；非漫画表不创建/不访问（代码级 contract 清理见 ticket 11）
- [x] `.fushi.zip` 或旧 DB 导入路径不存在
- [x] Windows build 和运行成功

## Comments

- schema v1 / 37 tables / 61 非漫画表不存在
- 旧 `fushi.db` 未读取/未迁移
- 六域持久化通过
- `packages/fushi_core` 48 项 + 定向 60 项通过
- build/run 成功
- 残留 `@DriftDatabase` 98 表声明与 dead backup 代码 → ticket 11
- 已知 `manga_drop_test` 6 项是 ticket 02 已移除行为的既有失败，与本 ticket 无关
