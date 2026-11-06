## Agent skills

### Issue tracker

Issues and specs live as markdown files under `.scratch/<feature>/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles; label strings match role names. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` at the repo root and ADRs in `docs/adr/`. See `docs/agents/domain.md`.

## Working agreement

### 开工前必须获得明确授权

在用户明确说可以开工（例如“开工”“开始执行”“开始做”“按这个做”）之前，不得开始实现工作：不要修改文件、创建 worktree/分支、执行变更命令、提交或删除代码。只读调研和方案讨论可以做。问答中的“按你推荐的来”不构成开工授权；不确定时先问“可以开工了吗？”。

## Project constraints

### UI fidelity (locked)

my-comic UI must use the same design and aesthetic as Fushi v3.0.0. Preserve the original Fushi shell, components, theme, and layout; only hide or remove non-manga entries. Do not replace, restyle, or simplify the UI without explicit user approval. See `docs/adr/0008-ui-fidelity-constraint.md`.
