# 04: 领域文档更新（GLOSSARY + ADR 0016）

**What to build:** 把新的漫画页布局写入 `GLOSSARY.md` 与 ADR 0016：标签栏位于标题下方的二级行，顶部 chrome 行是继续阅读胶囊。

**Blocked by:** 01（标签栏二级行）、03（继续阅读胶囊）

**Status:** resolved

- [x] GLOSSARY 更新 View tab（视图页签）：漫画页顶部不再是标签栏；顶部 chrome 行是继续阅读胶囊，标签栏在标题下方的二级行。
- [x] GLOSSARY 更新 Tag / 书架页签：补充二级浮动胶囊行的呈现位置与数量样式。
- [x] GLOSSARY 新增继续阅读胶囊（Continue reading pill）。
- [x] ADR 0016 补修订说明：标签页签栏从顶部 chrome 行移到标题下方二级行；顶部行改由继续阅读胶囊占据。
- [x] 文档只描述已实现的用户可见行为，不引入代码路径或易过时的实现细节。

## Answer

Implemented in `5df21aae`, merged as `47b604ce`. 更新 `GLOSSARY.md` 的 View tab / Tag / 书架页签，并新增继续阅读胶囊；ADR 0016 追加 2026-11-09 修订说明，原决策与 `status: accepted` 保留。Code review fixes in `106ad7d0`, merged as `cd805538`.
